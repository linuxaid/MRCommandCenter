import Foundation
import SwiftData

/// The last fetch of one Jira issue. Issues in a passing status aren't refetched on
/// automatic refreshes; manual refreshes always refetch (tickets can be reopened).
@Model
final class JiraCheck {
    @Attribute(.unique) var issueKey: String
    /// JSON `JiraIssueDetails`; nil when the issue wasn't found or the fetch failed.
    var detailsData: Data?
    var statusName: String?
    var acceptanceCriteria: String?
    var passed: Bool = false
    var notFound: Bool = false
    var lastError: String?
    var lastCheckedAt: Date

    init(issueKey: String, checkedAt: Date = .now) {
        self.issueKey = issueKey
        lastCheckedAt = checkedAt
    }

    var details: JiraIssueDetails? {
        detailsData.flatMap { try? JSONDecoder().decode(JiraIssueDetails.self, from: $0) }
    }

    func apply(_ details: JiraIssueDetails, passingStatuses: [String], at date: Date = .now) {
        detailsData = try? JSONEncoder().encode(details)
        statusName = details.status
        acceptanceCriteria = details.acceptanceCriteria
        passed = JiraStatusRules.isPassing(details.status, passingStatuses: passingStatuses)
        notFound = false
        lastError = nil
        lastCheckedAt = date
    }
}

nonisolated enum JiraStatusRules {
    static func isPassing(_ status: String, passingStatuses: [String]) -> Bool {
        passingStatuses.contains { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(status) == .orderedSame }
    }
}

/// What the app knows about an MR's Jira issue, cached on `TrackedMR` for the sidebar and checks.
nonisolated enum JiraLookup: String, Codable, Sendable {
    case found, notFound, failed, notConfigured
}
