import Foundation

/// Builds API clients from connection details. Swapped for mocks in previews and tests.
nonisolated protocol ClientFactory: Sendable {
    func gitLab(baseURL: URL, token: String) -> any GitLabAPI
    func jira(baseURL: URL, auth: JiraAuth) -> any JiraAPI
}

nonisolated struct LiveClientFactory: ClientFactory {
    let transport: any HTTPTransport

    func gitLab(baseURL: URL, token: String) -> any GitLabAPI {
        LiveGitLabClient(baseURL: baseURL, token: token, transport: transport)
    }

    func jira(baseURL: URL, auth: JiraAuth) -> any JiraAPI {
        LiveJiraClient(baseURL: baseURL, auth: auth, transport: transport)
    }
}

nonisolated struct MockClientFactory: ClientFactory {
    var gitLabClient = MockGitLabClient()
    var jiraClient = MockJiraClient()

    func gitLab(baseURL: URL, token: String) -> any GitLabAPI { gitLabClient }
    func jira(baseURL: URL, auth: JiraAuth) -> any JiraAPI { jiraClient }
}
