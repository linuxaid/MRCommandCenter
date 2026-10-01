import Foundation
import Synchronization

/// In-memory GitLab used by previews, `-UseMockData` launches, and tests.
/// Copies share one store, so comments posted in mock mode show up on the next fetch.
nonisolated struct MockGitLabClient: GitLabAPI {
    var user = GitLabUser(id: 42, username: "aj", name: "A.J. Reviewer")
    var scopes = ["read_api", "api"]
    var failure: APIError?
    private let store: MockGitLabStore

    init(data: MockGitLabData = .sample, failure: APIError? = nil) {
        store = MockGitLabStore(data)
        self.failure = failure
    }

    var data: MockGitLabData { store.data }

    func currentUser() async throws -> GitLabUser {
        try check()
        return user
    }

    func tokenInfo() async throws -> GitLabTokenInfo? {
        try check()
        return GitLabTokenInfo(name: "mock", scopes: scopes, active: true)
    }

    func openMergeRequests(reviewerID: Int) async throws -> [GitLabMergeRequest] {
        try check()
        return data.entries.map(\.listItem)
    }

    func mergeRequest(projectID: Int, iid: Int) async throws -> GitLabMergeRequest {
        try entry(projectID, iid).detail
    }

    func approvals(projectID: Int, iid: Int) async throws -> GitLabApprovals {
        try entry(projectID, iid).approvals
    }

    func discussions(projectID: Int, iid: Int) async throws -> [GitLabDiscussion] {
        try entry(projectID, iid).discussions
    }

    func diffs(projectID: Int, iid: Int) async throws -> [GitLabDiff] {
        try entry(projectID, iid).diffs
    }

    /// Rebuilds the new-side file from the mock diff's added and context lines.
    func fileContent(projectID: Int, path: String, ref: String) async throws -> String {
        try check()
        let diffs = data.entries.filter { $0.detail.projectId == projectID }.flatMap(\.diffs)
        guard let diff = diffs.first(where: { $0.newPath == path }) else { throw APIError.notFound }
        var lines: [Int: String] = [:]
        for line in UnifiedDiffParser.parse(diff.diff).flatMap(\.lines) where line.kind != .deletion {
            if let number = line.newNumber { lines[number] = line.text }
        }
        let last = lines.keys.max() ?? 0
        return (1...max(last, 1)).map { lines[$0] ?? "" }.joined(separator: "\n")
    }

    func createDiffDiscussion(projectID: Int, iid: Int, request: NewDiffDiscussionRequest) async throws -> GitLabDiscussion {
        _ = try entry(projectID, iid)
        let note = GitLabDiscussion.Note(
            id: Int.random(in: 100_000...999_999), resolvable: true, resolved: false, system: false,
            body: request.body, author: GitLabUserRef(id: user.id, username: user.username, name: user.name),
            createdAt: .now, type: "DiffNote", position: request.position
        )
        let discussion = GitLabDiscussion(id: UUID().uuidString, individualNote: false, notes: [note])
        store.mutate(projectID: projectID, iid: iid) { $0.discussions.append(discussion) }
        return discussion
    }

    func createDiscussion(projectID: Int, iid: Int, body: String) async throws -> GitLabDiscussion {
        _ = try entry(projectID, iid)
        let note = GitLabDiscussion.Note(
            id: Int.random(in: 100_000...999_999), resolvable: true, resolved: false, system: false, body: body,
            author: GitLabUserRef(id: user.id, username: user.username, name: user.name), createdAt: .now, type: "DiscussionNote"
        )
        let discussion = GitLabDiscussion(id: UUID().uuidString, individualNote: false, notes: [note])
        store.mutate(projectID: projectID, iid: iid) { $0.discussions.append(discussion) }
        return discussion
    }

    func replyToDiscussion(projectID: Int, iid: Int, discussionID: String, body: String) async throws -> GitLabDiscussion.Note {
        let entry = try entry(projectID, iid)
        guard let thread = entry.discussions.first(where: { $0.id == discussionID }) else { throw APIError.notFound }
        let note = GitLabDiscussion.Note(
            id: Int.random(in: 100_000...999_999), resolvable: thread.isResolvable, resolved: thread.isResolved, system: false,
            body: body, author: GitLabUserRef(id: user.id, username: user.username, name: user.name),
            createdAt: .now, type: thread.position == nil ? "DiscussionNote" : "DiffNote", position: thread.position
        )
        store.mutate(projectID: projectID, iid: iid) { entry in
            if let index = entry.discussions.firstIndex(where: { $0.id == discussionID }) {
                entry.discussions[index].notes = (entry.discussions[index].notes ?? []) + [note]
            }
        }
        return note
    }

    func pipeline(projectID: Int, pipelineID: Int) async throws -> GitLabPipeline {
        try check()
        guard let pipeline = data.entries.compactMap(\.detail.headPipeline).first(where: { $0.id == pipelineID }) else {
            throw APIError.notFound
        }
        return pipeline
    }

    private func check() throws {
        if let failure { throw failure }
    }

    func entry(_ projectID: Int, _ iid: Int) throws -> MockGitLabData.Entry {
        try check()
        guard let entry = data.entries.first(where: { $0.detail.projectId == projectID && $0.detail.iid == iid }) else {
            throw APIError.notFound
        }
        return entry
    }
}

