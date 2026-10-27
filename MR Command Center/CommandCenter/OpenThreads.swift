import Foundation
import Observation

/// The MR's unresolved comment threads, summarized for the brief (#28): where each one is,
/// what it says, who spoke last, and whether it's waiting on you.
struct OpenThread: Identifiable, Equatable {
    let id: String
    /// The file, or nil for a general thread on the MR.
    let path: String?
    /// The new-side line, which is what the diff can jump to. Nil for threads on a removed line
    /// (they open at their file instead) and for general threads.
    let line: Int?
    /// The old-side line, for threads on removed lines (shown, not jumped to).
    let oldLine: Int?
    let startedBy: String
    let firstNote: String
    let lastReplyBy: String?
    let noteCount: Int
    let waitingOnMe: Bool
    let lastActivity: Date?

    var location: String {
        guard let path else { return "General" }
        let file = (path as NSString).lastPathComponent
        if let line { return "\(file):\(line)" }
        if let oldLine { return "\(file):\(oldLine) (removed)" }
        return file
    }

    /// Open threads, the ones waiting on you first, then newest activity first.
    static func open(in discussions: [GitLabDiscussion], me: String?, isMyMR: Bool) -> [OpenThread] {
        discussions.compactMap { thread -> OpenThread? in
            guard thread.isUnresolved else { return nil }
            let notes = thread.userNotes
            guard let first = notes.first else { return nil }
            let last = notes.last
            let position = thread.position
            return OpenThread(
                id: thread.id,
                path: position.flatMap { $0.newPath ?? $0.oldPath },
                line: position?.newLine,
                oldLine: position?.newLine == nil ? position?.oldLine : nil,
                startedBy: first.author?.name ?? "Someone",
                firstNote: (first.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                lastReplyBy: notes.count > 1 ? last?.author?.name : nil,
                noteCount: notes.count,
                waitingOnMe: ThreadTurns.isWaitingOnMe(thread, me: me, isMyMR: isMyMR),
                lastActivity: last?.createdAt
            )
        }
        .sorted { a, b in
            if a.waitingOnMe != b.waitingOnMe { return a.waitingOnMe }
            return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
    }
}

/// The brief's Open threads card (#28): loads the threads and resolves them. Rows always come
/// from `DiscussionService`'s cache, which the diff's threads share, so both stay in step.
@Observable
final class OpenThreadsModel {
    private(set) var threads: [OpenThread] = []
    /// The first load finished (successfully or not); before that the card shows a spinner.
    private(set) var hasLoaded = false
    private(set) var loadError: String?
    private(set) var resolving: Set<String> = []
    private(set) var errors: [String: String] = [:]
    /// Bumped by every load and resolve, so a slow, older load can't put back a resolved row.
    private var generation = 0

    /// `force` skips the short discussion cache, for when the MR changed on GitLab.
    func load(_ mr: TrackedMR, service: DiscussionService, me: String?, force: Bool) async {
        generation += 1
        let mine = generation
        do {
            let discussions = try await service.discussions(for: mr, forceRefresh: force)
            guard mine == generation else { return }
            threads = OpenThread.open(in: discussions, me: me, isMyMR: mr.isAuthor)
            loadError = nil
        } catch is CancellationError {
            return
        } catch {
            guard mine == generation else { return }
            loadError = error.localizedDescription
        }
        hasLoaded = true
    }

    /// Resolves on GitLab, then shows the threads as they are now (including any that arrived).
    /// A failure keeps the row and shows why.
    func resolve(_ thread: OpenThread, on mr: TrackedMR, service: DiscussionService, me: String?) async {
        guard !resolving.contains(thread.id) else { return }
        generation += 1
        resolving.insert(thread.id)
        defer { resolving.remove(thread.id) }
        errors[thread.id] = nil
        do {
            try await service.setResolved(thread.id, resolved: true, mr: mr)
            if let cached = service.cachedDiscussions(for: mr.key) {
                threads = OpenThread.open(in: cached, me: me, isMyMR: mr.isAuthor)
            } else {
                threads.removeAll { $0.id == thread.id }
            }
        } catch {
            errors[thread.id] = error.localizedDescription
        }
    }
}
