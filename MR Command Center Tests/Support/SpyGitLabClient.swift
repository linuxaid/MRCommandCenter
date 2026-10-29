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
        var mergeFailure: APIError?
        var rawFileFailure: APIError?
        var labelFailure: APIError?
        var resolveFailure: APIError?
        var discussionsFailure: APIError?
        /// Holds a label update's reply for a while (by label name), to deliver replies out of order.
        var labelReplyDelays: [String: Duration] = [:]
        var rawFileOverride: Data?
        /// Fails merges of just these MRs (by iid), on top of `mergeFailure`.
        var mergeFailuresByIID: [Int: APIError] = [:]
        var merges: [MergeOptions] = []
        /// Fails retrying and starting pipelines.
        var pipelineFailure: APIError?
        /// Fails only merge request pipelines, like a project whose CI has no MR pipelines.
        var mergeRequestPipelineFailure: APIError?
        var pipelineRefs: [String] = []
        var jobsFailure: APIError?
        var jobLogFailure: APIError?
        /// Replaces every job log, to test cleaning and trimming.
        var jobLogOverride: String?
        /// Holds job-log replies for a while, so they can arrive after a newer pipeline loads.
        var jobLogDelay: Duration?
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

    func openMergeRequests(authorID: Int) async throws -> [GitLabMergeRequest] {
        record("authoredList")
        if let failure = state.withLock({ $0.listFailure }) { throw failure }
        return try await mock.openMergeRequests(authorID: authorID)
    }

    func setDiscussionResolved(projectID: Int, iid: Int, discussionID: String, resolved: Bool) async throws -> GitLabDiscussion {
        record("resolve")
        if let failure = state.withLock({ $0.resolveFailure }) { throw failure }
        let client = mock
        let discussion = try await client.setDiscussionResolved(projectID: projectID, iid: iid, discussionID: discussionID, resolved: resolved)
        edit { $0.data = client.data }
        return discussion
    }

    func projectLabels(projectID: Int) async throws -> [GitLabLabel] {
        record("projectLabels")
        if let failure = state.withLock({ $0.labelFailure }) { throw failure }
        return try await mock.projectLabels(projectID: projectID)
    }

    func updateLabels(projectID: Int, iid: Int, add: [String], remove: [String]) async throws -> GitLabMergeRequest {
        record("updateLabels")
        if let failure = state.withLock({ $0.labelFailure }) { throw failure }
        let client = mock
        let updated = try await client.updateLabels(projectID: projectID, iid: iid, add: add, remove: remove)
        edit { $0.data = client.data }
        if let delay = state.withLock({ state in (add + remove).compactMap { state.labelReplyDelays[$0] }.first }) {
            try await Task.sleep(for: delay)
        }
        return updated
    }

    func approve(projectID: Int, iid: Int, sha: String) async throws -> GitLabApprovals {
        record("approve")
        if let failure = state.withLock({ $0.mergeFailure }) { throw failure }
        let client = mock
        let approvals = try await client.approve(projectID: projectID, iid: iid, sha: sha)
        edit { $0.data = client.data }
        return approvals
    }

    func unapprove(projectID: Int, iid: Int) async throws {
        record("unapprove")
        let client = mock
        try await client.unapprove(projectID: projectID, iid: iid)
        edit { $0.data = client.data }
    }

    func merge(projectID: Int, iid: Int, options: MergeOptions) async throws -> GitLabMergeRequest {
        record("merge")
        if let failure = state.withLock({ $0.mergeFailure ?? $0.mergeFailuresByIID[iid] }) { throw failure }
        let client = mock
        let merged = try await client.merge(projectID: projectID, iid: iid, options: options)
        edit { state in
            state.merges.append(options)
            state.data = client.data
        }
        return merged
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
        if let failure = state.withLock({ $0.discussionsFailure }) { throw failure }
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

    func rawFile(projectID: Int, path: String, ref: String) async throws -> Data {
        record("rawFile")
        let (failure, override) = state.withLock { ($0.rawFileFailure, $0.rawFileOverride) }
        if let failure { throw failure }
        if let override { return override }
        return try await mock.rawFile(projectID: projectID, path: path, ref: ref)
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

    func failedJobs(projectID: Int, pipelineID: Int) async throws -> [GitLabJob] {
        record("failedJobs")
        if let failure = state.withLock({ $0.jobsFailure }) { throw failure }
        return try await mock.failedJobs(projectID: projectID, pipelineID: pipelineID)
    }

    func jobLog(projectID: Int, jobID: Int) async throws -> String {
        record("jobLog")
        if let delay = state.withLock({ $0.jobLogDelay }) { try await Task.sleep(for: delay) }
        let (failure, override) = state.withLock { ($0.jobLogFailure, $0.jobLogOverride) }
        if let failure { throw failure }
        if let override { return override }
        return try await mock.jobLog(projectID: projectID, jobID: jobID)
    }

    func retryPipeline(projectID: Int, pipelineID: Int) async throws -> GitLabPipeline {
        record("retryPipeline")
        if let failure = state.withLock({ $0.pipelineFailure }) { throw failure }
        let client = mock
        let pipeline = try await client.retryPipeline(projectID: projectID, pipelineID: pipelineID)
        edit { $0.data = client.data }
        return pipeline
    }

    func createMergeRequestPipeline(projectID: Int, iid: Int) async throws -> GitLabPipeline {
        record("createMergeRequestPipeline")
        if let failure = state.withLock({ $0.pipelineFailure ?? $0.mergeRequestPipelineFailure }) { throw failure }
        let client = mock
        let pipeline = try await client.createMergeRequestPipeline(projectID: projectID, iid: iid)
        edit { $0.data = client.data }
        return pipeline
    }

    func createPipeline(projectID: Int, ref: String) async throws -> GitLabPipeline {
        record("createPipeline")
        if let failure = state.withLock({ $0.pipelineFailure }) { throw failure }
        let client = mock
        let pipeline = try await client.createPipeline(projectID: projectID, ref: ref)
        edit { state in
            state.pipelineRefs.append(ref)
            state.data = client.data
        }
        return pipeline
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