nonisolated final class MockGitLabStore: Sendable {
    private let state: Mutex<MockGitLabData>

    init(_ data: MockGitLabData) {
        state = Mutex(data)
    }

    var data: MockGitLabData { state.withLock { $0 } }

    func mutate(projectID: Int, iid: Int, _ change: (inout MockGitLabData.Entry) -> Void) {
        state.withLock { data in
            if let index = data.entries.firstIndex(where: { $0.detail.projectId == projectID && $0.detail.iid == iid }) {
                change(&data.entries[index])
            }
        }
    }
}

/// Sample merge requests covering every status-line state.
nonisolated struct MockGitLabData: Sendable {
    nonisolated struct Entry: Sendable {
        var detail: GitLabMergeRequest
        var approvals: GitLabApprovals
        var discussions: [GitLabDiscussion]
        var diffs: [GitLabDiff] = []

        var listItem: GitLabMergeRequest {
            var item = detail
            item.headPipeline = nil
            item.diffRefs = nil
            item.changesCount = nil
            return item
        }
    }

    var entries: [Entry]

    static let sample = MockGitLabData(entries: [
        make(project: (101, "payments/api"), iid: 412, title: "Retry failed webhook deliveries with exponential backoff",
             branch: "feature/PAY-142-webhook-retries", author: ("Priya Natarajan", "priya"), hoursAgo: 1,
             pipeline: "success", approvals: (1, 2), unresolved: 2, labels: ["backend", "payments"]),
        make(project: (202, "web/storefront"), iid: 1873, title: "Add saved carts to checkout",
             branch: "feature/SHOP-88-saved-carts", author: ("Marco Bianchi", "marco"), hoursAgo: 3,
             pipeline: "failed", approvals: (0, 1), unresolved: 0, labels: ["frontend"]),
        make(project: (303, "platform/infra"), iid: 77, title: "Bump Terraform AWS provider to 5.x",
             branch: "chore/bump-aws-provider", author: ("Dana Okafor", "dana"), hoursAgo: 5,
             pipeline: "running", approvals: (2, 2), unresolved: 0, labels: ["infra", "dependencies"]),
        make(project: (101, "payments/api"), iid: 415, title: "Draft: Refactor ledger reconciliation job",
             branch: "feature/PAY-150-ledger-refactor", author: ("Priya Natarajan", "priya"), hoursAgo: 8,
             pipeline: "pending", approvals: (0, 2), unresolved: 1, labels: ["backend"], draft: true),
        make(project: (202, "web/storefront"), iid: 1880, title: "Fix currency rounding in order totals",
             branch: "bugfix/SHOP-91-rounding", author: ("Lena Fischer", "lena"), hoursAgo: 20,
             pipeline: "success", approvals: (1, 1), unresolved: 0, labels: ["bug", "frontend"], conflicts: true),
        make(project: (303, "platform/infra"), iid: 80, title: "Rotate staging database credentials via Vault",
             branch: "INFRA-12-vault-rotation", author: ("Dana Okafor", "dana"), hoursAgo: 26,
             pipeline: "canceled", approvals: (2, 2), unresolved: 0, labels: ["security"]),
        make(project: (202, "web/storefront"), iid: 1884, title: "Lazy-load product images below the fold",
             branch: "perf/SHOP-95-lazy-images", author: ("Marco Bianchi", "marco"), hoursAgo: 49,
             pipeline: nil, approvals: (0, 1), unresolved: 0, labels: ["performance"]),
        make(project: (101, "payments/api"), iid: 420, title: "Add idempotency keys to the refund endpoint",
             branch: "feature/PAY-160-refund-idempotency", author: ("Sam Lee", "samlee"), hoursAgo: 72,
             pipeline: "manual", approvals: (1, 2), unresolved: 5, labels: ["backend", "payments"]),
    ])

    private static let labelColors = [
        "backend": "#6699CC", "payments": "#009966", "frontend": "#8E44AD", "infra": "#36454F",
        "dependencies": "#7F8C8D", "bug": "#DC143C", "security": "#E67E22", "performance": "#1F78D1",
    ]

    private static let reference = Date(timeIntervalSince1970: 1_790_000_000)

    private static func make(
        project: (id: Int, path: String),
        iid: Int,
        title: String,
        branch: String,
        author: (name: String, username: String),
        hoursAgo: Double,
        pipeline: String?,
        approvals: (given: Int, required: Int),
        unresolved: Int,
        labels: [String],
        draft: Bool = false,
        conflicts: Bool = false
    ) -> Entry {
        let sha = String(repeating: String(format: "%02x", iid % 256), count: 20)
        let updated = reference.addingTimeInterval(-hoursAgo * 3600)
        let detail = GitLabMergeRequest(
            id: project.id * 10_000 + iid,
            iid: iid,
            projectId: project.id,
            title: title,
            description: "Implements \(title.lowercased()).\n\n## Testing\n- Unit tests added\n- Verified on staging",
            state: "opened",
            createdAt: updated.addingTimeInterval(-86_400 * 2),
            updatedAt: updated,
            sourceBranch: branch,
            targetBranch: "main",
            author: GitLabUserRef(id: author.username.unicodeScalars.reduce(100) { $0 + Int($1.value) }, username: author.username, name: author.name),
            draft: draft,
            labels: labels.map { GitLabLabel(name: $0, color: labelColors[$0], textColor: "#FFFFFF") },
            sha: sha,
            hasConflicts: conflicts,
            detailedMergeStatus: conflicts ? "conflict" : "mergeable",
            references: .init(full: "\(project.path)!\(iid)"),
            webUrl: "https://gitlab.example.com/\(project.path)/-/merge_requests/\(iid)",
            userNotesCount: unresolved * 2,
            headPipeline: pipeline.map {
                GitLabPipeline(id: iid * 100, sha: sha, status: $0,
                               webUrl: "https://gitlab.example.com/\(project.path)/-/pipelines/\(iid * 100)")
            },
            diffRefs: .init(baseSha: String(repeating: "0", count: 40), headSha: sha, startSha: String(repeating: "0", count: 40)),
            changesCount: MockDiffs.changesCount(forIID: iid)
        )
        let approvers = (0..<approvals.given).map {
            GitLabApprovals.Approver(user: GitLabUserRef(id: 900 + $0, username: "approver\($0)", name: "Approver \($0)"))
        }
        let discussions = (0..<unresolved).map {
            GitLabDiscussion(id: "d\(iid)-\($0)", individualNote: false,
                             notes: [.init(id: $0, resolvable: true, resolved: false, system: false)])
        } + [GitLabDiscussion(id: "d\(iid)-resolved", individualNote: false,
                              notes: [.init(id: 999, resolvable: true, resolved: true, system: false)])]
        return Entry(
            detail: detail,
            approvals: GitLabApprovals(
                approved: approvals.given >= approvals.required,
                approvalsRequired: approvals.required,
                approvalsLeft: max(0, approvals.required - approvals.given),
                approvedBy: approvers
            ),
            discussions: MockDiscussions.threads(forIID: iid, headSHA: sha) ?? discussions,
            diffs: MockDiffs.diffs(forIID: iid)
        )
    }
}
