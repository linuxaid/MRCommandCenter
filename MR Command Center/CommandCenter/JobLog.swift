import Foundation

/// A CI job's log made readable in the app (#35). GitLab sends the raw terminal output: colour
/// codes, collapsible-section markers, and progress lines redrawn with carriage returns.
nonisolated enum JobLog {
    /// How many lines to show. Failures are almost always at the end, and the full log is a
    /// click away in GitLab.
    static let tailLength = 200
    /// Extra raw lines cleaned beyond the tail, to make up for the ones cleaning drops
    /// (section markers, trailing blank lines).
    private static let slack = 50

    /// The log as plain lines, the way GitLab's log viewer shows them.
    static func lines(_ raw: String) -> [String] {
        clean(rawLines(raw)[...])
    }

    /// The last `length` lines, and roughly how many came before them. Logs can run to
    /// megabytes, so only the end is cleaned.
    static func tail(_ raw: String, length: Int = tailLength) -> (lines: [String], omitted: Int) {
        let all = rawLines(raw)
        let window = all.suffix(length + slack)
        let cleaned = clean(window)
        let shown = Array(cleaned.suffix(length))
        return (shown, all.count - window.count + cleaned.count - shown.count)
    }

    /// Split on the scalar: `\r\n` is one `Character`, so splitting a `String` on "\n" would miss
    /// it. A lone `\r` isn't a line break; it redraws the line.
    private static func rawLines(_ raw: String) -> [Substring.UnicodeScalarView] {
        raw.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
            .map { Substring.UnicodeScalarView($0) }
    }

    private static func clean(_ rawLines: ArraySlice<Substring.UnicodeScalarView>) -> [String] {
        // `Regex` isn't `Sendable`, so it's built per call rather than kept in a static.
        // `section_start:1700000000:step_script[collapsed=true]` and `section_end:…:step_script`.
        let sectionMarker = /section_(?:start|end):\d+:[A-Za-z0-9_.\-]+(?:\[[^\]]*\])?/
        var lines: [String] = []
        lines.reserveCapacity(rawLines.count)
        for scalars in rawLines {
            var line = String(scalars)
            while line.hasSuffix("\r") { line.removeLast() }
            line = stripEscapes(line)
            let hadMarker = line.contains("section_")
            // A carriage return redraws the line: only the last drawing is left on screen.
            if let last = line.split(separator: "\r", omittingEmptySubsequences: false).last {
                line = String(last)
            }
            line = line.replacing(sectionMarker, with: "")
            // A line that was only a section marker isn't shown at all, as in GitLab.
            if hadMarker, line.isEmpty { continue }
            lines.append(line)
        }
        // Trailing blank lines are just the log's final newlines.
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Terminal escape sequences: CSI (`ESC [ … final`, colours and erasing), OSC (`ESC ] … BEL`
    /// or `ESC \`, such as hyperlinks), and two-character ones like charset selects (`ESC ( B`).
    private static func stripEscapes(_ line: String) -> String {
        guard line.unicodeScalars.contains("\u{1B}") else { return line }
        let scalars = Array(line.unicodeScalars)
        var result = String.UnicodeScalarView()
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "\u{1B}" else {
                result.append(scalars[index])
                index += 1
                continue
            }
            index += 1
            guard index < scalars.count else { break }
            switch scalars[index] {
            case "[":
                index += 1
                // Parameters and intermediates, then one final byte from @ to ~.
                while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) { index += 1 }
                index += 1
            case "]":
                index += 1
                while index < scalars.count {
                    if scalars[index] == "\u{07}" { index += 1; break }
                    if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" { index += 2; break }
                    index += 1
                }
            case "(", ")", "*", "+":
                index += 2
            default:
                index += 1
            }
        }
        return String(result)
    }
}
