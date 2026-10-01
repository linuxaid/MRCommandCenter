import Foundation
import Testing
@testable import MR_Command_Center

struct GitLabDecodingTests {
    @Test func decodesMergeRequestList() throws {
        let items = try HTTPClient.decode([GitLabMergeRequest].self, from: Fixture.data("gitlab_merge_requests"), decoder: .gitLab)
        #expect(items.count == 2)

        let first = items[0]
        #expect(first.iid == 412)
        #expect(first.projectId == 101)
        #expect(first.author.username == "priya")
        #expect(first.labels?.map(\.name) == ["backend", "priority::high"])
        #expect(first.labels?.first?.color == "#6699cc")
        #expect(first.labels?.first?.textColor == "#FFFFFF")
        #expect(first.references?.full == "payments/api!412")
        #expect(first.isDraft == false)
        #expect(first.headPipeline == nil)
        #expect(first.key == "101!412")

        let second = items[1]
        #expect(second.isDraft, "Falls back to the legacy work_in_progress flag")
        #expect(second.description == nil)
        #expect(second.hasConflicts == true)
        #expect(second.references == nil)
    }

    @Test func decodesMergeRequestDetailWithHeadPipeline() throws {
        let detail = try HTTPClient.decode(GitLabMergeRequest.self, from: Fixture.data("gitlab_merge_request_detail"), decoder: .gitLab)
        #expect(detail.labels == [GitLabLabel(name: "backend"), GitLabLabel(name: "payments")], "Detail returns plain names")
        let pipeline = try #require(detail.headPipeline)
        #expect(pipeline.id == 55120)
        #expect(pipeline.pipelineStatus == .success)
        #expect(detail.diffRefs?.headSha == detail.sha)
    }

    @Test func decodesApprovals() throws {
        let approvals = try HTTPClient.decode(GitLabApprovals.self, from: Fixture.data("gitlab_approvals"), decoder: .gitLab)
        #expect(approvals.given == 1)
        #expect(approvals.required == 2)
        #expect(approvals.left == 1)
        #expect(approvals.approvedBy?.first?.user.name == "Dana Okafor")
    }

    @Test func countsUnresolvedDiscussions() throws {
        let discussions = try HTTPClient.decode([GitLabDiscussion].self, from: Fixture.data("gitlab_discussions"), decoder: .gitLab)
        #expect(discussions.count == 3)
        #expect(discussions.count(where: \.isUnresolved) == 1)
        #expect(discussions.count(where: \.isResolvable) == 2)
    }

    @Test func decodesPipeline() throws {
        let pipeline = try HTTPClient.decode(GitLabPipeline.self, from: Fixture.data("gitlab_pipeline"), decoder: .gitLab)
        #expect(pipeline.pipelineStatus == .running)
        #expect(pipeline.pipelineStatus.isActive)
    }

    @Test(arguments: [
        ("success", PipelineStatus.success), ("waiting_for_resource", .waitingForResource),
        ("canceled", .canceled), ("cancelled", .canceled), ("something_new", .unknown),
    ])
    func mapsPipelineStatuses(raw: String, expected: PipelineStatus) {
        #expect(PipelineStatus(gitLabValue: raw) == expected)
    }

    @Test func projectPathFallsBackToWebURL() throws {
        var item = try HTTPClient.decode([GitLabMergeRequest].self, from: Fixture.data("gitlab_merge_requests"), decoder: .gitLab)[1]
        item.references = nil
        #expect(TrackedMR.projectPath(from: item) == "web/storefront")
    }
}

struct GitLabPaginationTests {
    private func page(_ ids: [Int], next: String?) -> StubTransport.Reply {
        let body = "[" + ids.map { #"{"id":"d\#($0)","notes":[]}"# }.joined(separator: ",") + "]"
        return .response(status: 200, body: Data(body.utf8), headers: next.map { ["X-Next-Page": $0] } ?? ["X-Next-Page": ""])
    }

    @Test func followsNextPageHeaderUntilEmpty() async throws {
        let transport = StubTransport([page([1, 2], next: "2"), page([3, 4], next: "3"), page([5], next: nil)])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)

        let discussions = try await client.discussions(projectID: 1, iid: 2)

        #expect(discussions.map(\.id) == ["d1", "d2", "d3", "d4", "d5"])
        #expect(transport.requests.count == 3)
        let lastQuery = URLComponents(url: transport.requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(lastQuery.contains(URLQueryItem(name: "page", value: "3")))
        #expect(lastQuery.contains(URLQueryItem(name: "per_page", value: "100")))
    }

    @Test func stopsAtMaxPages() async throws {
        let transport = StubTransport((1...3).map { page([$0], next: String($0 + 1)) })
        var client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)
        client.maxPages = 3
        let discussions = try await client.discussions(projectID: 1, iid: 2)
        #expect(discussions.count == 3)
    }

    @Test func reviewerListUsesReviewerIDNotAssignee() async throws {
        let transport = StubTransport([.response(status: 200, body: Data("[]".utf8))])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)
        _ = try await client.openMergeRequests(reviewerID: 1234)

        let url = try #require(transport.requests.first?.url)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(url.path() == "/api/v4/merge_requests")
        #expect(query.contains(URLQueryItem(name: "reviewer_id", value: "1234")))
        #expect(query.contains(URLQueryItem(name: "state", value: "opened")))
        #expect(query.contains(URLQueryItem(name: "scope", value: "all")))
        #expect(!query.contains { $0.name == "assignee_id" })
        #expect(query.contains(URLQueryItem(name: "with_labels_details", value: "true")))
    }
}
