import os
import Foundation

nonisolated struct LiveGitLabClient: GitLabAPI {
    let http: HTTPClient
    var perPage = 100
    /// Safety valve against runaway pagination.
    var maxPages = 50

    init(baseURL: URL, token: String, transport: any HTTPTransport) {
        http = HTTPClient(
            baseURL: baseURL,
            transport: transport,
            defaultHeaders: ["PRIVATE-TOKEN": token, "Accept": "application/json"]
        )
    }

    func currentUser() async throws -> GitLabUser {
        try await http.get(GitLabUser.self, path: "/api/v4/user", decoder: .gitLab)
    }

    func tokenInfo() async throws -> GitLabTokenInfo? {
        do {
            return try await http.get(GitLabTokenInfo.self, path: "/api/v4/personal_access_tokens/self", decoder: .gitLab)
        } catch APIError.notFound, APIError.forbidden {
            return nil
        }
    }

    func openMergeRequests(reviewerID: Int) async throws -> [GitLabMergeRequest] {
        try await allPages(GitLabMergeRequest.self, path: "/api/v4/merge_requests", query: [
            URLQueryItem(name: "state", value: "opened"),
            URLQueryItem(name: "scope", value: "all"),
            URLQueryItem(name: "reviewer_id", value: String(reviewerID)),
            URLQueryItem(name: "order_by", value: "updated_at"),
            URLQueryItem(name: "with_labels_details", value: "true"),
        ])
    }

    func openMergeRequests(authorID: Int) async throws -> [GitLabMergeRequest] {
        try await allPages(GitLabMergeRequest.self, path: "/api/v4/merge_requests", query: [
            URLQueryItem(name: "state", value: "opened"),
            URLQueryItem(name: "scope", value: "all"),
            URLQueryItem(name: "author_id", value: String(authorID)),
            URLQueryItem(name: "order_by", value: "updated_at"),
            URLQueryItem(name: "with_labels_details", value: "true"),
        ])
    }

    func mergeRequest(projectID: Int, iid: Int) async throws -> GitLabMergeRequest {
        try await http.get(GitLabMergeRequest.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)", decoder: .gitLab)
    }

    func approvals(projectID: Int, iid: Int) async throws -> GitLabApprovals {
        try await http.get(GitLabApprovals.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/approvals", decoder: .gitLab)
    }

    func discussions(projectID: Int, iid: Int) async throws -> [GitLabDiscussion] {
        try await allPages(GitLabDiscussion.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/discussions")
    }

    func pipeline(projectID: Int, pipelineID: Int) async throws -> GitLabPipeline {
        try await http.get(GitLabPipeline.self, path: "/api/v4/projects/\(projectID)/pipelines/\(pipelineID)", decoder: .gitLab)
    }

    func diffs(projectID: Int, iid: Int) async throws -> [GitLabDiff] {
        try await allPages(GitLabDiff.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/diffs", perPage: 30)
    }

    func fileContent(projectID: Int, path: String, ref: String) async throws -> String {
        String(decoding: try await rawFile(projectID: projectID, path: path, ref: ref), as: UTF8.self)
    }

    func rawFile(projectID: Int, path: String, ref: String) async throws -> Data {
        let encoded = path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? path
        let request = try http.makeRequest(path: "/api/v4/projects/\(projectID)/repository/files/\(encoded)/raw",
                                           query: [URLQueryItem(name: "ref", value: ref)])
        return try await http.send(request).data
    }

    func createDiffDiscussion(projectID: Int, iid: Int, request: NewDiffDiscussionRequest) async throws -> GitLabDiscussion {
        try await http.post(GitLabDiscussion.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/discussions",
                            body: request, decoder: .gitLab)
    }

    func createDiscussion(projectID: Int, iid: Int, body: String) async throws -> GitLabDiscussion {
        try await http.post(GitLabDiscussion.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/discussions",
                            body: NewNoteRequest(body: body), decoder: .gitLab)
    }

    func replyToDiscussion(projectID: Int, iid: Int, discussionID: String, body: String) async throws -> GitLabDiscussion.Note {
        let id = discussionID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? discussionID
        return try await http.post(GitLabDiscussion.Note.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/discussions/\(id)/notes",
                                   body: NewNoteRequest(body: body), decoder: .gitLab)
    }

    func approve(projectID: Int, iid: Int, sha: String) async throws -> GitLabApprovals {
        try await http.post(GitLabApprovals.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/approve",
                            body: ApproveRequest(sha: sha), decoder: .gitLab)
    }

    func unapprove(projectID: Int, iid: Int) async throws {
        let request = try http.makeRequest(path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/unapprove", method: "POST")
        _ = try await http.send(request)
    }

    func merge(projectID: Int, iid: Int, options: MergeOptions) async throws -> GitLabMergeRequest {
        try await http.put(GitLabMergeRequest.self, path: "/api/v4/projects/\(projectID)/merge_requests/\(iid)/merge",
                           body: options, decoder: .gitLab)
    }

    /// Follows GitLab's offset pagination via the `X-Next-Page` header.
    @concurrent
    func allPages<T: Decodable & Sendable>(_ type: T.Type, path: String, query: [URLQueryItem] = [], perPage: Int? = nil) async throws -> [T] {
        let perPage = perPage ?? self.perPage
        var results: [T] = []
        var page = "1"
        for _ in 0..<maxPages {
            let request = try http.makeRequest(path: path, query: query + [
                URLQueryItem(name: "per_page", value: String(perPage)),
                URLQueryItem(name: "page", value: page),
            ])
            let response = try await http.send(request)
            results += try HTTPClient.decode([T].self, from: response.data, decoder: .gitLab)
            guard let next = response.header("X-Next-Page")?.trimmingCharacters(in: .whitespaces), !next.isEmpty else {
                return results
            }
            page = next
        }
        Log.network.notice("Stopped paginating after \(maxPages, privacy: .public) pages")
        return results
    }
}
