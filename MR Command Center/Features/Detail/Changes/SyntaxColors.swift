import SwiftUI

/// Xcode's default (light) theme colors, the de facto standard for code on a Mac.
enum SyntaxColors {
    static func color(for kind: SyntaxKind) -> Color {
        switch kind {
        case .keyword: Color(hex: 0x9B2393)
        case .string: Color(hex: 0xC41A16)
        case .comment: Color(hex: 0x5D6C79)
        case .number: Color(hex: 0x1C00CF)
        case .type: Color(hex: 0x3900A0)
        case .attribute: Color(hex: 0x815F03)
        case .directive: Color(hex: 0x643820)
        }
    }

    /// The line's display text with its tokens colored; keywords are semibold, as in Xcode.
    static func attributed(_ text: String, tokens: [SyntaxToken]) -> AttributedString {
        guard !tokens.isEmpty else { return AttributedString(text) }
        let chars = Array(text)
        var result = AttributedString()
        var position = 0
        for token in tokens.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            let lower = min(max(token.range.lowerBound, position), chars.count)
            let upper = min(token.range.upperBound, chars.count)
            if lower > position { result += AttributedString(String(chars[position..<lower])) }
            guard upper > lower else { continue }
            var run = AttributedString(String(chars[lower..<upper]))
            run.foregroundColor = color(for: token.kind)
            if token.kind == .keyword { run.inlinePresentationIntent = .stronglyEmphasized }
            result += run
            position = upper
        }
        if position < chars.count { result += AttributedString(String(chars[position...])) }
        return result
    }
}
