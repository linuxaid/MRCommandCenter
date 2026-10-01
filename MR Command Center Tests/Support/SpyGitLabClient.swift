import Foundation
import SwiftData
import Synchronization
@testable import MR_Command_Center

/// Mutable GitLab double that counts calls, for caching-rule tests.
nonisolated final class SpyGitLabClient: GitLabAPI {
    struct State {
        var data = MockGitLabData.sample
        var listFailure: APIError?
        var detailFailure: APIError?
        var calls: [String: Int] = [:]
        var pipelineOverrides: [Int: String] = [:]
        var postFailure: APIError?
        var lastDiscussionRequest: NewDiffDiscussionRequest?
        var lastGeneralBody: String?
    }

    let state = Mutex(State())

    func count(_ name: String) -> Int { state.withLock { $0.calls[name, default: 0] } }

    func edit(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }

    private func record(_ name: String) {
        state.withLock { $0.calls[name, default: 0] += 1 }
    }

    private var mock: MockGitLabClient {
        MockGitLabClient(data: state.withLock { $0.data })
    }

    func currentUser() async throws -> GitLabUser {
        record("currentUser")
        return try await mock.currentUser()
    }

    func tokenInfo() async throws -> GitLabTokenInfo? { nil }

    func openMergeRequests(reviewerID: Int) async throws -> [GitLabMergeRequest] {
        record("list")
        if let failure = state.withLock({ $0.listFailure }) { throw failure }
        return try await mock.openMergeRequests(reviewerID: reviewerID)
    }

    func mergeRequest(projectID: Int, iid: Int) async throws -> GitLabMergeRequest {
        record("detail")
        if let failure = state.withLock({ $0.detailFailure }) { throw failure }
        return try await mock.mergeRequest(projectID: projectID, iid: iid)
    }

    func approvals(projectID: Int, iid: Int) async throws -> GitLabApprovals {
        record("approvals")
        return try await mock.approvals(projectID: projectID, iid: iid)
    }

    func discussions(projectID: Int, iid: Int) async throws -> [GitLabDiscussion] {
        record("discussions")
        return try await mock.discussions(projectID: projectID, iid: iid)
    }

    func diffs(projectID: Int, iid: Int) async throws -> [GitLabDiff] {
        record("diffs")
        return try await mock.diffs(projectID: projectID, iid: iid)
    }

    func fileContent(projectID: Int, path: String, ref: String) async throws -> String {
        record("fileContent")
        return try await mock.fileContent(projectID: projectID, path: path, ref: ref)
    }

    func createDiffDiscussion(projectID: Int, iid: Int, request: NewDiffDiscussionRequest) async throws -> GitLabDiscussion {
        record("createDiscussion")
        if let failure = state.withLock({ $0.postFailure }) { throw failure }
        let client = mock
        let discussion = try await client.createDiffDiscussion(projectID: projectID, iid: iid, request: request)
        edit { state in
            state.lastDiscussionRequest = request
            state.data = client.data
        }
        return discussion
    }

    func createDiscussion(projectID: Int, iid: Int, body: String) async throws -> GitLabDiscussion {
        record("createGeneralDiscussion")
        if let failure = state.withLock({ $0.postFailure }) { throw failure }
        let client = mock
        let discussion = try await client.createDiscussion(projectID: projectID, iid: iid, body: body)
        edit { state in
            state.lastGeneralBody = body
            state.data = client.data
        }
        return discussion
    }

    func replyToDiscussion(projectID: Int, iid: Int, discussionID: String, body: String) async throws -> GitLabDiscussion.Note {
        record("reply")
        if let failure = state.withLock({ $0.postFailure }) { throw failure }
        let client = mock
        let note = try await client.replyToDiscussion(projectID: projectID, iid: iid, discussionID: discussionID, body: body)
        edit { $0.data = client.data }
        return note
    }

    func pipeline(projectID: Int, pipelineID: Int) async throws -> GitLabPipeline {
        record("pipeline")
        var pipeline = try await mock.pipeline(projectID: projectID, pipelineID: pipelineID)
        if let status = state.withLock({ $0.pipelineOverrides[pipelineID] }) {
            pipeline = GitLabPipeline(id: pipeline.id, sha: pipeline.sha, status: status, webUrl: pipeline.webUrl)
        }
        return pipeline
    }
}

nonisolated struct SpyClientFactory: ClientFactory {
    let gitLabClient: SpyGitLabClient
    var jiraClient = SpyJiraClient()

    func gitLab(baseURL: URL, token: String) -> any GitLabAPI { gitLabClient }
    func jira(baseURL: URL, auth: JiraAuth) -> any JiraAPI { jiraClient }
}

/// Counts issue fetches and can fail or rewrite issues.
nonisolated final class SpyJiraClient: JiraAPI {
    struct State {
        var issues = MockJiraData.issues
        var fetches: [String] = []
        var failure: APIError?
    }

    let state = Mutex(State())

    func edit(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    func fetchCount(_ key: String) -> Int { state.withLock { $0.fetches.count { $0 == key } } }

    func myself() async throws -> JiraUser { JiraUser(accountId: "x", displayName: "Tester") }

    func issue(key: String, fields: [String]) async throws -> JiraIssue {
        let (issue, failure) = state.withLock { state -> (JiraIssue?, APIError?) in
            state.fetches.append(key)
            return (state.issues[key], state.failure)
        }
        if let failure { throw failure }
        guard let issue else { throw APIError.notFound }
        return issue
    }

    func fields() async throws -> [JiraField] { MockJiraData.fieldList }
}

extension AppModel {
    static func testing(gitLab spy: SpyGitLabClient = SpyGitLabClient(), token: String? = "token",
                        model: FakeReviewModel = FakeReviewModel(), modelStatus: ModelStatus = .available,
                        jira: SpyJiraClient? = nil) -> AppModel {
        var tokens = token.map { [SecretAccount.gitLabToken: $0] } ?? [:]
        if jira != nil { tokens[SecretAccount.jiraToken] = "jira-token" }
        let secrets = InMemorySecretStore(tokens)
        var dependencies = AppDependencies(secrets: secrets, clients: SpyClientFactory(gitLabClient: spy, jiraClient: jira ?? SpyJiraClient()), isMock: true)
        dependencies.reviewModel = { model }
        dependencies.modelStatus = { modelStatus }
        let app = AppModel.preview(dependencies: dependencies)
        if jira != nil {
            // Configure Jira like mock mode does.
            let settings = AccountSettings.current(in: app.modelContainer.mainContext)
            settings.jiraBaseURL = "https://example.atlassian.net"
            settings.jiraEmail = "reviewer@example.com"
            settings.jiraAcceptanceCriteriaFieldID = MockJiraData.acceptanceCriteriaField
        }
        return app
    }
}
