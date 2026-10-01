import Foundation

/// A parsed file change, ready for display and (later) AI review.
nonisolated struct DiffFile: Identifiable, Sendable, Equatable {
    enum Change: Sendable, Equatable {
        case added, deleted, renamed, modified
    }

    /// Why a file has no diff to show.
    enum Unavailable: Sendable, Equatable {
        case binary
        case tooLarge
        case collapsed
        case renamedWithoutChanges
        case empty
    }

    let id: String
    let oldPath: String
    let newPath: String
    let change: Change
    let isGenerated: Bool
    /// GitLab sent the diff but flagged it as collapsed; show it collapsed by default.
    let isCollapsedByGitLab: Bool
    let unavailable: Unavailable?
    let hunks: [DiffHunk]
    let additions: Int
    let deletions: Int

    var path: String { change == .deleted ? oldPath : newPath }
    var fileName: String { (path as NSString).lastPathComponent }
    var directory: String {
        let dir = (path as NSString).deletingLastPathComponent
        return dir.isEmpty ? "" : dir + "/"
    }

    /// Lines shown in the diff, used for the collapse threshold.
    var lineCount: Int { hunks.reduce(0) { $0 + $1.lines.count } }

    init(_ diff: GitLabDiff, index: Int) {
        id = "\(index):\(diff.newPath)"
        oldPath = diff.oldPath
        newPath = diff.newPath
        change = diff.newFile ? .added : diff.deletedFile ? .deleted : diff.renamedFile ? .renamed : .modified
        isGenerated = diff.generatedFile ?? false

        let text = diff.diff
        let hunks = text.isEmpty ? [] : UnifiedDiffParser.parse(text)
        let lines = hunks.lazy.flatMap(\.lines)
        additions = lines.count { $0.kind == .addition }
        deletions = lines.count { $0.kind == .deletion }
        self.hunks = hunks

        if diff.tooLarge == true {
            unavailable = .tooLarge
        } else if Self.isBinary(text) {
            unavailable = .binary
        } else if hunks.isEmpty && diff.collapsed == true {
            unavailable = .collapsed
        } else if hunks.isEmpty && change == .renamed {
            unavailable = .renamedWithoutChanges
        } else if hunks.isEmpty {
            unavailable = .empty
        } else {
            unavailable = nil
        }
        isCollapsedByGitLab = diff.collapsed == true && unavailable == nil
    }

    static func isBinary(_ text: String) -> Bool {
        text.hasPrefix("Binary files ") || text.contains("\nBinary files ") || text.hasPrefix("GIT binary patch")
    }
}

/// The diff for one MR at one head SHA.
nonisolated struct MRDiff: Sendable, Equatable {
    let headSHA: String
    let files: [DiffFile]
    /// GitLab's `changes_count`, e.g. "12" or "1000+".
    let changesCount: String?
    let fetchedAt: Date
    /// Needed to post new diff comments; nil if GitLab didn't send `diff_refs`.
    let refs: DiffRefs?

    var additions: Int { files.reduce(0) { $0 + $1.additions } }
    var deletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// GitLab returned fewer files than the MR changes (its diff limits were hit).
    var isOverflow: Bool {
        guard let changesCount else { return false }
        if changesCount.hasSuffix("+") { return true }
        return (Int(changesCount) ?? 0) > files.count
    }

    init(headSHA: String, diffs: [GitLabDiff], changesCount: String?, fetchedAt: Date, refs: DiffRefs? = nil) {
        self.headSHA = headSHA
        files = diffs.enumerated().map { DiffFile($1, index: $0) }
        self.changesCount = changesCount
        self.fetchedAt = fetchedAt
        self.refs = refs
    }
}
