import Foundation

/// GitLab REST v4. Implemented by `LiveGitLabClient` and `MockGitLabClient`.
nonisolated protocol GitLabAPI: Sendable {
    func currentUser() async throws -> GitLabUser
    /// Returns nil when the server doesn't support the endpoint or the token type.
    func tokenInfo() async throws -> GitLabTokenInfo?
    /// Open MRs where the given user is a reviewer, across all projects. All pages.
    func openMergeRequests(reviewerID: Int) async throws -> [GitLabMergeRequest]
    /// Open MRs the given user opened, across all projects. All pages.
    func openMergeRequests(authorID: Int) async throws -> [GitLabMergeRequest]
    func mergeRequest(projectID: Int, iid: Int) async throws -> GitLabMergeRequest
    func approvals(projectID: Int, iid: Int) async throws -> GitLabApprovals
    /// All pages.
    func discussions(projectID: Int, iid: Int) async throws -> [GitLabDiscussion]
    func pipeline(projectID: Int, pipelineID: Int) async throws -> GitLabPipeline
    /// The pipeline's failed jobs (the latest try of each). All pages.
    func failedJobs(projectID: Int, pipelineID: Int) async throws -> [GitLabJob]
    /// A job's log, as raw terminal output.
    func jobLog(projectID: Int, jobID: Int) async throws -> String
    /// Reruns a pipeline's failed and canceled jobs. Requires the `api` scope.
    func retryPipeline(projectID: Int, pipelineID: Int) async throws -> GitLabPipeline
    /// Starts a merge request pipeline for the MR's latest commit. Requires the `api` scope.
    func createMergeRequestPipeline(projectID: Int, iid: Int) async throws -> GitLabPipeline
    /// Starts a branch pipeline. Requires the `api` scope.
    func createPipeline(projectID: Int, ref: String) async throws -> GitLabPipeline
    /// Per-file diffs for the MR's latest version. All pages.
    func diffs(projectID: Int, iid: Int) async throws -> [GitLabDiff]
    /// A file's raw content at a commit (used by the AI review's file-reading tool).
    func fileContent(projectID: Int, path: String, ref: String) async throws -> String
    /// A file's raw bytes at a commit (image previews for binary files).
    func rawFile(projectID: Int, path: String, ref: String) async throws -> Data
    /// Starts a new comment thread on a diff line. Requires the `api` scope.
    func createDiffDiscussion(projectID: Int, iid: Int, request: NewDiffDiscussionRequest) async throws -> GitLabDiscussion
    /// Starts a general (resolvable) thread on the MR, not tied to a line. Requires the `api` scope.
    func createDiscussion(projectID: Int, iid: Int, body: String) async throws -> GitLabDiscussion
    /// Replies to an existing thread. Requires the `api` scope.
    func replyToDiscussion(projectID: Int, iid: Int, discussionID: String, body: String) async throws -> GitLabDiscussion.Note
    /// Resolves or reopens a comment thread. Requires the `api` scope.
    func setDiscussionResolved(projectID: Int, iid: Int, discussionID: String, resolved: Bool) async throws -> GitLabDiscussion
    /// Every label defined for the project (including inherited group labels). All pages.
    func projectLabels(projectID: Int) async throws -> [GitLabLabel]
    /// Adds and removes labels on an MR by name. Requires the `api` scope.
    func updateLabels(projectID: Int, iid: Int, add: [String], remove: [String]) async throws -> GitLabMergeRequest
    /// Approves the MR at exactly `sha`. Requires the `api` scope.
    func approve(projectID: Int, iid: Int, sha: String) async throws -> GitLabApprovals
    /// Removes your approval. Requires the `api` scope.
    func unapprove(projectID: Int, iid: Int) async throws
    /// Merges the MR at exactly `options.sha` (or sets it to merge when the pipeline passes). Requires the `api` scope.
    func merge(projectID: Int, iid: Int, options: MergeOptions) async throws -> GitLabMergeRequest
}

nonisolated enum GitLabScopes {
    static let required = "read_api"
    static let commentPosting = "api"

    static func hasReadAccess(_ scopes: [String]) -> Bool {
        scopes.contains(required) || scopes.contains(commentPosting)
    }
}
