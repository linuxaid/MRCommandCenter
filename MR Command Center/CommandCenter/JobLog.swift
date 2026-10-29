import Foundation

/// A CI job's log made readable in the app (#35). GitLab sends the raw terminal output: colour
/// codes, collapsible-section markers, and progress lines redrawn with carriage returns.
nonisolated enum JobLog {
    /// How many lines to show. Failures are almost always at the end, and the full log is a
    /// click away in GitLab.
    static let tailLength = 200

    /// The log as plain lines, the way a terminal would end up showing them.
    static func lines(_ raw: String) -> [String] {
        let lines = drawnLines(raw)
        // Trailing blank lines are just the log's final newlines.
        let end = lines.lastIndex { !$0.isEmpty }.map { $0 + 1 } ?? 0
        return Array(lines[..<end])
    }

    private static func drawnLines(_ raw: String) -> [String] {
        // `Regex` isn't `Sendable`, so it's built per call rather than kept in a static.
        let sectionMarker = /section_(?:start|end):\d+:[A-Za-z0-9_.\-]+(?:\[[^\]]*\])?/
        // Split on the scalar: `\r\n` is one `Character`, so splitting on "\n" would miss it.
        return raw.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { scalars in
            var line = String(String.UnicodeScalarView(scalars))
            while line.hasSuffix("\r") { line.removeLast() }
            line = stripEscapes(line)
            // A carriage return redraws the line: only the last drawing is left on screen.
            if let last = line.split(separator: "\r", omittingEmptySubsequences: false).last {
                line = String(last)
            }
            // `section_start:1700000000:step_script[collapsed=true]` and `section_end:…:step_script`.
            return line.replacing(sectionMarker, with: "")
        }
    }

    /// The last `tailLength` lines, and how many were left out before them.
    static func tail(_ raw: String, length: Int = tailLength) -> (lines: [String], omitted: Int) {
        let all = lines(raw)
        let shown = Array(all.suffix(length))
        return (shown, all.count - shown.count)
    }

    /// Terminal escape sequences: colours and cursor/erase commands (`ESC [ ... letter`).
    private static func stripEscapes(_ line: String) -> String {
        guard line.contains("\u{1B}") else { return line }
        var result = ""
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\u{1B}" {
                index = line.index(after: index)
                if index < line.endIndex, line[index] == "[" {
                    index = line.index(after: index)
                    // Parameters and intermediates, then one final letter.
                    while index < line.endIndex, !(line[index].isLetter || line[index] == "~") {
                        index = line.index(after: index)
                    }
                    if index < line.endIndex { index = line.index(after: index) }
                }
                continue
            }
            result.append(character)
            index = line.index(after: index)
        }
        return result
    }

}
