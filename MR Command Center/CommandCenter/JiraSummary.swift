import Foundation

/// What the brief shows about an MR's Jira issue (#25): the issue's key fields and its story,
/// or why there's nothing to show. Pure, so it's tested without a view.
struct JiraSummary: Equatable {
    enum State: Equatable {
        case found
        /// The branch name has no issue key.
        case noKey(branch: String)
        /// Jira isn't connected in Settings.
        case notConnected
        case loading
        case notFound
        case failed(String)
    }

    struct Row: Equatable, Identifiable {
        enum Tone: Equatable {
            case normal, positive, warning
        }

        let label: String
        let value: String
        var tone: Tone = .normal

        var id: String { label }
    }

    let state: State
    let key: String?
    let title: String?
    let rows: [Row]
    let description: String?
    let acceptanceCriteria: String?
    /// The latest refresh failed, so the details shown are from an earlier one.
    var staleError: String?

    /// Something to expand under the details.
    var hasExpandableText: Bool { description != nil || acceptanceCriteria != nil }

    static func make(for mr: TrackedMR, details: JiraIssueDetails?) -> JiraSummary {
        guard let key = mr.jiraKey else {
            return JiraSummary(state: .noKey(branch: mr.sourceBranch), key: nil, title: nil, rows: [],
                               description: nil, acceptanceCriteria: nil)
        }
        func empty(_ state: State) -> JiraSummary {
            JiraSummary(state: state, key: key, title: nil, rows: [], description: nil, acceptanceCriteria: nil)
        }
        switch mr.jiraLookup {
        case .notConfigured?: return empty(.notConnected)
        case .notFound?: return empty(.notFound)
        case nil: return empty(.loading)
        case .found?, .failed?:
            guard let details else { return empty(.failed(mr.jiraError ?? "Couldn't load the issue.")) }
            var summary = found(details, passing: mr.jiraPassing == true)
            summary.staleError = mr.jiraError
            return summary
        }
    }

    static func found(_ details: JiraIssueDetails, passing: Bool) -> JiraSummary {
        let rows = [
            Row(label: "Status", value: details.status, tone: passing ? .positive : .normal),
            Row(label: "Type", value: nonEmpty(details.issueType) ?? "Not set"),
            details.hasPriority
                ? Row(label: "Priority", value: details.priority ?? "")
                : Row(label: "Priority", value: "Not set", tone: .warning),
            Row(label: details.fixVersions.count > 1 ? "Fix versions" : "Fix version",
                value: details.fixVersions.isEmpty ? "None" : details.fixVersions.joined(separator: ", ")),
            Row(label: "Assignee", value: nonEmpty(details.assignee) ?? "Unassigned"),
        ]
        return JiraSummary(state: .found, key: details.key, title: nonEmpty(details.summary), rows: rows,
                           description: nonEmpty(details.description), acceptanceCriteria: nonEmpty(details.acceptanceCriteria))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
