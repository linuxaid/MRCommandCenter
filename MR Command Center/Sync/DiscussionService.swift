import Foundation
import SwiftData
import os

enum CommentPostingError: LocalizedError, Equatable {
    case disabled
    case emptyBody
    case missingDiffRefs
    case needsAPIScope
    case alreadyPosted
    case resolveNeedsAPIScope

    var errorDescription: String? {
        switch self {
        case .disabled:
            "Posting comments is turned off. Turn it on in Settings → Accounts."
        case .emptyBody:
            "Write a comment first."
        case .missingDiffRefs:
            "GitLab didn't provide the commit references needed to anchor this comment. Refresh the MR and try again."
        case .needsAPIScope:
            "GitLab refused the comment (403). Posting needs a token with the api scope, not just read_api."
        case .alreadyPosted:
            "This AI comment was already posted to GitLab."
        case .resolveNeedsAPIScope:
            "GitLab refused (403). Resolving threads needs a token with the api scope and permission in this project."
        }
    }
}

/// Loads MR discussion threads and posts new diff comments and replies.
/// Threads are cached in memory per MR; posting updates the cache immediately.
final class DiscussionService {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let dependencies: AppDependencies
    private var cache: [String: (fetchedAt: Date, discussions: [GitLabDiscussion])] = [:]

    init(container: ModelContainer, dependencies: AppDependencies) {
        self.container = container
        self.dependencies = dependencies
    }

    var isPostingEnabled: Bool {
        AccountSettings.current(in: context).postCommentsEnabled
    }

    func discussions(for mr: TrackedMR, maxAge: TimeInterval = 30, forceRefresh: Bool = false) async throws -> [GitLabDiscussion] {
        if !forceRefresh, let cached = cache[mr.key], Date.now.timeIntervalSince(cached.fetchedAt) < maxAge {
            return cached.discussions
        }
        let discussions = try await client().discussions(projectID: mr.projectID, iid: mr.iid)
        cache[mr.key] = (.now, discussions)
        updateCounts(for: mr, with: discussions)
        return discussions
    }

    func cachedDiscussions(for mrKey: String) -> [GitLabDiscussion]? {
        cache[mrKey]?.discussions
    }

    /// Starts a new thread on a diff line, anchored to the exact diff version shown.
    func createThread(on line: DiffLine, in file: DiffFile, of diff: MRDiff, body: String, mr: TrackedMR) async throws -> GitLabDiscussion {
        let text = try validated(body)
        guard let refs = diff.refs else { throw CommentPostingError.missingDiffRefs }
        let request = ThreadPlacement.newDiscussion(body: text, line: line, file: file, refs: refs)
        let discussion = try await mapPostingErrors {
            try await client().createDiffDiscussion(projectID: mr.projectID, iid: mr.iid, request: request)
        }
        var discussions = cache[mr.key]?.discussions ?? []
        discussions.append(discussion)
        cache[mr.key] = (cache[mr.key]?.fetchedAt ?? .now, discussions)
        updateCounts(for: mr, with: discussions)
        Log.sync.info("Posted a diff comment")
        return discussion
    }

    /// Posts an AI concern as a diff comment, always attributed, and remembers it was posted.
    func postAIConcern(_ concern: ConcernRecord, body: String, on line: DiffLine, in file: DiffFile,
                       of diff: MRDiff, mr: TrackedMR) async throws -> GitLabDiscussion {
        guard concern.postedDiscussionID == nil else { throw CommentPostingError.alreadyPosted }
        let discussion = try await createThread(on: line, in: file, of: diff, body: AICommentFormatter.ensureAttribution(body), mr: mr)
        concern.postedDiscussionID = discussion.id
        concern.postedAt = .now
        try? context.save()
        return discussion
    }

