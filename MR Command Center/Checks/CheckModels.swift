import Foundation

nonisolated enum CheckID: String, Codable, Sendable, CaseIterable {
    case pipeline, jira, priority, approvals, conflicts, draft, discussions
    case diffSize, tests, secrets, debugOutput, todos
}

/// Ordered by severity so the worst outcome can be found with `max()`.
nonisolated enum CheckOutcome: Int, Codable, Sendable, Comparable {
    case notApplicable, pass, pending, warning, fail

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A flagged added line.
nonisolated struct PatternFinding: Codable, Sendable, Equatable, Hashable {
    enum Kind: String, Codable, Sendable {
        case secret, debugOutput, todo
    }

    let kind: Kind
    let path: String
    /// New-side line number of the added line.
    let line: Int
    /// What matched, e.g. "AWS access key ID" or "console.log".
    let rule: String
    /// The line, with any secret value masked.
    let excerpt: String
}

nonisolated struct CheckResult: Codable, Sendable, Equatable, Identifiable {
    let id: CheckID
    let outcome: CheckOutcome
    let title: String
    let detail: String
    var findings: [PatternFinding] = []
}

/// All checks for an MR at its head SHA.
nonisolated struct CheckReport: Sendable, Equatable {
    let results: [CheckResult]
    /// False while the diff-based checks haven't run yet for this SHA.
    let diffChecksAvailable: Bool

    var failures: Int { results.count { $0.outcome == .fail } }
    var warnings: Int { results.count { $0.outcome == .warning } }
    var pending: Int { results.count { $0.outcome == .pending } }
    var worst: CheckOutcome { results.map(\.outcome).max() ?? .pass }

    func result(_ id: CheckID) -> CheckResult? { results.first { $0.id == id } }

    /// Findings for one file, e.g. to feed the AI review.
    func findings(forPath path: String) -> [PatternFinding] {
        results.flatMap(\.findings).filter { $0.path == path }
    }
}

/// User-configurable inputs to the diff checks. The fingerprint invalidates cached
/// results when any of these change.
nonisolated struct CheckConfiguration: Sendable, Equatable {
    var diffSizeLimit: Int
    var debugPatterns: [String]
    var todoMarkers: [String]
    var extraTestPathPatterns: [String]

    static let `default` = CheckConfiguration(
        diffSizeLimit: 1000,
        debugPatterns: AccountSettings.defaultDebugPatterns,
        todoMarkers: AccountSettings.defaultTodoMarkers,
        extraTestPathPatterns: []
    )

    /// Bump when check logic changes so cached results are recomputed.
    static let rulesVersion = 1

    var fingerprint: String {
        let parts = ["v\(Self.rulesVersion)", String(diffSizeLimit)] + debugPatterns + ["|"] + todoMarkers + ["|"] + extraTestPathPatterns
        return parts.joined(separator: "\u{1F}")
    }
}
