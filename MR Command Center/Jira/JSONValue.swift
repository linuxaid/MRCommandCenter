import Foundation

/// Any JSON value. Jira issue fields vary by instance (custom fields can be strings,
/// rich-text documents, option objects, arrays…), so they're decoded generically.
nonisolated enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var isNull: Bool { self == .null }

    /// Plain text for any field shape: strings, Atlassian Document Format, option objects
    /// (`value` / `name`), arrays, numbers.
    var plainText: String? {
        switch self {
        case .null: return nil
        case .string(let value): return value
        case .number(let value): return value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value): return value ? "Yes" : "No"
        case .array(let values):
            let parts = values.compactMap(\.plainText).filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object:
            if self["type"]?.string == "doc" { return ADFRenderer.render(self) }
            for key in ["value", "name", "displayName", "text"] {
                if let text = self[key]?.plainText { return text }
            }
            return nil
        }
    }
}
