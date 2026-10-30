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
    /// the rules' score stands alone until it is.
    func startNudges(for mrs: [TrackedMR]) {
        guard nudgeTask == nil, dependencies.modelStatus().isAvailable else { return }
        let pending = mrs.filter(needsNudge)
        guard !pending.isEmpty else { return }
        nudgeTask = Task { [weak self] in
            for mr in pending {
                guard let self, !Task.isCancelled else { break }
                await self.nudge(mr)
            }
            self?.nudgeTask = nil
        }
    }

    /// Waits for the background nudges to finish (tests).
    func waitForNudges() async {
        await nudgeTask?.value
    }

    func nudge(_ mr: TrackedMR) async {
        let headSHA = mr.headSHA
        guard needsNudge(mr), let difficulty = mr.difficulty else { return }
        do {
            let diff = try await diffs.diff(for: mr)
            let prompt = DifficultyPrompt.prompt(title: mr.title, diff: diff, ruleScore: difficulty.ruleScore)
            let nudge = try await dependencies.reviewModel()
                .difficulty(instructions: DifficultyPrompt.instructions, prompt: prompt, options: ReviewOptions(maximumResponseTokens: 120))
            guard mr.headSHA == headSHA else { return }
            mr.difficultyNudgeData = try JSONEncoder().encode(nudge)
        } catch is CancellationError {
            return
        } catch {
            guard mr.headSHA == headSHA else { return }
            // Not asked again at this commit; the rules' score stands alone.
            mr.difficultyNudgeData = nil
            Log.sync.error("The model couldn't judge difficulty: \(ReviewFailureMapper.map(error).title, privacy: .public)")
        }
        mr.difficultyNudgeSHA = headSHA
        save()
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving difficulty failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
