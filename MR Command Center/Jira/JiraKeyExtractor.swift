import Foundation

/// Finds a Jira issue key in a branch name with a configurable pattern.
nonisolated enum JiraKeyExtractor {
    static let defaultPattern = #"[A-Z][A-Z0-9]+-\d+"#

    /// Returns the first match, or nil when there's none or the pattern is invalid.
    static func extractKey(from branch: String, pattern: String = defaultPattern) -> String? {
        guard !pattern.isEmpty, let regex = try? Regex(pattern) else { return nil }
        guard let match = try? regex.firstMatch(in: branch) else { return nil }
        let key = String(branch[match.range])
        return key.isEmpty ? nil : key
    }
}
