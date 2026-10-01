import Foundation
import Observation
import SwiftData
import os

/// Runs and caches static checks. Diff checks run once per head SHA and check
/// configuration; metadata checks are recomputed from cached MR fields on demand.
@Observable
final class StaticCheckService {
    @ObservationIgnored private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    @ObservationIgnored private let diffs: DiffService
    /// Decoded snapshots, keyed by snapshot ID + fingerprint. Filled lazily during reads,
    /// so it's not observed; `revision` signals new results instead.
    @ObservationIgnored private var decoded: [String: [CheckResult]] = [:]
    /// Bumped whenever results are stored, so views reading reports update.
    private(set) var revision = 0
    private(set) var inFlight: Set<String> = []
    /// Why the diff checks couldn't run, keyed by MR.
    private(set) var errors: [String: String] = [:]

    init(container: ModelContainer, diffs: DiffService) {
        self.container = container
        self.diffs = diffs
    }

    private var configuration: CheckConfiguration {
        AccountSettings.current(in: context).checkConfiguration
    }

    func report(for mr: TrackedMR) -> CheckReport {
        _ = revision
        let metadata = StaticChecks.metadataChecks(MRCheckInput(mr))
        if let cached = cachedDiffResults(for: mr) {
            return CheckReport(results: metadata + cached, diffChecksAvailable: true)
        }
        let reason = errors[mr.key].map { "Couldn't analyze the diff: \($0)" } ?? "Analyzing the diff…"
        return CheckReport(results: metadata + StaticChecks.pendingDiffChecks(reason: reason), diffChecksAvailable: false)
    }

    func cachedDiffResults(for mr: TrackedMR) -> [CheckResult]? {
        let fingerprint = configuration.fingerprint
        let id = "\(mr.key)@\(mr.headSHA)"
        if let results = decoded[id + fingerprint] { return results }
        var descriptor = FetchDescriptor<StaticCheckSnapshot>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let snapshot = try? context.fetch(descriptor).first,
              snapshot.configurationFingerprint == fingerprint,
              let results = try? snapshot.results() else { return nil }
        decoded[id + fingerprint] = results
        return results
    }

    /// Runs the diff checks for the MR's head SHA if they aren't cached. Fetches the diff
    /// through `DiffService`, which caches it per SHA too.
    func evaluate(_ mr: TrackedMR, force: Bool = false) async {
        guard force || cachedDiffResults(for: mr) == nil, !inFlight.contains(mr.key) else { return }
        inFlight.insert(mr.key)
        defer { inFlight.remove(mr.key) }

        let configuration = configuration
        let headSHA = mr.headSHA
        do {
            let diff = try await diffs.diff(for: mr)
            let results = await Self.run(diff, configuration: configuration)
            store(results, for: mr, headSHA: headSHA, fingerprint: configuration.fingerprint)
            errors[mr.key] = nil
        } catch is CancellationError {
            return
        } catch {
            errors[mr.key] = error.localizedDescription
            Log.sync.error("Static checks couldn't load the diff: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// After a refresh: analyze every MR whose head SHA hasn't been checked yet.
    func evaluateMissing(_ mrs: [TrackedMR]) async {
        for mr in mrs where cachedDiffResults(for: mr) == nil {
            guard !Task.isCancelled else { return }
            await evaluate(mr)
        }
    }

    @concurrent
    private nonisolated static func run(_ diff: MRDiff, configuration: CheckConfiguration) async -> [CheckResult] {
        StaticChecks.diffChecks(diff, configuration: configuration)
    }

    private func store(_ results: [CheckResult], for mr: TrackedMR, headSHA: String, fingerprint: String) {
        do {
            let key = mr.key
            let stale = try context.fetch(FetchDescriptor<StaticCheckSnapshot>(predicate: #Predicate { $0.mrKey == key }))
            stale.forEach(context.delete)
            context.insert(try StaticCheckSnapshot(mrKey: key, headSHA: headSHA, fingerprint: fingerprint, results: results))
            decoded["\(key)@\(headSHA)" + fingerprint] = results
            mr.diffCheckSHA = headSHA
            mr.diffCheckFailures = results.count { $0.outcome == .fail }
            mr.diffCheckWarnings = results.count { $0.outcome == .warning }
            try context.save()
            revision += 1
        } catch {
            Log.persistence.error("Caching static checks failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
