import AppKit
import Foundation
import Observation
import SwiftData
import os

nonisolated enum RefreshTrigger: Sendable {
    case manual
    case automatic
}

enum RefreshProblem: Equatable {
    case notConfigured
    case offline
    case credentials(String)
    case failed(String)
}

/// What changed in a refresh. Phase 8 notifications hook in here.
struct RefreshOutcome: Equatable {
    var newMergeRequestKeys: [String] = []
    var newlyFailedPipelineKeys: [String] = []
    var detailFetches = 0
    var pipelineFetches = 0
    var wasInitialLoad = false
}

/// Owns the reviewer MR list: fetches from GitLab, applies the caching rules,
/// and persists `TrackedMR` rows.
@Observable
final class MergeRequestStore {
    private(set) var mergeRequests: [TrackedMR] = []
    var selectedKey: String?
    private(set) var isRefreshing = false
    private(set) var problem: RefreshProblem?
    private(set) var lastRefreshedAt: Date?
    /// Parallel detail requests per refresh.
    var detailConcurrency = 4

    /// Held so the container outlives anyone who only keeps a reference to the store;
    /// a `ModelContext` alone doesn't retain it.
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let dependencies: AppDependencies

    init(container: ModelContainer, dependencies: AppDependencies) {
        self.container = container
        self.dependencies = dependencies
        lastRefreshedAt = AccountSettings.current(in: context).lastMergeRequestRefreshAt
        reloadFromStore()
    }

    var selected: TrackedMR? {
        guard let selectedKey else { return nil }
        return mergeRequests.first { $0.key == selectedKey }
    }

    func reloadFromStore() {
        let descriptor = FetchDescriptor<TrackedMR>(
            predicate: #Predicate { $0.isInReviewerList },
            sortBy: [SortDescriptor(\.lastSeenUpdatedAt, order: .reverse)]
        )
        do {
            mergeRequests = try context.fetch(descriptor)
        } catch {
            Log.persistence.error("Fetching tracked MRs failed: \(error.localizedDescription, privacy: .public)")
        }
        if let selectedKey, !mergeRequests.contains(where: { $0.key == selectedKey }) {
            self.selectedKey = nil
        }
    }

    // MARK: Refresh

    func refreshIfStale(olderThan interval: TimeInterval) async {
        guard let lastRefreshedAt, Date.now.timeIntervalSince(lastRefreshedAt) < interval else {
            await refresh(.automatic)
            return
        }
    }

    @discardableResult
    func refresh(_ trigger: RefreshTrigger) async -> RefreshOutcome? {
        guard !isRefreshing else { return nil }
        isRefreshing = true
        defer { isRefreshing = false }

        let settings = AccountSettings.current(in: context)
        let client: any GitLabAPI
        do {
            client = try dependencies.gitLabClient(settings: settings)
        } catch {
            problem = .notConfigured
            return nil
        }

        do {
            let outcome = try await performRefresh(client: client, settings: settings)
            let now = Date.now
            settings.lastMergeRequestRefreshAt = now
            lastRefreshedAt = now
            problem = nil
            finish()
            Log.sync.info("Refresh (\(String(describing: trigger), privacy: .public)): \(self.mergeRequests.count, privacy: .public) MRs, \(outcome.detailFetches, privacy: .public) detail fetches, \(outcome.pipelineFetches, privacy: .public) pipeline fetches")
            return outcome
        } catch is CancellationError {
            finish()
            return nil
        } catch let error as APIError {
            problem = switch error {
            case .offline: .offline
            case _ where error.needsCredentialFix: .credentials(error.localizedDescription)
            default: .failed(error.localizedDescription)
            }
            Log.sync.error("Refresh failed: \(error.localizedDescription, privacy: .public)")
            finish()
            return nil
        } catch {
            problem = .failed(error.localizedDescription)
            finish()
            return nil
        }
    }

