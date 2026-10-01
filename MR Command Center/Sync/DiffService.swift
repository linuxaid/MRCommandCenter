import Foundation
import SwiftData
import os

/// Fetches MR diffs lazily and caches them per head SHA.
final class DiffService {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let dependencies: AppDependencies

    init(container: ModelContainer, dependencies: AppDependencies) {
        self.container = container
        self.dependencies = dependencies
    }

    /// Returns the cached diff for the MR's current head SHA, fetching it if needed.
    func diff(for mr: TrackedMR, forceRefresh: Bool = false) async throws -> MRDiff {
        let key = mr.key
        let headSHA = mr.headSHA
        if !forceRefresh, let snapshot = cachedSnapshot(mrKey: key, headSHA: headSHA) {
            return try await Self.parse(snapshot.decodedDiffs(), headSHA: headSHA, changesCount: snapshot.changesCount,
                                        fetchedAt: snapshot.fetchedAt, refs: snapshot.refs ?? mr.diffRefs)
        }

        let settings = AccountSettings.current(in: context)
        let client = try dependencies.gitLabClient(settings: settings)
        let diffs = try await client.diffs(projectID: mr.projectID, iid: mr.iid)
        let now = Date.now
        let refs = mr.diffRefs
        store(diffs, mrKey: key, headSHA: headSHA, changesCount: mr.changesCount, refs: refs, fetchedAt: now)
        return await Self.parse(diffs, headSHA: headSHA, changesCount: mr.changesCount, fetchedAt: now, refs: refs)
    }

    func cachedSnapshot(mrKey: String, headSHA: String) -> DiffSnapshot? {
        let id = DiffSnapshot.makeID(mrKey: mrKey, headSHA: headSHA)
        var descriptor = FetchDescriptor<DiffSnapshot>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func store(_ diffs: [GitLabDiff], mrKey: String, headSHA: String, changesCount: String?, refs: DiffRefs?, fetchedAt: Date) {
        do {
            // Older commits' diffs aren't needed for display; AI runs and eval cases keep their own copies.
            let stale = try context.fetch(FetchDescriptor<DiffSnapshot>(predicate: #Predicate { $0.mrKey == mrKey }))
            stale.forEach(context.delete)
            context.insert(try DiffSnapshot(mrKey: mrKey, headSHA: headSHA, diffs: diffs, changesCount: changesCount, refs: refs, fetchedAt: fetchedAt))
            try context.save()
        } catch {
            Log.persistence.error("Caching diff failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @concurrent
    private nonisolated static func parse(_ diffs: [GitLabDiff], headSHA: String, changesCount: String?, fetchedAt: Date, refs: DiffRefs?) async -> MRDiff {
        MRDiff(headSHA: headSHA, diffs: diffs, changesCount: changesCount, fetchedAt: fetchedAt, refs: refs)
    }
}
