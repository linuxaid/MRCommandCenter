import Foundation
import Observation
import SwiftData
import os

/// Eval sets, batch runs against a prompt version, and their metrics.
@Observable
final class EvalService {
    struct BatchProgress: Equatable {
        let batchID: UUID
        let total: Int
        var finished = 0
        var currentCase: String?
    }

    private(set) var progress: BatchProgress?
    /// Bumped on any change so views reading cases, batches, or metrics refresh.
    private(set) var revision = 0

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private let diffs: DiffService
    @ObservationIgnored private let staticChecks: StaticCheckService
    @ObservationIgnored private let aiReview: AIReviewService
    @ObservationIgnored private var task: Task<Void, Never>?
    private var context: ModelContext { container.mainContext }

    init(container: ModelContainer, dependencies: AppDependencies, diffs: DiffService,
         staticChecks: StaticCheckService, aiReview: AIReviewService) {
        self.container = container
        self.dependencies = dependencies
        self.diffs = diffs
        self.staticChecks = staticChecks
        self.aiReview = aiReview
        markInterruptedBatches()
    }

    // MARK: Cases

    var cases: [EvalCase] {
        _ = revision
        return (try? context.fetch(FetchDescriptor<EvalCase>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
    }

    func existingCase(for mr: TrackedMR) -> EvalCase? {
        let key = mr.key
        let sha = mr.headSHA
        return try? context.fetch(FetchDescriptor<EvalCase>(predicate: #Predicate { $0.mrKey == key && $0.headSHA == sha })).first
    }

    /// Snapshots the MR at its head SHA (diff, static flags, Jira data) as an eval case,
    /// or updates the expectations if this SHA is already in the set.
    @discardableResult
    func saveCase(for mr: TrackedMR, expectedVerdict: VerdictStatus, expectedConcerns: [ExpectedConcern], notes: String) async throws -> EvalCase {
        if let existing = existingCase(for: mr) {
            existing.expectedVerdict = expectedVerdict
            existing.expectedConcerns = expectedConcerns
            existing.notes = notes
            changed()
            return existing
        }
        let diff = try await diffs.diff(for: mr)
        guard let snapshot = diffs.cachedSnapshot(mrKey: mr.key, headSHA: diff.headSHA) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        await staticChecks.evaluate(mr)
        let report = staticChecks.report(for: mr)
        let evalCase = try EvalCase(
            mr: mr, diffs: try snapshot.decodedDiffs(), findings: report.results.flatMap(\.findings),
            staticSummary: AIReviewService.summary(of: report),
            expectedVerdict: expectedVerdict, expectedConcerns: expectedConcerns, notes: notes
        )
        let story = aiReview.storyContext(for: mr)
        evalCase.jiraSummary = story.jiraSummary
        evalCase.acceptanceCriteria = story.acceptanceCriteria
        evalCase.storyDescription = story.storyDescription
        context.insert(evalCase)
        changed()
        return evalCase
    }

    func delete(_ evalCase: EvalCase) {
        context.delete(evalCase)
        changed()
    }

    // MARK: Batches

    var batches: [EvalBatch] {
        _ = revision
        return (try? context.fetch(FetchDescriptor<EvalBatch>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)]))) ?? []
    }

    func runs(in batch: EvalBatch) -> [AIReviewRun] {
        _ = revision
        let id = Optional(batch.id)
        return (try? context.fetch(FetchDescriptor<AIReviewRun>(predicate: #Predicate { $0.evalBatchID == id },
                                                                sortBy: [SortDescriptor(\.startedAt)]))) ?? []
    }

    func metrics(for batch: EvalBatch) -> BatchMetrics {
        let caseIDs = Set(batch.caseIDs)
        let facts = cases.filter { caseIDs.contains($0.id) }.map(\.facts)
        return EvalMetrics.compute(cases: facts, runs: runs(in: batch).compactMap(\.evalFacts))
    }

    var isRunning: Bool { progress != nil }

    /// Reviews every case's snapshot with the given prompt version, one case at a time.
    /// Tools are off so runs depend only on the snapshot.
    func runBatch(prompt: PromptVersion, cases: [EvalCase]) {
        aiReview.refreshStatus()
        guard !isRunning, !cases.isEmpty, aiReview.modelStatus.isAvailable else { return }
        let settings = AccountSettings.current(in: context)
        let model = dependencies.reviewModel()
        let batch = EvalBatch(prompt: prompt.snapshot, modelIdentifier: model.identifier,
                              caseIDs: cases.map(\.id), greedy: settings.aiGreedySampling)
        context.insert(batch)
        save()
        progress = BatchProgress(batchID: batch.id, total: cases.count)
        let options = ReviewOptions(greedy: settings.aiGreedySampling, temperature: settings.aiTemperature, toolsEnabled: false)
        let concurrency = max(1, settings.aiConcurrencyLimit)
        let skills = aiReview.enabledSkills()
        let prompt = prompt.snapshot

        task = Task {
            for evalCase in cases {
                if Task.isCancelled { break }
                progress?.currentCase = evalCase.name
                await review(evalCase, batch: batch, prompt: prompt, model: model, options: options,
                             concurrency: concurrency, skills: skills)
                progress?.finished += 1
                changed()
            }
            batch.status = Task.isCancelled ? .cancelled : .completed
            batch.finishedAt = .now
            progress = nil
            task = nil
            changed()
        }
    }

    func cancelBatch() { task?.cancel() }

    /// Waits for the running batch (tests).
    func waitForBatch() async { await task?.value }

    func delete(_ batch: EvalBatch) {
        runs(in: batch).forEach(context.delete)
        context.delete(batch)
        changed()
    }

    private func review(_ evalCase: EvalCase, batch: EvalBatch, prompt: PromptSnapshot, model: any ReviewLanguageModel,
                        options: ReviewOptions, concurrency: Int, skills: [SkillSnapshot]) async {
        let run = AIReviewRun(mrKey: evalCase.mrKey, projectID: evalCase.projectID, iid: evalCase.iid, mrTitle: evalCase.mrTitle,
                              headSHA: evalCase.headSHA, prompt: prompt, modelIdentifier: model.identifier)
        run.evalCaseID = evalCase.id
        run.evalBatchID = batch.id
        run.usedAcceptanceCriteria = evalCase.context.hasAcceptanceCriteria
        context.insert(run)
        save()

        let job = ReviewJob(
            files: evalCase.diffs.enumerated().map { DiffFile($1, index: $0) },
            context: evalCase.context,
            flagsByPath: Dictionary(grouping: evalCase.findings, by: \.path),
            staticSummary: evalCase.staticSummary,
            skills: skills,
            prompt: prompt,
            options: options,
            concurrency: concurrency
        )
        let outputs = OutputCollector()
        let outcome = await ReviewEngine(model: model).run(job) { event in
            if case .fileFinished(let output) = event { await outputs.append(output) }
        }
        for output in await outputs.all {
            AIReviewService.store(output, in: run, context: context)
        }
        AIReviewService.applyVerdict(of: outcome, to: run)
        run.status = outcome.wasCancelled ? .cancelled : .completed
        run.finishedAt = .now
        save()
    }

    private func markInterruptedBatches() {
        let running = BatchStatus.running.rawValue
        let stale = (try? context.fetch(FetchDescriptor<EvalBatch>(predicate: #Predicate { $0.statusRaw == running }))) ?? []
        for batch in stale { batch.status = .cancelled }
        if !stale.isEmpty { save() }
    }

    private func changed() {
        save()
        revision += 1
    }

    private func save() {
        do { try context.save() } catch {
            Log.persistence.error("Saving eval data failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Collects file results from the engine's event stream.
private actor OutputCollector {
    private(set) var all: [FileReviewOutput] = []
    func append(_ output: FileReviewOutput) { all.append(output) }
}
