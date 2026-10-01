import Foundation

/// A row in the side-by-side view: deletions on the left, additions on the right.
nonisolated struct SplitRow: Identifiable, Sendable, Equatable {
    let id: Int
    let left: DiffLine?
    let right: DiffLine?
}

nonisolated enum SideBySide {
    /// Pairs each run of deletions with the run of additions that follows it.
    static func rows(for hunk: DiffHunk) -> [SplitRow] {
        var rows: [SplitRow] = []
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []

        func flush() {
            for index in 0..<max(deletions.count, additions.count) {
                let left = index < deletions.count ? deletions[index] : nil
                let right = index < additions.count ? additions[index] : nil
                rows.append(SplitRow(id: (left ?? right)!.id, left: left, right: right))
            }
            deletions = []
            additions = []
        }

        for line in hunk.lines {
            switch line.kind {
            case .deletion:
                if !additions.isEmpty { flush() }
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .context:
                flush()
                rows.append(SplitRow(id: line.id, left: line, right: line))
            case .noNewline:
                continue
            }
        }
        flush()
        return rows
    }
}
