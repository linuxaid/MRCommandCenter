import Foundation

/// Realistic comment threads for a couple of mock MRs: on added lines, on a removed line,
/// resolved, outdated (left on an older commit), and a general comment.
nonisolated enum MockDiscussions {
    static func threads(forIID iid: Int, headSHA: String) -> [GitLabDiscussion]? {
        switch iid {
        case 412: webhookRetries(headSHA: headSHA)
        case 1880: currencyRounding(headSHA: headSHA)
        default: nil
        }
    }

    private static let dana = GitLabUserRef(id: 31, username: "dana", name: "Dana Okafor")
    private static let priya = GitLabUserRef(id: 17, username: "priya", name: "Priya Natarajan")
    private static let sam = GitLabUserRef(id: 44, username: "samlee", name: "Sam Lee")
    private static let lena = GitLabUserRef(id: 52, username: "lena", name: "Lena Fischer")
    private static let me = GitLabUserRef(id: MockGitLabData.me.id, username: MockGitLabData.me.username, name: MockGitLabData.me.name)
    private static let reference = Date(timeIntervalSince1970: 1_790_000_000)

    private static func position(_ path: String, old: Int? = nil, new: Int? = nil, head: String) -> GitLabNotePosition {
        GitLabNotePosition(baseSha: String(repeating: "0", count: 40), startSha: String(repeating: "0", count: 40), headSha: head,
                           oldPath: path, newPath: path, positionType: "text", oldLine: old, newLine: new)
    }

    private static func thread(
        _ id: String, at position: GitLabNotePosition?, resolved: Bool?,
        _ notes: [(GitLabUserRef, String, hoursAgo: Double)]
    ) -> GitLabDiscussion {
        GitLabDiscussion(id: id, individualNote: position == nil && resolved == nil, notes: notes.enumerated().map { index, note in
            GitLabDiscussion.Note(
                id: abs(id.unicodeScalars.reduce(0) { $0 &* 31 &+ Int($1.value) } % 1_000_000) * 10 + index,
                resolvable: resolved != nil, resolved: resolved, system: false,
                body: note.1, author: note.0, createdAt: reference.addingTimeInterval(-note.hoursAgo * 3600),
                type: position == nil ? "DiscussionNote" : "DiffNote", position: position
            )
        })
    }

    static func webhookRetries(headSHA: String) -> [GitLabDiscussion] {
        let file = "app/webhooks/delivery.py"
        return [
            thread("412-429", at: position(file, new: 40, head: headSHA), resolved: false, [
                (dana, "Should a `429` really be a permanent failure? Most providers send `Retry-After`.", 5),
                (priya, "Good catch. I'll honor `Retry-After` and retry those.", 4),
            ]),
            thread("412-metric", at: position("app/webhooks/backoff.py", new: 12, head: headSHA), resolved: false, [
                (me, "Can we count deliveries that run out of retries? We'll want an alert on that.", 3),
                (priya, "Added `webhook_retry_exhausted_total`. Does that work for you?", 1),
            ]),
            thread("412-print", at: position(file, new: 42, head: headSHA), resolved: false, [
                (dana, "Leftover debug **print**? This will spam stdout in production.", 5),
            ]),
            thread("412-oldlog", at: position(file, old: 33, head: headSHA), resolved: true, [
                (sam, "We lose the status code in this log line now, which was handy when debugging.", 6),
                (priya, "It's in the new warning when we give up. Resolving.", 5.5),
            ]),
            thread("412-backoff", at: position("app/webhooks/backoff.py", new: 8, head: headSHA), resolved: true, [
                (dana, "Consider capping the total retry time as well as each delay.", 7),
            ]),
            thread("412-outdated", at: position(file, new: 30, head: String(repeating: "1", count: 40)), resolved: true, [
                (dana, "Nit: the timeout should come from config, not a constant.", 30),
                (priya, "Done in the latest push.", 26),
            ]),
            thread("412-general", at: nil, resolved: nil, [
                (sam, "Thanks for picking this up! Webhook retries have been on our list for a while.", 20),
            ]),
        ]
    }

    static func currencyRounding(headSHA: String) -> [GitLabDiscussion] {
        [
            thread("1880-kwd", at: position("src/orders/totals.ts", new: 4, head: headSHA), resolved: true, [
                (dana, "Should KWD use banker's rounding instead of `Math.round`?", 18),
                (lena, "Finance confirmed half-up is what they expect.", 16),
            ]),
        ]
    }
}
