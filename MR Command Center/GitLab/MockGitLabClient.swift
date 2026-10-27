import Foundation
import Synchronization

/// In-memory GitLab used by previews, `-UseMockData` launches, and tests.
/// Copies share one store, so comments posted in mock mode show up on the next fetch.
nonisolated struct MockGitLabClient: GitLabAPI {
    var user = MockGitLabData.me
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
        return data.entries.filter { $0.detail.author.id != reviewerID }.map(\.listItem)
    }

    func openMergeRequests(authorID: Int) async throws -> [GitLabMergeRequest] {
        try check()
        return data.entries.filter { $0.detail.author.id == authorID }.map(\.listItem)
    }

    func setDiscussionResolved(projectID: Int, iid: Int, discussionID: String, resolved: Bool) async throws -> GitLabDiscussion {
        let entry = try entry(projectID, iid)
        guard entry.discussions.contains(where: { $0.id == discussionID }) else { throw APIError.notFound }
        let resolver = GitLabUserRef(id: user.id, username: user.username, name: user.name)
        store.mutate(projectID: projectID, iid: iid) { entry in
            guard let index = entry.discussions.firstIndex(where: { $0.id == discussionID }) else { return }
            entry.discussions[index].notes = entry.discussions[index].notes?.map { note in
                guard note.resolvable == true else { return note }
                var note = note
                note.resolved = resolved
                note.resolvedBy = resolved ? resolver : nil
                return note
            }
            entry.bumpUpdatedAt()
        }
        guard let updated = try self.entry(projectID, iid).discussions.first(where: { $0.id == discussionID }) else {
            throw APIError.notFound
        }
        return updated
    }

    /// Every label the mock data uses, plus a few that no MR has yet.
    func projectLabels(projectID: Int) async throws -> [GitLabLabel] {
        try check()
        return MockGitLabData.projectLabels
    }

    func updateLabels(projectID: Int, iid: Int, add: [String], remove: [String]) async throws -> GitLabMergeRequest {
        _ = try entry(projectID, iid)
        let known = Dictionary(MockGitLabData.projectLabels.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        store.mutate(projectID: projectID, iid: iid) { entry in
            var labels = (entry.detail.labels ?? []).filter { !remove.contains($0.name) }
            for name in add where !labels.contains(where: { $0.name == name }) {
                labels.append(known[name] ?? GitLabLabel(name: name))
            }
            entry.detail.labels = labels
            entry.bumpUpdatedAt()
        }
        return try entry(projectID, iid).detail
    }

    func approve(projectID: Int, iid: Int, sha: String) async throws -> GitLabApprovals {
        let entry = try entry(projectID, iid)
        guard entry.detail.sha == sha else { throw APIError.server(status: 409) }
        guard !entry.approvals.approverUsernames.contains(user.username) else { throw APIError.server(status: 401) }
        store.mutate(projectID: projectID, iid: iid) { entry in
            var approvals = entry.approvals
            let me = GitLabUserRef(id: user.id, username: user.username, name: user.name)
            approvals.approvedBy = (approvals.approvedBy ?? []) + [GitLabApprovals.Approver(user: me)]
            approvals.approvalsLeft = max(0, approvals.required - approvals.given)
            approvals.approved = approvals.left == 0
            entry.approvals = approvals
            entry.bumpUpdatedAt()
        }
        return try self.entry(projectID, iid).approvals
    }

    func unapprove(projectID: Int, iid: Int) async throws {
        _ = try entry(projectID, iid)
        store.mutate(projectID: projectID, iid: iid) { entry in
            entry.approvals.approvedBy?.removeAll { $0.user.username == user.username }
            entry.approvals.approvalsLeft = max(0, entry.approvals.required - entry.approvals.given)
            entry.approvals.approved = entry.approvals.left == 0
            entry.bumpUpdatedAt()
        }
    }

    /// Merging removes the MR from the open lists, like GitLab does. With "merge when the
    /// pipeline succeeds" and a pipeline still going, it only sets that flag.
    func merge(projectID: Int, iid: Int, options: MergeOptions) async throws -> GitLabMergeRequest {
        let entry = try entry(projectID, iid)
        guard entry.detail.sha == options.sha else { throw APIError.server(status: 409) }
        if options.mergeWhenPipelineSucceeds == true, entry.detail.headPipeline?.pipelineStatus.isActive == true {
            store.mutate(projectID: projectID, iid: iid) { entry in
                entry.detail.mergeWhenPipelineSucceeds = true
                entry.bumpUpdatedAt()
            }
            return try self.entry(projectID, iid).detail
        }
        store.remove(projectID: projectID, iid: iid)
        return entry.detail
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

    /// Images in the mock diffs come back as a generated PNG (`MockImages`); anything else as its text.
    func rawFile(projectID: Int, path: String, ref: String) async throws -> Data {
        try check()
        let diffs = data.entries.filter { $0.detail.projectId == projectID }.flatMap(\.diffs)
        guard diffs.contains(where: { $0.newPath == path || $0.oldPath == path }) else { throw APIError.notFound }
        if ImagePreview.isImage(path) {
            return MockImages.png(width: MockImages.size.width, height: MockImages.size.height)
        }
        return Data(try await fileContent(projectID: projectID, path: path, ref: ref).utf8)
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

    func remove(projectID: Int, iid: Int) {
        state.withLock { data in
            data.entries.removeAll { $0.detail.projectId == projectID && $0.detail.iid == iid }
        }
    }

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

        /// Writes change `updated_at`, which is what makes the app refetch details.
        mutating func bumpUpdatedAt() {
            let d = detail
            detail = GitLabMergeRequest(
                id: d.id, iid: d.iid, projectId: d.projectId, title: d.title, description: d.description, state: d.state,
                createdAt: d.createdAt, updatedAt: d.updatedAt.addingTimeInterval(60), sourceBranch: d.sourceBranch,
                targetBranch: d.targetBranch, author: d.author, draft: d.draft, workInProgress: d.workInProgress,
                labels: d.labels, sha: d.sha, hasConflicts: d.hasConflicts,
                detailedMergeStatus: Self.status(d.detailedMergeStatus, approvalsLeft: approvals.left),
                references: d.references, webUrl: d.webUrl, userNotesCount: d.userNotesCount,
                mergeWhenPipelineSucceeds: d.mergeWhenPipelineSucceeds, reviewers: d.reviewers,
                headPipeline: d.headPipeline, diffRefs: d.diffRefs, changesCount: d.changesCount
            )
        }

        private static func status(_ status: String?, approvalsLeft: Int) -> String? {
            if approvalsLeft == 0 && status == "not_approved" { return "mergeable" }
            if approvalsLeft > 0 && status == "mergeable" { return "not_approved" }
            return status
        }

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
             pipeline: "manual", approvals: (1, 2), unresolved: 5, labels: ["backend", "payments"], approvedByMe: true),
        // Opened by the mock user, so they show up through the author list.
        make(project: (404, "platform/gateway"), iid: 233, title: "Add request tracing headers to the gateway",
             branch: "feature/GW-31-tracing", author: (MockGitLabData.me.name, MockGitLabData.me.username), hoursAgo: 2,
             pipeline: "success", approvals: (2, 2), unresolved: 0, labels: ["backend"], authorID: MockGitLabData.me.id),
        make(project: (505, "ios/app"), iid: 1290, title: "Move the settings screen to SwiftUI",
             branch: "feature/IOS-402-settings-swiftui", author: (MockGitLabData.me.name, MockGitLabData.me.username), hoursAgo: 4,
             pipeline: "failed", approvals: (1, 2), unresolved: 0, labels: ["frontend"], authorID: MockGitLabData.me.id),
        make(project: (505, "ios/app"), iid: 1295, title: "Bump swift-collections to 1.2.1",
             branch: "renovate/swift-collections-1.x", author: ("Renovate Bot", "renovate-bot"), hoursAgo: 6,
             pipeline: "success", approvals: (1, 1), unresolved: 0, labels: ["dependencies"]),
    ])

    /// The signed-in user in mock mode (`MockGitLabClient.user`).
    static let me = GitLabUser(id: 42, username: "aj", name: "A.J. Reviewer")

    static var projectLabels: [GitLabLabel] {
        let descriptions = ["needs-design": "Waiting on a design review", "blocked": "Can't move until something else lands",
                            "ready-for-qa": "Ready for QA to test"]
        let extra = ["needs-design": "#D9480F", "blocked": "#C92A2A", "ready-for-qa": "#2B8A3E"]
        return labelColors.merging(extra) { first, _ in first }
            .map { GitLabLabel(name: $0.key, color: $0.value, textColor: "#FFFFFF", description: descriptions[$0.key]) }
            .sorted { $0.name < $1.name }
    }

    private static let labelColors = [
        "backend": "#6699CC", "payments": "#009966", "frontend": "#8E44AD", "infra": "#36454F",
        "dependencies": "#7F8C8D", "bug": "#DC143C", "security": "#E67E22", "performance": "#1F78D1",
    ]

    private static let reference = Date(timeIntervalSince1970: 1_790_000_000)

    /// What GitLab would report, checked in its usual order.
    private static func mergeStatus(pipeline: String?, approvals: (given: Int, required: Int), unresolved: Int,
                                    draft: Bool, conflicts: Bool) -> String {
        if draft { return "draft_status" }
        if conflicts { return "conflict" }
        switch pipeline {
        case "failed", "canceled", "manual": return "ci_must_pass"
        case "running", "pending": return "ci_still_running"
        default: break
        }
        if approvals.given < approvals.required { return "not_approved" }
        if unresolved > 0 { return "discussions_not_resolved" }
        return "mergeable"
    }

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
        conflicts: Bool = false,
        approvedByMe: Bool = false,
        authorID: Int? = nil
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
            author: GitLabUserRef(id: authorID ?? author.username.unicodeScalars.reduce(100) { $0 + Int($1.value) },
                                  username: author.username, name: author.name),
            draft: draft,
            labels: labels.map { GitLabLabel(name: $0, color: labelColors[$0], textColor: "#FFFFFF") },
            sha: sha,
            hasConflicts: conflicts,
            detailedMergeStatus: mergeStatus(pipeline: pipeline, approvals: approvals, unresolved: unresolved,
                                             draft: draft, conflicts: conflicts),
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
        let approverNames = [("dana", "Dana Okafor"), ("samlee", "Sam Lee"), ("lena", "Lena Fischer")]
        var approvers = (0..<approvals.given).map {
            let (username, name) = approverNames[$0 % approverNames.count]
            return GitLabApprovals.Approver(user: GitLabUserRef(id: 900 + $0, username: username, name: name))
        }
        if approvedByMe, !approvers.isEmpty {
            approvers[0] = GitLabApprovals.Approver(user: GitLabUserRef(id: me.id, username: me.username, name: me.name))
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
