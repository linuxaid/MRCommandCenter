import Foundation

/// Converts Atlassian Document Format (Jira Cloud rich text) to Markdown-ish plain text
/// that keeps structure the model can use: headings, lists, checklists, tables, code.
nonisolated enum ADFRenderer {
    static func render(_ document: JSONValue) -> String {
        var lines: [String] = []
        for node in document["content"]?.array ?? [] {
            lines.append(contentsOf: block(node, depth: 0))
        }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func block(_ node: JSONValue, depth: Int) -> [String] {
        let children = node["content"]?.array ?? []
        let indent = String(repeating: "  ", count: depth)
        switch node["type"]?.string {
        case "paragraph":
            return [indent + inline(children), ""]
        case "heading":
            var level = 2
            if case .number(let value)? = node["attrs"]?["level"] { level = Int(value) }
            return [String(repeating: "#", count: max(1, min(level, 6))) + " " + inline(children), ""]
        case "bulletList":
            return children.flatMap { listItem($0, marker: "-", depth: depth) } + (depth == 0 ? [""] : [])
        case "orderedList":
            return children.enumerated().flatMap { listItem($1, marker: "\($0 + 1).", depth: depth) } + (depth == 0 ? [""] : [])
        case "taskList":
            return children.flatMap { item -> [String] in
                let done = item["attrs"]?["state"]?.string == "DONE"
                return listItem(item, marker: done ? "- [x]" : "- [ ]", depth: depth)
            } + (depth == 0 ? [""] : [])
        case "codeBlock":
            return ["```", inline(children), "```", ""]
        case "blockquote", "panel", "expand", "nestedExpand", "layoutSection", "layoutColumn":
            var lines: [String] = []
            if let title = node["attrs"]?["title"]?.string { lines.append(indent + title) }
            for child in children { lines += block(child, depth: depth) }
            return lines
        case "rule":
            return ["---", ""]
        case "table":
            let rows = children.map { row in
                "| " + (row["content"]?.array ?? []).map { cell in
                    (cell["content"]?.array ?? []).flatMap { block($0, depth: 0) }.filter { !$0.isEmpty }.joined(separator: " ")
                }.joined(separator: " | ") + " |"
            }
            return rows + [""]
        case "mediaSingle", "mediaGroup", "media":
            return []
        default:
            let text = inline(children.isEmpty ? [node] : children)
            return text.isEmpty ? [] : [indent + text]
        }
    }

    private static func listItem(_ item: JSONValue, marker: String, depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        let children = item["content"]?.array ?? []
        // Task items hold inline content directly.
        if item["type"]?.string == "taskItem" {
            return [indent + marker + " " + inline(children)]
        }
        var lines: [String] = []
        var wroteMarker = false
        for child in children {
            switch child["type"]?.string {
            case "bulletList", "orderedList", "taskList":
                lines += block(child, depth: depth + 1)
            default:
                let text = child["type"]?.string == "paragraph"
                    ? inline(child["content"]?.array ?? [])
                    : block(child, depth: 0).filter { !$0.isEmpty }.joined(separator: " ")
                lines.append(indent + (wroteMarker ? "  " : marker + " ") + text)
                wroteMarker = true
            }
        }
        if !wroteMarker { lines.insert(indent + marker, at: 0) }
        return lines
    }

    private static func inline(_ nodes: [JSONValue]) -> String {
        nodes.map { node -> String in
            switch node["type"]?.string {
            case "text":
                let text = node["text"]?.string ?? ""
                let marks = (node["marks"]?.array ?? []).compactMap { $0["type"]?.string }
                if marks.contains("code") { return "`\(text)`" }
                if marks.contains("strong") { return "**\(text)**" }
                return text
            case "hardBreak": return "\n"
            case "mention": return node["attrs"]?["text"]?.string ?? "@someone"
            case "emoji": return node["attrs"]?["shortName"]?.string ?? ""
            case "inlineCard", "blockCard": return node["attrs"]?["url"]?.string ?? ""
            case "status": return "[\(node["attrs"]?["text"]?.string ?? "")]"
            case "date": return node["attrs"]?["timestamp"]?.plainText ?? ""
            default: return inline(node["content"]?.array ?? [])
            }
        }.joined()
    }
}

/// Finds acceptance criteria: the configured custom field if it has text, otherwise the
/// section of the description under an "Acceptance Criteria" (or "Definition of Done")
/// heading, in Markdown, Jira wiki markup, or bold-line form.
nonisolated enum AcceptanceCriteriaExtractor {
    enum Source: String, Codable, Sendable {
        case customField, description
    }

    static func fromDescription(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: isCriteriaHeading) else { return nil }
        var section: [String] = []
        for line in lines[(start + 1)...] {
            if isHeading(line) { break }
            section.append(line)
        }
        let result = section.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    static func isCriteriaHeading(_ line: String) -> Bool {
        guard isHeading(line) || line.trimmingCharacters(in: .whitespaces).hasSuffix(":") else { return false }
        let lower = line.lowercased()
        return lower.contains("acceptance criteria") || lower.contains("definition of done")
            || lower.range(of: #"\bac\b"#, options: .regularExpression) != nil
    }

    /// Markdown `#`, wiki `h1.`–`h6.`, or a line that is entirely bold.
    static func isHeading(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return true }
        if trimmed.range(of: #"^h[1-6]\.\s"#, options: .regularExpression) != nil { return true }
        if trimmed.range(of: #"^(\*\*[^*]+\*\*|\*[^*]+\*):?$"#, options: .regularExpression) != nil { return true }
        return false
    }
}
