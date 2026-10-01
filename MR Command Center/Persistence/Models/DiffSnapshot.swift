import Foundation
import SwiftData

/// GitLab's diff for one MR at one head SHA, cached so it's fetched once per commit.
/// The diff text stays on this Mac (local SwiftData store only).
@Model
final class DiffSnapshot {
    @Attribute(.unique) var id: String
    var mrKey: String
    var headSHA: String
    /// JSON-encoded `[GitLabDiff]`.
    @Attribute(.externalStorage) var filesData: Data
    var changesCount: String?
    var fetchedAt: Date
    /// `diff_refs` at fetch time, so comments anchor to exactly the version shown.
    var baseSHA: String?
    var startSHA: String?

    init(mrKey: String, headSHA: String, diffs: [GitLabDiff], changesCount: String?, refs: DiffRefs?, fetchedAt: Date = .now) throws {
        id = Self.makeID(mrKey: mrKey, headSHA: headSHA)
        self.mrKey = mrKey
        self.headSHA = headSHA
        filesData = try JSONEncoder().encode(diffs)
        self.changesCount = changesCount
        self.fetchedAt = fetchedAt
        baseSHA = refs?.baseSHA
        startSHA = refs?.startSHA
    }

    var refs: DiffRefs? {
        guard let baseSHA, let startSHA else { return nil }
        return DiffRefs(baseSHA: baseSHA, startSHA: startSHA, headSHA: headSHA)
    }

    static func makeID(mrKey: String, headSHA: String) -> String {
        "\(mrKey)@\(headSHA)"
    }

    func decodedDiffs() throws -> [GitLabDiff] {
        try JSONDecoder().decode([GitLabDiff].self, from: filesData)
    }
}
