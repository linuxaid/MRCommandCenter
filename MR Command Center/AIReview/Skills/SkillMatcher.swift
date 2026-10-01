import Darwin
import Foundation

nonisolated enum SkillMatcher {
    /// Case-insensitive glob match. Patterns containing `/` match the whole path;
    /// others match the file name. `*` alone matches every file.
    static func matches(_ path: String, pattern: String) -> Bool {
        let pattern = pattern.trimmingCharacters(in: .whitespaces)
        guard !pattern.isEmpty else { return false }
        let subject = pattern.contains("/") ? path : (path as NSString).lastPathComponent
        // `**/` is treated like `*/` since fnmatch without FNM_PATHNAME lets `*` cross `/`.
        let normalized = pattern.replacingOccurrences(of: "**/", with: "*")
        return fnmatch(normalized, subject, FNM_CASEFOLD) == 0
    }

    static func skills(for path: String, from skills: [SkillSnapshot]) -> [SkillSnapshot] {
        skills.filter { skill in skill.appliesTo.contains { matches(path, pattern: $0) } }
    }
}

/// Markdown skill files with a small front-matter header, for sharing skills across a team:
///
///     ---
///     name: Python
///     applies_to: "*.py, *.pyi"
///     ---
///     - Check for mutable default arguments.
nonisolated enum SkillFile {
    struct Parsed: Equatable {
        var name: String
        var appliesTo: [String]
        var content: String
    }

    enum ParseError: LocalizedError, Equatable {
        case missingName
        case emptyContent

        var errorDescription: String? {
            switch self {
            case .missingName: "The skill file needs a name: line in its header."
            case .emptyContent: "The skill file has no guidance text."
            }
        }
    }

    static func parse(_ text: String, fallbackName: String? = nil) throws(ParseError) -> Parsed {
        var name = fallbackName
        var appliesTo: [String] = []
        var body = text.replacingOccurrences(of: "\r\n", with: "\n")

        if body.hasPrefix("---\n"), let end = body.range(of: "\n---", range: body.index(body.startIndex, offsetBy: 4)..<body.endIndex) {
            let header = body[body.index(body.startIndex, offsetBy: 4)..<end.lowerBound]
            body = String(body[end.upperBound...])
            for line in header.split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch parts[0].lowercased() {
                case "name": name = value
                case "applies_to", "appliesto", "globs":
                    appliesTo = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                default: continue
                }
            }
        }

        let content = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let name, !name.isEmpty else { throw .missingName }
        guard !content.isEmpty else { throw .emptyContent }
        return Parsed(name: name, appliesTo: appliesTo.isEmpty ? ["*"] : appliesTo, content: content)
    }

    static func render(name: String, appliesTo: [String], content: String) -> String {
        """
        ---
        name: \(name)
        applies_to: "\(appliesTo.joined(separator: ", "))"
        ---
        \(content.trimmingCharacters(in: .whitespacesAndNewlines))

        """
    }
}
