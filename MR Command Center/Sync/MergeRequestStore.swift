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

/// Owns the list of open MRs you review or authored: fetches from GitLab, applies the
/// caching rules, persists `TrackedMR` rows, and records what changed as `ActivityEvent`s.
@Observable
final class MergeRequestStore {
    /// Every open MR where you're a reviewer or the author, drafts included.
    private(set) var trackedMergeRequests: [TrackedMR] = []
    /// Your GitLab username, once known.
    private(set) var username: String?
    var selectedKey: String? {
        didSet { if selectedKey != nil { selectedPastKey = nil } }
    }
    /// A merged or closed MR picked from Activity. It's shown read only, from the last
    /// snapshot taken before it left your list. Picking an open MR clears it.
    var selectedPastKey: String? {
        didSet { if selectedPastKey != nil { selectedKey = nil } }
    }
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
        let settings = AccountSettings.current(in: context)
        lastRefreshedAt = settings.lastMergeRequestRefreshAt
        username = settings.gitLabUsername
        reloadFromStore()
    }

    var selected: TrackedMR? {
        guard let selectedKey else { return nil }
        return mergeRequest(forKey: selectedKey)
    }

    func mergeRequest(forKey key: String) -> TrackedMR? {
        trackedMergeRequests.first { $0.key == key }
    }

    /// Fetches on every read; fine for the detail column, not for per-row checks.
    var selectedPast: TrackedMR? {
        selectedPastKey.flatMap(pastMergeRequest(forKey:))
    }

    /// The saved snapshot of an MR that's no longer open, or nil if it's still in your list.
    func pastMergeRequest(forKey key: String) -> TrackedMR? {
        var descriptor = FetchDescriptor<TrackedMR>(predicate: #Predicate { $0.key == key && !$0.isInReviewerList })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Keys of every MR an Activity row can open: open ones plus saved snapshots of past ones.
    /// One fetch, so Activity can check each of its rows against it.
    func openableActivityKeys() -> Set<String> {
        var descriptor = FetchDescriptor<TrackedMR>(predicate: #Predicate { !$0.isInReviewerList })
        descriptor.propertiesToFetch = [\.key]
        let past = (try? context.fetch(descriptor))?.map(\.key) ?? []
        return Set(trackedMergeRequests.map(\.key)).union(past)
    }

    /// Opens an Activity row: the brief for an open MR, the read-only view for a past one.
    func selectActivity(forKey key: String) {
        if mergeRequest(forKey: key) != nil {
            selectedKey = key
        } else if pastMergeRequest(forKey: key) != nil {
            selectedPastKey = key
        }
    }

    /// Marks the MR's activity as seen.
    func markSeen(_ mr: TrackedMR) {
        guard mr.hasUnseenActivity else { return }
        mr.seenAt = .now
        save()
    }

    func reloadFromStore() {
        let descriptor = FetchDescriptor<TrackedMR>(
            predicate: #Predicate { $0.isInReviewerList },
            sortBy: [SortDescriptor(\.lastSeenUpdatedAt, order: .reverse)]
        )
        do {
            trackedMergeRequests = try context.fetch(descriptor)
        } catch {
            Log.persistence.error("Fetching tracked MRs failed: \(error.localizedDescription, privacy: .public)")
        }
        if let selectedKey, !trackedMergeRequests.contains(where: { $0.key == selectedKey }) {
            self.selectedKey = nil
        }
        // A past MR that's back in the list (reopened, or you were added again) is open now.
        if let selectedPastKey, trackedMergeRequests.contains(where: { $0.key == selectedPastKey }) {
            selectedKey = selectedPastKey
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
            Log.sync.info("Refresh (\(String(describing: trigger), privacy: .public)): \(self.trackedMergeRequests.count, privacy: .public) MRs, \(outcome.detailFetches, privacy: .public) detail fetches, \(outcome.pipelineFetches, privacy: .public) pipeline fetches")
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
        save()
        reloadFromStore()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving refresh results failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func performRefresh(client: any GitLabAPI, settings: AccountSettings) async throws -> RefreshOutcome {
        let userID: Int
        if let cached = settings.gitLabUserID, settings.gitLabUsername != nil {
            userID = cached
        } else {
            let user = try await client.currentUser()
            settings.gitLabUserID = user.id
            settings.gitLabUsername = user.username
            userID = user.id
        }
        username = settings.gitLabUsername

        async let reviewing = client.openMergeRequests(reviewerID: userID)
        async let authored = client.openMergeRequests(authorID: userID)
        let reviewingItems = try await reviewing
        let authoredItems = try await authored
        let reviewingKeys = Set(reviewingItems.map(\.key))
        let authoredKeys = Set(authoredItems.map(\.key))
        var items = reviewingItems
        items += authoredItems.filter { !reviewingKeys.contains($0.key) }

        let existing = try context.fetch(FetchDescriptor<TrackedMR>())
        var byKey = Dictionary(existing.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        var outcome = RefreshOutcome(wasInitialLoad: existing.isEmpty)
        var jobs: [DetailJob] = []
        var before: [String: MRSnapshot] = [:]
        let now = Date.now

        for item in items {
            let mr: TrackedMR
            if let found = byKey[item.key] {
                if found.isInReviewerList {
                    before[item.key] = MRSnapshot(found)
                } else {
                    outcome.newMergeRequestKeys.append(item.key)
                }
                found.update(from: item)
                mr = found
            } else {
                mr = TrackedMR(from: item, now: now)
                context.insert(mr)
                byKey[item.key] = mr
                outcome.newMergeRequestKeys.append(item.key)
            }
            let isReviewer = reviewingKeys.contains(item.key)
            let isAuthor = authoredKeys.contains(item.key)
            if mr.isReviewer != isReviewer { mr.isReviewer = isReviewer }
            if mr.isAuthor != isAuthor { mr.isAuthor = isAuthor }
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
            record(ActivityDetector.Change(kind: .left, message: "Merged or closed"), for: mr, at: now)
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

        if !outcome.wasInitialLoad {
            for key in outcome.newMergeRequestKeys {
                guard let mr = byKey[key] else { continue }
                let message = mr.isAuthor ? "You opened this merge request" : "\(mr.authorName) asked you to review"
                record(ActivityDetector.Change(kind: .appeared, message: message), for: mr, at: now)
            }
        }
        for (key, snapshot) in before {
            guard let mr = byKey[key] else { continue }
            for change in ActivityDetector.changes(from: snapshot, to: MRSnapshot(mr)) {
                record(change, for: mr, at: now)
            }
        }
        pruneActivity()
        if let blockingError { throw blockingError }
        return outcome
    }

    // MARK: Activity

    /// Saves an activity line and marks the MR as having something new.
    func record(_ change: ActivityDetector.Change, for mr: TrackedMR, at date: Date = .now) {
        context.insert(ActivityEvent(kind: change.kind, message: change.message, mrKey: mr.key,
                                     mrReference: mr.reference, mrTitle: mr.title, date: date))
        mr.lastActivityAt = date
    }

    /// Keeps the newest events only.
    private func pruneActivity(keeping limit: Int = 1000) {
        guard let all = try? context.fetch(FetchDescriptor<ActivityEvent>(sortBy: [SortDescriptor(\.date, order: .reverse)])),
              all.count > limit else { return }
        for event in all[limit...] { context.delete(event) }
    }

    /// Always refetches one MR's details, approvals, discussions, and pipeline ("Refresh this MR").
    func refreshDetails(for mr: TrackedMR) async {
        guard !refreshingKeys.contains(mr.key) else { return }
        refreshingKeys.insert(mr.key)
        defer { refreshingKeys.remove(mr.key) }

        do {
            let client = try dependencies.gitLabClient(settings: AccountSettings.current(in: context))
            let job = DetailJob(key: mr.key, projectID: mr.projectID, iid: mr.iid, kind: .full)
            let snapshot = MRSnapshot(mr)
            if let error = apply(await Self.fetch(job, client: client), to: mr) {
                problem = error == .offline ? .offline : .credentials(error.localizedDescription)
            }
            for change in ActivityDetector.changes(from: snapshot, to: MRSnapshot(mr)) {
                record(change, for: mr)
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
            mr.apply(discussions: discussions, me: username)
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

    /// Moves the selection through `order` (the keys as the list shows them), clamping at the ends.
    func moveSelection(by offset: Int, in order: [String]) {
        guard !order.isEmpty else { return }
        guard let selectedKey, let index = order.firstIndex(of: selectedKey) else {
            self.selectedKey = offset > 0 ? order.first : order.last
            return
        }
        self.selectedKey = order[min(max(index + offset, 0), order.count - 1)]
    }

    /// The GitLab page ⌘O opens: the selected open MR, or the merged or closed one picked in Activity.
    var browserURL: URL? {
        (selected ?? selectedPast).flatMap { URL(string: $0.webURL) }
    }

    func openSelectedInBrowser() {
        guard let url = browserURL else { return }
        NSWorkspace.shared.open(url)
    }
}
