import Foundation

/// Comment threads for one file, grouped by where they can be shown.
nonisolated struct FileThreads: Sendable, Equatable {
    /// Threads anchored to a line visible in the diff, keyed by `DiffLine.id`.
    var byLine: [DiffLine.ID: [GitLabDiscussion]] = [:]
    /// Current-version threads on lines outside the shown hunks (e.g. on expanded context).
    var offDiff: [GitLabDiscussion] = []
    /// Threads left on an older version whose line changed since.
    var outdated: [GitLabDiscussion] = []

    var all: [GitLabDiscussion] { byLine.values.flatMap { $0 } + offDiff + outdated }
    var count: Int { byLine.values.reduce(0) { $0 + $1.count } + offDiff.count + outdated.count }
    var unresolvedCount: Int { all.count(where: \.isUnresolved) }
}

/// Where each diff comment thread belongs in the Changes view.
nonisolated struct ThreadPlacement: Sendable, Equatable {
    var files: [DiffFile.ID: FileThreads] = [:]
    /// Diff threads on files that are no longer part of this diff.
    var orphaned: [GitLabDiscussion] = []

    func threads(for fileID: DiffFile.ID) -> FileThreads {
        files[fileID] ?? FileThreads()
    }

    /// Places diff threads. A thread is current when its position's `head_sha` matches the
    /// diff's head (GitLab re-anchors positions on unchanged lines after new pushes);
    /// otherwise it's outdated. General (non-diff) threads are ignored here.
    static func place(_ discussions: [GitLabDiscussion], in diff: MRDiff) -> ThreadPlacement {
        var placement = ThreadPlacement()
        for discussion in discussions {
            guard let position = discussion.position, !discussion.userNotes.isEmpty else { continue }
            guard let file = diff.files.first(where: { matches(position, $0) }) else {
                placement.orphaned.append(discussion)
                continue
            }
            var threads = placement.files[file.id] ?? FileThreads()
            if let head = position.headSha, head != diff.headSHA {
                threads.outdated.append(discussion)
            } else if let line = line(for: position, in: file) {
                threads.byLine[line.id, default: []].append(discussion)
            } else {
                threads.offDiff.append(discussion)
            }
            placement.files[file.id] = threads
        }
        return placement
    }

    static func matches(_ position: GitLabNotePosition, _ file: DiffFile) -> Bool {
        if let newPath = position.newPath, newPath == file.newPath { return true }
        if let oldPath = position.oldPath, oldPath == file.oldPath, file.change != .added { return true }
        return false
    }

    /// New-side line for added/context lines; old-side line for removed lines.
    static func line(for position: GitLabNotePosition, in file: DiffFile) -> DiffLine? {
        let lines = file.hunks.lazy.flatMap(\.lines)
        if let newLine = position.newLine {
            return lines.first { $0.kind != .deletion && $0.kind != .noNewline && $0.newNumber == newLine }
        }
        if let oldLine = position.oldLine {
            return lines.first { $0.kind != .addition && $0.kind != .noNewline && $0.oldNumber == oldLine }
        }
        return nil
    }

    /// The position to send when commenting on a line.
    static func newDiscussion(body: String, line: DiffLine, file: DiffFile, refs: DiffRefs) -> NewDiffDiscussionRequest {
        let (oldLine, newLine): (Int?, Int?) = switch line.kind {
        case .addition: (nil, line.newNumber)
        case .deletion: (line.oldNumber, nil)
        case .context, .noNewline: (line.oldNumber, line.newNumber)
        }
        return NewDiffDiscussionRequest(body: body, refs: refs, oldPath: file.oldPath, newPath: file.newPath,
                                        oldLine: oldLine, newLine: newLine)
    }
}