    /// Posts a run's summary as a resolvable thread on the MR, once per run.
    func postSummary(of run: AIReviewRun, body: String, mr: TrackedMR) async throws -> GitLabDiscussion {
        guard run.summaryDiscussionID == nil else { throw CommentPostingError.alreadyPosted }
        let text = try validated(AICommentFormatter.ensureAttribution(body))
        let discussion = try await mapPostingErrors {
            try await client().createDiscussion(projectID: mr.projectID, iid: mr.iid, body: text)
        }
        var discussions = cache[mr.key]?.discussions ?? []
        discussions.append(discussion)
        cache[mr.key] = (cache[mr.key]?.fetchedAt ?? .now, discussions)
        updateCounts(for: mr, with: discussions)
        run.summaryDiscussionID = discussion.id
        run.summaryPostedAt = .now
        try? context.save()
        Log.sync.info("Posted an AI summary thread")
        return discussion
    }

    func reply(to discussionID: String, body: String, mr: TrackedMR) async throws -> GitLabDiscussion.Note {
        let text = try validated(body)
        let note = try await mapPostingErrors {
            try await client().replyToDiscussion(projectID: mr.projectID, iid: mr.iid, discussionID: discussionID, body: text)
        }
        if var discussions = cache[mr.key]?.discussions,
           let index = discussions.firstIndex(where: { $0.id == discussionID }) {
            discussions[index].notes = (discussions[index].notes ?? []) + [note]
            cache[mr.key] = (cache[mr.key]?.fetchedAt ?? .now, discussions)
        }
        Log.sync.info("Posted a reply")
        return note
    }

    /// Where activity lines go (`MergeRequestStore.record`), set by `AppModel`.
    var recordActivity: ((ActivityDetector.Change, TrackedMR) -> Void)?

    /// Resolves (or reopens) a thread so the MR can merge, and records it in Activity.
    /// Not gated by "Allow posting comments": like Approve and Merge, it only needs the api scope.
    func setResolved(_ discussionID: String, resolved: Bool, mr: TrackedMR) async throws {
        let before = MRSnapshot(mr)
        let updated: GitLabDiscussion
        do {
            updated = try await client().setDiscussionResolved(projectID: mr.projectID, iid: mr.iid,
                                                               discussionID: discussionID, resolved: resolved)
        } catch APIError.forbidden {
            throw CommentPostingError.resolveNeedsAPIScope
        }
        // Recount from a fresh fetch: the cache may predate threads that arrived since.
        if (try? await discussions(for: mr, forceRefresh: true)) == nil {
            // Couldn't refetch: patch the cache, and move the count by just this thread.
            if var cached = cache[mr.key]?.discussions, let index = cached.firstIndex(where: { $0.id == discussionID }) {
                let wasUnresolved = cached[index].isUnresolved
                cached[index] = updated
                cache[mr.key] = (cache[mr.key]?.fetchedAt ?? .now, cached)
                if wasUnresolved != updated.isUnresolved {
                    mr.unresolvedDiscussions = max(0, mr.unresolvedDiscussions + (updated.isUnresolved ? 1 : -1))
                }
            }
        }
        let me = AccountSettings.current(in: context).gitLabUsername
        let starter = updated.userNotes.first?.author
        let whose = starter?.username == me ? "your" : starter.map { "\($0.name.split(separator: " ").first ?? "")'s" } ?? "a"
        recordActivity?(ActivityDetector.Change(kind: .other, message: "You \(resolved ? "resolved" : "reopened") \(whose) thread"), mr)
        // What resolving changed: all threads resolved, ready to merge...
        for change in ActivityDetector.changes(from: before, to: MRSnapshot(mr)) {
            recordActivity?(change, mr)
        }
        try? context.save()
        Log.sync.info("Changed a thread's resolved state")
    }

    private func validated(_ body: String) throws -> String {
        guard isPostingEnabled else { throw CommentPostingError.disabled }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CommentPostingError.emptyBody }
        return text
    }

    private func mapPostingErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch APIError.forbidden {
            throw CommentPostingError.needsAPIScope
        }
    }

    private func client() throws -> any GitLabAPI {
        try dependencies.gitLabClient(settings: AccountSettings.current(in: context))
    }

    /// Keeps the sidebar's unresolved-thread count in step with what's shown.
    /// Keeps the thread counts and "whose turn" fields current after a fetch or a post.
    private func updateCounts(for mr: TrackedMR, with discussions: [GitLabDiscussion]) {
        mr.apply(discussions: discussions, me: AccountSettings.current(in: context).gitLabUsername)
        try? context.save()
    }
}
