import Foundation
import Observation

/// Where a comment box is open.
enum CommentTarget: Hashable {
    case line(fileID: DiffFile.ID, lineID: DiffLine.ID)
    case reply(discussionID: String)
}

/// A file's group of threads that can't sit on a shown line.
struct ThreadGroupID: Hashable {
    enum Kind { case offDiff, outdated }
    let fileID: DiffFile.ID
    let kind: Kind
}

/// Comment threads and composer state for the Changes view of one MR.
@Observable
final class CommentsModel {
    private(set) var placement = ThreadPlacement()
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var isPostingEnabled = false

    /// The one open comment box. Drafts survive switching between boxes.
    var activeTarget: CommentTarget?
    var drafts: [CommentTarget: String] = [:]
    private(set) var postingTarget: CommentTarget?
    private(set) var postErrors: [CommentTarget: String] = [:]
    /// Threads the user folded. Every thread starts open, resolved ones included, so
    /// resolved threads are never hidden behind a click.
    private(set) var collapsedThreadIDs: Set<String> = []
    /// Per-file thread groups the user folded or opened, overriding where they start.
    private var groupExpansion: [ThreadGroupID: Bool] = [:]

    func isExpanded(_ discussion: GitLabDiscussion) -> Bool {
        !collapsedThreadIDs.contains(discussion.id)
    }

    func toggleExpanded(_ discussion: GitLabDiscussion) {
        if collapsedThreadIDs.contains(discussion.id) {
            collapsedThreadIDs.remove(discussion.id)
        } else {
            collapsedThreadIDs.insert(discussion.id)
        }
    }

    /// Both groups start open: resolved threads usually end up outdated (the line was
    /// fixed, then the thread resolved), and a folded group hid them.
    func isGroupExpanded(_ group: ThreadGroupID) -> Bool {
        groupExpansion[group] ?? true
    }

    func setGroupExpanded(_ group: ThreadGroupID, _ expanded: Bool) {
        groupExpansion[group] = expanded
    }

    // MARK: AI concerns

    /// The AI run shown inline (latest completed run at this diff's head SHA).
    private(set) var aiRun: AIReviewRun?
    /// Mirrors the "Show AI comments" toggle.
    var showsAI = true
    /// Called after an AI concern is posted or dismissed, to refresh open counts.
    @ObservationIgnored var onAIChange: (() -> Void)?

    func setDismissed(_ concern: ConcernRecord, _ dismissed: Bool) {
        concern.dismissedAt = dismissed ? .now : nil
        onAIChange?()
    }

    var openAICount: Int { aiConcerns.values.count(where: \.isOpen) }

    /// Open AI comments per file, for the file list badges.
    var openAICountsByFile: [DiffFile.ID: Int] {
        var counts: [DiffFile.ID: Int] = [:]
        for (fileID, lines) in aiPlacement.byLine {
            counts[fileID, default: 0] += lines.values.joined().count { aiConcerns[$0]?.isOpen == true }
        }
        for (fileID, ids) in aiPlacement.unplaced {
            counts[fileID, default: 0] += ids.count { aiConcerns[$0]?.isOpen == true }
        }
        return counts
    }
    private(set) var aiPlacement = AIConcernPlacement()
    private(set) var aiConcerns: [UUID: ConcernRecord] = [:]
    /// The AI comment being previewed before posting.
    var aiPostDraft: AIPostDraft?
    private(set) var isPostingAI = false
    var aiPostError: String?

    func showAI(_ run: AIReviewRun?, in diff: MRDiff) {
        guard let run, run.headSHA == diff.headSHA else {
            aiRun = nil
            aiPlacement = AIConcernPlacement()
            aiConcerns = [:]
            return
        }
        aiRun = run
        var refs: [AIConcernRef] = []
        var concerns: [UUID: ConcernRecord] = [:]
        for file in run.orderedFiles {
            for concern in file.orderedConcerns {
                refs.append(AIConcernRef(id: concern.id, path: file.path, line: concern.lineNumber))
                concerns[concern.id] = concern
            }
        }
        aiConcerns = concerns
        aiPlacement = AIConcernPlacement.place(refs, in: diff)
    }

