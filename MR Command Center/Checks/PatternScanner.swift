import Foundation

/// Flags likely secrets, debug output, and TODO markers in *added* lines only.
nonisolated enum PatternScanner {
    struct SecretRule {
        let name: String
        let regex: Regex<AnyRegexOutput>
    }

    /// Built-in secret patterns. Deliberately conservative to keep false positives low.
    static let secretPatterns: [(name: String, pattern: String)] = [
        ("AWS access key ID", #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#),
        ("GitHub token", #"\bgh[pousr]_[A-Za-z0-9]{36,}\b"#),
        ("GitLab token", #"\bglpat-[A-Za-z0-9_\-]{20,}"#),
        ("Slack token", #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#),
        ("Stripe live key", #"\b(sk|rk)_live_[0-9A-Za-z]{20,}"#),
        ("Google API key", #"\bAIza[0-9A-Za-z\-_]{35}\b"#),
        ("Private key", #"-----BEGIN ([A-Z]+ )?PRIVATE KEY-----"#),
        ("Hard-coded credential", #"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token)\b\s*[:=]\s*["'][^"'\s]{8,}["']"#),
    ]

    /// `Regex` isn't Sendable, so rules are compiled per scan rather than stored statically.
    static func compiledSecretRules() -> [SecretRule] {
        secretPatterns.compactMap { rule in
            (try? Regex(rule.pattern)).map { SecretRule(name: rule.name, regex: $0) }
        }
    }

    static func scan(_ files: [DiffFile], debugPatterns: [String], todoMarkers: [String]) -> [PatternFinding] {
        var findings: [PatternFinding] = []
        let rules = compiledSecretRules()
        for file in files where !file.isGenerated && file.unavailable == nil {
            for line in file.hunks.lazy.flatMap(\.lines) where line.kind == .addition {
                guard let number = line.newNumber else { continue }
                findings += scan(line: line.text, path: file.path, number: number, secretRules: rules,
                                 debugPatterns: debugPatterns, todoMarkers: todoMarkers)
            }
        }
        return findings
    }

    static func scan(line text: String, path: String, number: Int, secretRules: [SecretRule]? = nil,
                     debugPatterns: [String], todoMarkers: [String]) -> [PatternFinding] {
        var findings: [PatternFinding] = []
        for rule in secretRules ?? compiledSecretRules() {
            if let match = try? rule.regex.firstMatch(in: text) {
                findings.append(PatternFinding(kind: .secret, path: path, line: number, rule: rule.name,
                                               excerpt: mask(text, range: match.range)))
                break
            }
        }
        if let pattern = debugPatterns.first(where: { containsToken($0, in: text) }) {
            findings.append(PatternFinding(kind: .debugOutput, path: path, line: number, rule: pattern, excerpt: excerpt(text)))
        }
        if let marker = todoMarkers.first(where: { containsToken($0, in: text) }) {
            findings.append(PatternFinding(kind: .todo, path: path, line: number, rule: marker, excerpt: excerpt(text)))
        }
        return findings
    }

    /// Substring match that won't fire inside a longer identifier, so `print(` doesn't
    /// match `fingerprint(` and `TODO` doesn't match `TODOS`.
    static func containsToken(_ token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: token, range: searchRange) {
            let before = range.lowerBound > text.startIndex ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            let startsWithWord = token.first.map(isWordCharacter) ?? false
            let endsWithWord = token.last.map(isWordCharacter) ?? false
            let leftOK = !startsWithWord || before.map { !isWordCharacter($0) } ?? true
            let rightOK = !endsWithWord || after.map { !isWordCharacter($0) } ?? true
            if leftOK && rightOK { return true }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Keeps the first and last 4 characters of a secret so it's recognizable but not usable.
    static func mask(_ text: String, range: Range<String.Index>) -> String {
        let secret = text[range]
        let masked = secret.count <= 8
            ? String(repeating: "•", count: secret.count)
            : secret.prefix(4) + String(repeating: "•", count: secret.count - 8) + secret.suffix(4)
        return excerpt(text.replacingCharacters(in: range, with: masked))
    }

    private static func excerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 160 ? String(trimmed.prefix(160)) + "…" : trimmed
    }
}