    private func finish() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving refresh results failed: \(error.localizedDescription, privacy: .public)")
        }
        reloadFromStore()
    }

    private func performRefresh(client: any GitLabAPI, settings: AccountSettings) async throws -> RefreshOutcome {
        let userID: Int
        if let cached = settings.gitLabUserID {
            userID = cached
        } else {
            let user = try await client.currentUser()
            settings.gitLabUserID = user.id
            settings.gitLabUsername = user.username
            userID = user.id
        }

        let items = try await client.openMergeRequests(reviewerID: userID)
        let existing = try context.fetch(FetchDescriptor<TrackedMR>())
        var byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var outcome = RefreshOutcome(wasInitialLoad: existing.isEmpty)
        var jobs: [DetailJob] = []
        let now = Date.now

        for item in items {
            let mr: TrackedMR
            if let found = byKey[item.key] {
                if !found.isInReviewerList { outcome.newMergeRequestKeys.append(item.key) }
                found.update(from: item)
                mr = found
            } else {
                mr = TrackedMR(from: item, now: now)
                context.insert(mr)
                byKey[item.key] = mr
                outcome.newMergeRequestKeys.append(item.key)
            }
            let jiraKey = JiraKeyExtractor.extractKey(from: mr.sourceBranch, pattern: settings.branchKeyPattern)
            if mr.jiraKey != jiraKey { mr.jiraKey = jiraKey }
            mr.lastRefreshedAt = now

            if CachePolicy.needsDetailRefresh(detailsFetchedForUpdatedAt: mr.detailsFetchedForUpdatedAt, remoteUpdatedAt: item.updatedAt) {
                jobs.append(DetailJob(key: mr.key, projectID: mr.projectID, iid: mr.iid, kind: .full))
            } else if CachePolicy.needsPipelineRefresh(cachedStatus: mr.pipelineStatus, pipelineID: mr.pipelineID),
                      let pipelineID = mr.pipelineID {
                jobs.append(DetailJob(key: mr.key, projectID: mr.projectID, iid: mr.iid, kind: .pipeline(pipelineID)))
            }
        }

        let seen = Set(items.map(\.key))
        for mr in existing where mr.isInReviewerList && !seen.contains(mr.key) {
            mr.isInReviewerList = false
        }
        try context.save()
        reloadFromStore()

        var blockingError: APIError?
        for result in await fetchAll(jobs, client: client) {
            guard let mr = byKey[result.key] else { continue }
            let previousStatus = mr.pipelineStatus
            switch result.payload {
            case .full: outcome.detailFetches += 1
            case .pipeline: outcome.pipelineFetches += 1
            case .failed: break
            }
            if let error = apply(result, to: mr) {
                blockingError = blockingError ?? error
            }
            if mr.pipelineStatus == .failed, previousStatus != .failed {
                outcome.newlyFailedPipelineKeys.append(mr.key)
            }
        }
        if let blockingError { throw blockingError }
        return outcome
    }

    /// Always refetches one MR's details, approvals, discussions, and pipeline ("Refresh this MR").
    func refreshDetails(for mr: TrackedMR) async {
        guard !refreshingKeys.contains(mr.key) else { return }
        refreshingKeys.insert(mr.key)
        defer { refreshingKeys.remove(mr.key) }

        do {
            let client = try dependencies.gitLabClient(settings: AccountSettings.current(in: context))
            let job = DetailJob(key: mr.key, projectID: mr.projectID, iid: mr.iid, kind: .full)
            if let error = apply(await Self.fetch(job, client: client), to: mr) {
                problem = error == .offline ? .offline : .credentials(error.localizedDescription)
            }
        } catch {
            problem = .notConfigured
        }
        finish()
    }

    private(set) var refreshingKeys: Set<String> = []

    /// Applies a fetch result. Returns an error that should block the whole refresh (offline or auth).
    private func apply(_ result: DetailResult, to mr: TrackedMR) -> APIError? {
        switch result.payload {
        case .full(let detail, let approvals, let discussions):
            mr.update(from: detail)
            mr.apply(pipeline: detail.headPipeline)
            mr.apply(approvals: approvals)
            mr.apply(discussions: discussions)
            if mr.changesCount != detail.changesCount { mr.changesCount = detail.changesCount }
            if let refs = detail.diffRefs {
                if mr.baseSHA != refs.baseSha { mr.baseSHA = refs.baseSha }
                if mr.startSHA != refs.startSha { mr.startSHA = refs.startSha }
            }
            mr.detailsFetchedForUpdatedAt = detail.updatedAt
            mr.detailsError = nil
        case .pipeline(let pipeline):
            mr.apply(pipeline: pipeline)
        case .failed(let error):
            mr.detailsError = error.localizedDescription
            if let apiError = error as? APIError, apiError == .offline || apiError.needsCredentialFix {
                return apiError
            }
        }
        return nil
    }

    // MARK: Detail fetching

    private struct DetailJob: Sendable {
        enum Kind: Sendable {
            case full
            case pipeline(Int)
        }

        let key: String
        let projectID: Int
        let iid: Int
        let kind: Kind
    }

    private struct DetailResult: Sendable {
        enum Payload: Sendable {
            case full(GitLabMergeRequest, GitLabApprovals, [GitLabDiscussion])
            case pipeline(GitLabPipeline)
            case failed(any Error)
        }

        let key: String
        let payload: Payload
    }

    private func fetchAll(_ jobs: [DetailJob], client: any GitLabAPI) async -> [DetailResult] {
        let limit = max(1, detailConcurrency)
        return await withTaskGroup(of: DetailResult.self) { group in
            var results: [DetailResult] = []
            var pending = jobs.makeIterator()
            for _ in 0..<min(limit, jobs.count) {
                if let job = pending.next() {
                    group.addTask { await Self.fetch(job, client: client) }
                }
            }
            while let result = await group.next() {
                results.append(result)
                if let job = pending.next() {
                    group.addTask { await Self.fetch(job, client: client) }
                }
            }
            return results
        }
    }

    @concurrent
    private nonisolated static func fetch(_ job: DetailJob, client: any GitLabAPI) async -> DetailResult {
        do {
            switch job.kind {
            case .full:
                async let detail = client.mergeRequest(projectID: job.projectID, iid: job.iid)
                async let approvals = client.approvals(projectID: job.projectID, iid: job.iid)
                async let discussions = client.discussions(projectID: job.projectID, iid: job.iid)
                return DetailResult(key: job.key, payload: .full(try await detail, try await approvals, try await discussions))
            case .pipeline(let pipelineID):
                let pipeline = try await client.pipeline(projectID: job.projectID, pipelineID: pipelineID)
                return DetailResult(key: job.key, payload: .pipeline(pipeline))
            }
        } catch {
            return DetailResult(key: job.key, payload: .failed(error))
        }
    }

    // MARK: Navigation

    func selectNext() { moveSelection(by: 1) }
    func selectPrevious() { moveSelection(by: -1) }

    private func moveSelection(by offset: Int) {
        guard !mergeRequests.isEmpty else { return }
        guard let selectedKey, let index = mergeRequests.firstIndex(where: { $0.key == selectedKey }) else {
            self.selectedKey = offset > 0 ? mergeRequests.first?.key : mergeRequests.last?.key
            return
        }
        let next = min(max(index + offset, 0), mergeRequests.count - 1)
        self.selectedKey = mergeRequests[next].key
    }

    func openSelectedInBrowser() {
        guard let url = selected.flatMap({ URL(string: $0.webURL) }) else { return }
        NSWorkspace.shared.open(url)
    }
}