    func aiConcerns(fileID: DiffFile.ID, lineID: DiffLine.ID) -> [ConcernRecord] {
        aiPlacement.concerns(fileID: fileID, lineID: lineID).compactMap { aiConcerns[$0] }
    }

    func unplacedAIConcerns(fileID: DiffFile.ID) -> [ConcernRecord] {
        (aiPlacement.unplaced[fileID] ?? []).compactMap { aiConcerns[$0] }
    }

    /// Opens the preview for posting an AI concern on its line.
    func previewPost(_ concern: ConcernRecord, fileID: DiffFile.ID, lineID: DiffLine.ID) {
        refreshPostingEnabled()
        aiPostError = nil
        aiPostDraft = AIPostDraft(concernID: concern.id, fileID: fileID, lineID: lineID,
                                  body: AICommentFormatter.body(severity: concern.severity, explanation: concern.explanation))
    }

    func postAIDraft() async {
        guard let draft = aiPostDraft, let service, let mr, let diff, let concern = aiConcerns[draft.concernID],
              let file = diff.files.first(where: { $0.id == draft.fileID }),
              let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.id == draft.lineID }) else { return }
        isPostingAI = true
        defer { isPostingAI = false }
        do {
            _ = try await service.postAIConcern(concern, body: draft.body, on: line, in: file, of: diff, mr: mr)
            aiPostDraft = nil
            onAIChange?()
            if let updated = service.cachedDiscussions(for: mr.key) { apply(updated) }
        } catch {
            aiPostError = error.localizedDescription
        }
    }

    private var discussions: [GitLabDiscussion] = []
    private var diff: MRDiff?
    private var mr: TrackedMR?
    private var service: DiscussionService?

    func load(mr: TrackedMR, diff: MRDiff, service: DiscussionService, forceRefresh: Bool = false) async {
        self.mr = mr
        self.diff = diff
        self.service = service
        isPostingEnabled = service.isPostingEnabled
        if let cached = service.cachedDiscussions(for: mr.key), !forceRefresh {
            apply(cached)
        }
        isLoading = true
        defer { isLoading = false }
        do {
            apply(try await service.discussions(for: mr, forceRefresh: forceRefresh))
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func apply(_ discussions: [GitLabDiscussion]) {
        self.discussions = discussions
        if let diff {
            placement = ThreadPlacement.place(discussions, in: diff)
        }
    }

    func threads(fileID: DiffFile.ID, lineID: DiffLine.ID) -> [GitLabDiscussion] {
        placement.files[fileID]?.byLine[lineID] ?? []
    }

    var canComment: Bool { diff?.refs != nil }

    // MARK: Composer

    func open(_ target: CommentTarget) {
        activeTarget = target
        postErrors[target] = nil
    }

    func cancel(_ target: CommentTarget) {
        drafts[target] = nil
        postErrors[target] = nil
        if activeTarget == target { activeTarget = nil }
    }

    func refreshPostingEnabled() {
        isPostingEnabled = service?.isPostingEnabled ?? false
    }

    func submit(_ target: CommentTarget) async {
        guard let service, let mr, let diff, postingTarget == nil else { return }
        let body = drafts[target] ?? ""
        postingTarget = target
        defer { postingTarget = nil }
        do {
            switch target {
            case .line(let fileID, let lineID):
                guard let file = diff.files.first(where: { $0.id == fileID }),
                      let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.id == lineID }) else { return }
                _ = try await service.createThread(on: line, in: file, of: diff, body: body, mr: mr)
            case .reply(let discussionID):
                _ = try await service.reply(to: discussionID, body: body, mr: mr)
            }
            drafts[target] = nil
            postErrors[target] = nil
            if activeTarget == target { activeTarget = nil }
            if let updated = service.cachedDiscussions(for: mr.key) { apply(updated) }
        } catch {
            postErrors[target] = error.localizedDescription
        }
    }
}

struct AIPostDraft: Identifiable, Equatable {
    var id: UUID { concernID }
    let concernID: UUID
    let fileID: DiffFile.ID
    let lineID: DiffLine.ID
    var body: String
}
