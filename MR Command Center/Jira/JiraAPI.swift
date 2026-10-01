import Foundation

/// Jira REST. Implemented by `LiveJiraClient` and `MockJiraClient`.
nonisolated protocol JiraAPI: Sendable {
    func myself() async throws -> JiraUser
    /// Throws `APIError.notFound` when the issue doesn't exist or isn't visible to the token.
    func issue(key: String, fields: [String]) async throws -> JiraIssue
    func fields() async throws -> [JiraField]
}
