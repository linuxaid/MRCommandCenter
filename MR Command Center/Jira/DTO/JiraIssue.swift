import Foundation

/// `GET /issue/{key}` with fields decoded generically (custom fields vary by instance).
nonisolated struct JiraIssue: Decodable, Sendable, Equatable {
    let key: String
    let fields: [String: JSONValue]
}

/// `GET /field`, used by the setup preview to suggest field IDs.
nonisolated struct JiraField: Decodable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    var custom: Bool?
}

/// What the app uses from an issue, extracted once from the raw fields.
nonisolated struct JiraIssueDetails: Codable, Sendable, Equatable {
    var key: String
    var summary: String
    var status: String
    /// Jira's status category key: `new`, `indeterminate`, or `done`.
    var statusCategory: String?
    var issueType: String?
    var assignee: String?
    var priority: String?
    var fixVersions: [String]
    var description: String?
    var acceptanceCriteria: String?
    var acceptanceCriteriaSource: AcceptanceCriteriaExtractor.Source?

    static let placeholderPriorities: Set<String> = ["none", "unprioritized", "unprioritised", "undefined", "unset", "not set", "-", "n/a"]

    /// Priority is set and isn't a placeholder value.
    var hasPriority: Bool {
        guard let priority = priority?.trimmingCharacters(in: .whitespaces), !priority.isEmpty else { return false }
        return !Self.placeholderPriorities.contains(priority.lowercased())
    }

    /// The story as the AI review sees it: summary, description, and criteria.
    var hasStory: Bool { !(description ?? "").isEmpty || acceptanceCriteria != nil }

    init(issue: JiraIssue, acceptanceCriteriaFieldID: String, priorityFieldID: String) {
        let fields = issue.fields
        key = issue.key
        summary = fields["summary"]?.plainText ?? ""
        status = fields["status"]?["name"]?.string ?? "Unknown"
        statusCategory = fields["status"]?["statusCategory"]?["key"]?.string
        issueType = fields["issuetype"]?["name"]?.string
        assignee = fields["assignee"]?.plainText
        let priorityKey = priorityFieldID.trimmingCharacters(in: .whitespaces).isEmpty ? "priority" : priorityFieldID
        priority = fields[priorityKey]?.plainText
        fixVersions = fields["fixVersions"]?.array?.compactMap { $0["name"]?.string } ?? []
        description = fields["description"]?.plainText

        let fieldID = acceptanceCriteriaFieldID.trimmingCharacters(in: .whitespaces)
        if !fieldID.isEmpty, let text = fields[fieldID]?.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            acceptanceCriteria = text
            acceptanceCriteriaSource = .customField
        } else if let description, let text = AcceptanceCriteriaExtractor.fromDescription(description) {
            acceptanceCriteria = text
            acceptanceCriteriaSource = .description
        }
    }

    static func requestedFields(acceptanceCriteriaFieldID: String, priorityFieldID: String) -> [String] {
        var fields = ["summary", "status", "issuetype", "assignee", "priority", "fixVersions", "description"]
        for custom in [acceptanceCriteriaFieldID, priorityFieldID].map({ $0.trimmingCharacters(in: .whitespaces) }) where !custom.isEmpty {
            if !fields.contains(custom) { fields.append(custom) }
        }
        return fields
    }
}
