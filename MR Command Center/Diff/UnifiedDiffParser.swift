import Foundation

nonisolated struct DiffLine: Identifiable, Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case context, addition, deletion
        /// `\ No newline at end of file`
        case noNewline
    }

    let id: Int
    let kind: Kind
    let oldNumber: Int?
    let newNumber: Int?
    let text: String
}

nonisolated struct DiffHunk: Identifiable, Sendable, Equatable {
    let id: Int
    let header: String
    let oldStart: Int
    let oldCount: Int
    let newStart: Int
    let newCount: Int
    /// Text after the second `@@`, usually the enclosing function.
    let section: String
    let lines: [DiffLine]
}

/// Parses the hunk body of a unified diff (what GitLab returns in `diff`).
nonisolated enum UnifiedDiffParser {
    static func parse(_ text: String) -> [DiffHunk] {
        // Split on any newline Character: Swift treats "\r\n" as a single Character,
        // so splitting on "\n" alone would leave CRLF diffs as one line.
        var rawLines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if rawLines.last == "" { rawLines.removeLast() }

        var hunks: [DiffHunk] = []
        var header: HunkHeader?
        var lines: [DiffLine] = []
        var oldLine = 0
        var newLine = 0

        func flush() {
            guard let header else { return }
            hunks.append(DiffHunk(
                id: hunks.count, header: header.raw,
                oldStart: header.oldStart, oldCount: header.oldCount,
                newStart: header.newStart, newCount: header.newCount,
                section: header.section, lines: lines
            ))
            lines = []
        }

        for raw in rawLines {
            let line = raw

            if line.hasPrefix("@@"), let parsed = HunkHeader(line) {
                flush()
                header = parsed
                oldLine = parsed.oldStart
                newLine = parsed.newStart
                continue
            }
            // Ignore file headers (`diff --git`, `---`, `+++`, `index`) before the first hunk.
            guard header != nil else { continue }

            let id = hunks.count * 1_000_000 + lines.count
            let body = String(line.dropFirst())
            switch line.first {
            case "+":
                lines.append(DiffLine(id: id, kind: .addition, oldNumber: nil, newNumber: newLine, text: body))
                newLine += 1
            case "-":
                lines.append(DiffLine(id: id, kind: .deletion, oldNumber: oldLine, newNumber: nil, text: body))
                oldLine += 1
            case "\\":
                lines.append(DiffLine(id: id, kind: .noNewline, oldNumber: nil, newNumber: nil, text: body.trimmingCharacters(in: .whitespaces)))
            default:
                // " " context, or an empty line some tools emit for a blank context line.
                lines.append(DiffLine(id: id, kind: .context, oldNumber: oldLine, newNumber: newLine, text: body))
                oldLine += 1
                newLine += 1
            }
        }
        flush()
        return hunks
    }

    private struct HunkHeader {
        let raw: String
        let oldStart: Int
        let oldCount: Int
        let newStart: Int
        let newCount: Int
        let section: String

        nonisolated init?(_ line: Substring) {
            // @@ -oldStart[,oldCount] +newStart[,newCount] @@ section
            guard let match = line.wholeMatch(of: #/@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@ ?(.*)/#) else {
                return nil
            }
            raw = String(line)
            oldStart = Int(match.1) ?? 0
            oldCount = match.2.flatMap { Int($0) } ?? 1
            newStart = Int(match.3) ?? 0
            newCount = match.4.flatMap { Int($0) } ?? 1
            section = String(match.5)
        }
    }
}
