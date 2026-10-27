import Foundation

/// A discussion thread: a diff comment thread, a general MR thread, or a system note.
/// Note bodies are user content: they stay in memory and the local store and are never logged.
nonisolated struct GitLabDiscussion: Decodable, Sendable, Equatable, Identifiable {
    nonisolated struct Note: Decodable, Sendable, Equatable, Identifiable {
        let id: Int
        var resolvable: Bool?
        var resolved: Bool?
        var system: Bool?
        var body: String?
        var author: GitLabUserRef?
        var createdAt: Date?
        /// `DiffNote` for comments on a diff line.
        var type: String?
        var position: GitLabNotePosition?
        var resolvedBy: GitLabUserRef?
    }

    let id: String
    var individualNote: Bool?
    var notes: [Note]?

    var isResolvable: Bool { notes?.contains { $0.resolvable == true } ?? false }
    var isUnresolved: Bool { notes?.contains { $0.resolvable == true && $0.resolved != true } ?? false }
    var isResolved: Bool { isResolvable && !isUnresolved }

    /// Position of the thread's first diff note, if this is a diff thread.
    var position: GitLabNotePosition? { notes?.first?.position }
    var userNotes: [Note] { notes?.filter { $0.system != true } ?? [] }
}

/// Where a diff comment is attached. Uses new-side lines for added/context lines and
/// old-side lines for removed lines; context lines carry both.
nonisolated struct GitLabNotePosition: Codable, Sendable, Equatable, Hashable {
    var baseSha: String?
    var startSha: String?
    var headSha: String?
    var oldPath: String?
    var newPath: String?
    var positionType: String?
    var oldLine: Int?
    var newLine: Int?
}

/// The three SHAs GitLab needs to anchor a new diff comment (`diff_refs` on the MR).
nonisolated struct DiffRefs: Codable, Sendable, Equatable, Hashable {
    let baseSHA: String
    let startSHA: String
    let headSHA: String
}

/// Body for `POST /projects/:id/merge_requests/:iid/discussions` with a text position.
nonisolated struct NewDiffDiscussionRequest: Encodable, Sendable, Equatable {
    let body: String
    let position: GitLabNotePosition

    init(body: String, refs: DiffRefs, oldPath: String, newPath: String, oldLine: Int?, newLine: Int?) {
        self.body = body
        position = GitLabNotePosition(
            baseSha: refs.baseSHA, startSha: refs.startSHA, headSha: refs.headSHA,
            oldPath: oldPath, newPath: newPath, positionType: "text",
            oldLine: oldLine, newLine: newLine
        )
    }
}

/// Body for `PUT /projects/:id/merge_requests/:iid/discussions/:discussion_id`.
nonisolated struct ResolveDiscussionRequest: Encodable, Sendable, Equatable {
    let resolved: Bool
}

nonisolated struct NewNoteRequest: Encodable, Sendable, Equatable {
    let body: String
}
