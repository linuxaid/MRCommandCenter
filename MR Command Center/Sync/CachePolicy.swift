import Foundation

/// Pure rules for when cached data must be refetched. Kept free of I/O so it's easy to test.
nonisolated enum CachePolicy {
    /// MR details, approvals, and discussions are refetched only when `updated_at` changed,
    /// they've never been fetched, or the user forced it.
    static func needsDetailRefresh(detailsFetchedForUpdatedAt: Date?, remoteUpdatedAt: Date, force: Bool = false) -> Bool {
        guard !force, let fetched = detailsFetchedForUpdatedAt else { return true }
        return abs(fetched.timeIntervalSince(remoteUpdatedAt)) > 0.001
    }

    /// A pipeline finishing doesn't always bump the MR's `updated_at`, so an active
    /// pipeline is re-polled on its own (one cheap request).
    /// The AI review runs only when the head SHA differs from the last successful review
    /// for the current prompt version. "Rerun" bypasses this explicitly.
    static func shouldRunAIReview(lastSuccessfulSHA: String?, headSHA: String) -> Bool {
        guard let lastSuccessfulSHA else { return true }
        return lastSuccessfulSHA != headSHA
    }

    /// Jira issues in a passing status aren't refetched on automatic refreshes. Manual
    /// refreshes always refetch, since tickets can be reopened.
    static func shouldFetchJira(previouslyPassed: Bool?, trigger: RefreshTrigger) -> Bool {
        trigger == .manual || previouslyPassed != true
    }

    static func needsPipelineRefresh(cachedStatus: PipelineStatus?, pipelineID: Int?) -> Bool {
        guard pipelineID != nil, let cachedStatus else { return false }
        return cachedStatus.isActive
    }
}
