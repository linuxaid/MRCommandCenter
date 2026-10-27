import Foundation

/// The MR's unresolved comment threads, summarized for the brief (#28): where each one is,
/// what it says, who spoke last, and whether it's waiting on you.
struct OpenThread: Identifiable, Equatable {
    let id: String
    /// `app/webhooks/delivery.py:40`, or nil for a general thread on the MR.
    let path: String?
    let line: Int?
    let startedBy: String
    let firstNote: String
    let lastReplyBy: String?
    let noteCount: Int
    let waitingOnMe: Bool
    let lastActivity: Date?

    var location: String {
        guard let path else { return "General" }
        let file = (path as NSString).lastPathComponent
        return line.map { "\(file):\($0)" } ?? file
    }

    /// Open threads, the ones waiting on you first, then newest activity first.
    static func open(in discussions: [GitLabDiscussion], me: String?, isMyMR: Bool) -> [OpenThread] {
        discussions.compactMap { thread -> OpenThread? in
            guard thread.isUnresolved else { return nil }
            let notes = thread.userNotes
            guard let first = notes.first else { return nil }
            let last = notes.last
            let position = thread.position
            let lastIsMe = last?.author?.username == me
            let involved = isMyMR || notes.contains { $0.author?.username == me }
            return OpenThread(
                id: thread.id,
                path: position.flatMap { $0.newPath ?? $0.oldPath },
                line: position.flatMap { $0.newLine ?? $0.oldLine },
                startedBy: first.author?.name ?? "Someone",
                firstNote: (first.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                lastReplyBy: notes.count > 1 ? last?.author?.name : nil,
                noteCount: notes.count,
                waitingOnMe: me != nil && involved && !lastIsMe,
                lastActivity: last?.createdAt
            )
        }
        .sorted { a, b in
            if a.waitingOnMe != b.waitingOnMe { return a.waitingOnMe }
            return (a.lastActivity ?? .distantPast) > (b.lastActivity ?? .distantPast)
        }
    }
}
