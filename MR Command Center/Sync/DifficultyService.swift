import Foundation
import SwiftData
import os

/// Scores how hard each open MR is to review (#36): rules over the diff once per head commit,
/// then a nudge of at most one point from the on-device model when it's available. Uses the
/// diff `DiffService` already cached for the static checks, so it costs no extra requests.
final class DifficultyService {
    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let dependencies: AppDependencies
    private let diffs: DiffService
    private var nudgeTask: Task<Void, Never>?
    /// MRs whose diff facts are being worked out, so a refresh and "Refresh This MR" never
    /// fetch the same diff twice.
    private var inFlight: Set<String> = []

    init(container: ModelContainer, dependencies: AppDependencies, diffs: DiffService) {
        self.container = container
        self.dependencies = dependencies
        self.diffs = diffs
    }

    /// After a refresh: work out the diff facts for every MR whose head commit hasn't been scored.
    func evaluateMissing(_ mrs: [TrackedMR]) async {
        for mr in mrs where needsFacts(mr) {
            guard !Task.isCancelled else { return }
            await evaluate(mr)
        }
    }

    func needsFacts(_ mr: TrackedMR) -> Bool {
        !mr.headSHA.isEmpty && mr.difficultySHA != mr.headSHA
    }

    func evaluate(_ mr: TrackedMR) async {
        guard !inFlight.contains(mr.key) else { return }
        inFlight.insert(mr.key)
        defer { inFlight.remove(mr.key) }
        let headSHA = mr.headSHA
        let patterns = AccountSettings.current(in: context).extraTestPathPatterns
        do {
            let diff = try await diffs.diff(for: mr)
            let facts = await Self.facts(diff, extraTestPatterns: patterns)
            // A push landed while the diff loaded: the next refresh scores the new commit.
            guard mr.headSHA == headSHA else { return }
            mr.difficultyFactsData = try JSONEncoder().encode(facts)
            mr.difficultySHA = headSHA
            save()
        } catch is CancellationError {
            return
        } catch {
            Log.sync.error("Difficulty couldn't load the diff: \(error.localizedDescription, privacy: .public)")
        }
    }

    @concurrent
    private nonisolated static func facts(_ diff: MRDiff, extraTestPatterns: [String]) async -> DiffFacts {
        DiffFacts(diff, extraTestPatterns: extraTestPatterns)
    }

    // MARK: The model's nudge

    func needsNudge(_ mr: TrackedMR) -> Bool {
        mr.difficultyFacts != nil && mr.difficultyNudgeSHA != mr.headSHA
    }

    /// Asks the model about each scored MR it hasn't seen at this commit, one at a time in the
    /// background so a refresh never waits on it. Does nothing while the model is unavailable;
    /// the rules' score stands alone until it is. While a batch is running new requests are
    /// dropped; anything they'd have covered is picked up after the next refresh.
    /// `after` runs first, to wait for other model work.
    func startNudges(for mrs: [TrackedMR], after: (() async -> Void)? = nil) {
        guard nudgeTask == nil, dependencies.modelStatus().isAvailable else { return }
        let pending = mrs.filter(needsNudge)
        guard !pending.isEmpty else { return }
        nudgeTask = Task { [weak self] in
            await after?()
            for mr in pending {
                guard let self, !Task.isCancelled, await self.nudge(mr) else { break }
            }
            self?.nudgeTask = nil
        }
    }

    /// Waits for the background nudges to finish (tests).
    func waitForNudges() async {
        await nudgeTask?.value
    }

    /// False when the model is busy or not ready, so the rest of the batch waits for the next refresh.
    @discardableResult
    func nudge(_ mr: TrackedMR) async -> Bool {
        let headSHA = mr.headSHA
        guard needsNudge(mr), let difficulty = mr.difficulty else { return true }
        do {
            let diff = try await diffs.diff(for: mr)
            let prompt = DifficultyPrompt.prompt(title: mr.title, diff: diff, ruleScore: difficulty.ruleScore)
            let nudge = try await dependencies.reviewModel()
                .difficulty(instructions: DifficultyPrompt.instructions, prompt: prompt, options: ReviewOptions(maximumResponseTokens: 120))
            guard mr.headSHA == headSHA else { return true }
            mr.difficultyNudgeData = try JSONEncoder().encode(nudge)
        } catch is CancellationError {
            return false
        } catch {
            let failure = ReviewFailureMapper.map(error)
            Log.sync.error("The model couldn't judge difficulty: \(failure.title, privacy: .public)")
            // Busy, timed out or not ready: try again after the next refresh. Background apps
            // get rate-limited, and nudges run after automatic refreshes.
            if failure == .rateLimited || failure == .modelUnavailable { return false }
            guard mr.headSHA == headSHA, !Self.isTemporary(failure) else { return true }
            // Something about this MR the model won't or can't answer: not asked again at
            // this commit, and the rules' score stands alone.
            mr.difficultyNudgeData = nil
        }
        mr.difficultyNudgeSHA = headSHA
        save()
        return true
    }

    static func isTemporary(_ failure: ReviewFailure) -> Bool { failure.isTemporary }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving difficulty failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

extension ReviewFailure {
    /// Busy, timed out or not ready: worth asking again later, unlike a refusal or an answer
    /// that won't fit.
    nonisolated var isTemporary: Bool {
        switch self {
        case .rateLimited, .timeout, .modelUnavailable, .other: true
        case .contextSizeExceeded, .guardrailViolation, .unsupportedLanguage, .refusal, .decodingFailure: false
        }
    }
}
