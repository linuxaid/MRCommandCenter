import Foundation
import Observation
import SwiftData
import os

/// Live progress of one running review, for the AI Review tab.
@Observable
final class RunProgress {
    enum FileState: Equatable {
        case queued, running
        case reviewed(concerns: Int)
        case skipped(String)
        case failed(String)
    }

    let startedAt = Date.now
    private(set) var paths: [String] = []
    private(set) var states: [String: FileState] = [:]
    var isMerging = false
    var message: String?

    func plan(_ paths: [String]) {
        self.paths = paths
        states = Dictionary(uniqueKeysWithValues: paths.map { ($0, .queued) })
    }

    func set(_ path: String, _ state: FileState) { states[path] = state }

    var finishedCount: Int {
        states.values.count { if case .queued = $0 { false } else if case .running = $0 { false } else { true } }
    }
}

/// Runs on-device AI reviews and stores them as `AIReviewRun`s.
@Observable
final class AIReviewService {
    private(set) var modelStatus: ModelStatus = .available
    private(set) var progress: [String: RunProgress] = [:]
    /// Bumped when runs are saved so views reading runs update.
    private(set) var revision = 0

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private let dependencies: AppDependencies
    @ObservationIgnored private let diffs: DiffService
    @ObservationIgnored private let staticChecks: StaticCheckService
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Runs in progress by MR key (SwiftData models can't cross into the engine's closures).
    @ObservationIgnored private var activeRuns: [String: AIReviewRun] = [:]
    private var context: ModelContext { container.mainContext }

    @ObservationIgnored private let jira: JiraService

    init(container: ModelContainer, dependencies: AppDependencies, diffs: DiffService, staticChecks: StaticCheckService, jira: JiraService) {
        self.container = container
        self.dependencies = dependencies
        self.diffs = diffs
        self.staticChecks = staticChecks
        self.jira = jira
        seedDefaults()
        markInterruptedRuns()
        refreshStatus()
    }

    func refreshStatus() {
        let status = dependencies.modelStatus()
        if status != modelStatus { modelStatus = status }
    }

    // MARK: Queries

    var activePrompt: PromptVersion {
        let settings = AccountSettings.current(in: context)
        let versions = (try? context.fetch(FetchDescriptor<PromptVersion>(sortBy: [SortDescriptor(\.createdAt)]))) ?? []
        if let id = settings.activePromptVersionID, let active = versions.first(where: { $0.id == id }) { return active }
        if let first = versions.first { return first }
        seedDefaults()
        return (try? context.fetch(FetchDescriptor<PromptVersion>()))?.first ?? PromptVersion(
            name: "v1", fileInstructions: PromptVersion.defaultFileInstructions, mergeInstructions: PromptVersion.defaultMergeInstructions)
    }

    func runs(for mrKey: String) -> [AIReviewRun] {
        _ = revision
        let descriptor = FetchDescriptor<AIReviewRun>(
            predicate: #Predicate { $0.mrKey == mrKey && $0.evalBatchID == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    func latestRun(for mrKey: String) -> AIReviewRun? { runs(for: mrKey).first }

    /// The newest run with a verdict for the given prompt version.
    func latestSuccessfulRun(for mrKey: String, promptVersionID: UUID) -> AIReviewRun? {
        runs(for: mrKey).first { $0.promptVersionID == promptVersionID && $0.status == .completed && $0.verdictStatusRaw != nil }
    }

    func needsReview(_ mr: TrackedMR) -> Bool {
        CachePolicy.shouldRunAIReview(lastSuccessfulSHA: latestSuccessfulRun(for: mr.key, promptVersionID: activePrompt.id)?.headSHA,
                                      headSHA: mr.headSHA)
    }

    func isRunning(_ mrKey: String) -> Bool { progress[mrKey] != nil }

    /// The run whose concerns count as "open": the latest with a verdict at the reviewed SHA.
    func currentRun(for mr: TrackedMR) -> AIReviewRun? {
        runs(for: mr.key).first { $0.status == .completed && $0.verdictStatusRaw != nil && $0.headSHA == (mr.aiReviewedSHA ?? mr.headSHA) }
    }

    /// Recomputes the sidebar's open-concern count after a review, post, or dismissal.
    func updateOpenConcerns(for mr: TrackedMR) {
        let open = currentRun(for: mr)?.files.flatMap(\.concerns).count(where: \.isOpen) ?? 0
        if mr.aiOpenConcerns != open { mr.aiOpenConcerns = open }
        save()
        revision += 1
    }

    func setDismissed(_ concern: ConcernRecord, _ dismissed: Bool, mr: TrackedMR) {
        concern.dismissedAt = dismissed ? .now : nil
        updateOpenConcerns(for: mr)
    }

    /// Draft text for the MR summary thread: verdict, rationale, and the open concerns.
    func summaryBody(for run: AIReviewRun, mr: TrackedMR) -> String {
        let concerns = run.orderedFiles.flatMap { file in
            file.orderedConcerns.filter { $0.dismissedAt == nil }.map {
                AICommentFormatter.SummaryConcern(path: file.path, lineHint: $0.lineHint, severity: $0.severity, explanation: $0.explanation)
            }
        }
        return AICommentFormatter.summary(verdict: run.verdictStatus, rationale: run.rationale, headSHA: run.headSHA,
                                          promptName: run.promptVersionName,
                                          staticSummary: Self.summary(of: staticChecks.report(for: mr)), concerns: concerns)
    }

    /// Worth posting a summary when the verdict isn't "looks good" or concerns are still open.
    func summaryIsWorthPosting(_ run: AIReviewRun) -> Bool {
        run.verdictStatus != .looksGood || run.files.flatMap(\.concerns).contains(where: \.isOpen)
    }

    // MARK: Running

    /// Starts a review. Unless `rerun` is set, does nothing when the head SHA was already
    /// reviewed with the current prompt version.
    func start(_ mr: TrackedMR, rerun: Bool = false) {
        refreshStatus()
        guard modelStatus.isAvailable, !isRunning(mr.key) else { return }
        guard rerun || needsReview(mr) else { return }
        let key = mr.key
        progress[key] = RunProgress()
        tasks[key] = Task {
            await perform(mr)
            progress[key] = nil
            tasks[key] = nil
        }
    }

    func cancel(_ mrKey: String) {
        tasks[mrKey]?.cancel()
        progress[mrKey]?.message = "Cancelling…"
    }

    /// Waits for a running review to finish (used by tests and batch runs).
    func wait(for mrKey: String) async {
        await tasks[mrKey]?.value
    }

    private func perform(_ mr: TrackedMR) async {
        let settings = AccountSettings.current(in: context)
        let prompt = activePrompt.snapshot
        let model = dependencies.reviewModel()
        let run = AIReviewRun(mr: mr, prompt: prompt, modelIdentifier: model.identifier)
        context.insert(run)
        activeRuns[mr.key] = run
        defer { activeRuns[mr.key] = nil }
        save()

        let diff: MRDiff
        do {
            diff = try await diffs.diff(for: mr)
        } catch {
            finish(run, status: .failed, error: "Couldn't load the diff: \(error.localizedDescription)")
            return
        }
        await staticChecks.evaluate(mr)
        let report = staticChecks.report(for: mr)
        let skills = enabledSkills()

        var job = ReviewJob(
            files: diff.files,
            context: storyContext(for: mr),
            flagsByPath: Dictionary(grouping: report.results.flatMap(\.findings), by: \.path),
            staticSummary: Self.summary(of: report),
            skills: skills,
            prompt: prompt,
            options: ReviewOptions(greedy: settings.aiGreedySampling, temperature: settings.aiTemperature,
                                   toolsEnabled: settings.aiToolsEnabled),
            concurrency: max(1, settings.aiConcurrencyLimit)
        )
        if settings.aiToolsEnabled, let client = try? dependencies.gitLabClient(settings: settings) {
            let cache = FileContentCache(client: client, projectID: mr.projectID, ref: mr.headSHA)
            job.makeTools = { ReviewTools.make { path in try await cache.content(of: path) } }
        }
        run.toolsEnabled = settings.aiToolsEnabled
        run.usedAcceptanceCriteria = job.context.hasAcceptanceCriteria
        run.storyKey = job.context.jiraSummary == nil ? nil : mr.jiraKey
        run.storyNote = job.context.storyUnavailableReason

        let key = mr.key
        let engine = ReviewEngine(model: model)
        let outcome = await engine.run(job) { [weak self] event in
            await self?.handle(event, mrKey: key)
        }

        Self.applyVerdict(of: outcome, to: run)

        if outcome.wasCancelled {
            finish(run, status: .cancelled, error: "Cancelled")
        } else {
            finish(run, status: .completed, error: nil)
            if let verdict = outcome.verdict {
                mr.aiVerdictRaw = verdict.status.rawValue
                mr.aiReviewedSHA = run.headSHA
                mr.aiReviewedAt = .now
                updateOpenConcerns(for: mr)
            }
        }
        Log.ai.info("AI review finished: \(outcome.files.count, privacy: .public) files, verdict \(outcome.verdict?.status.rawValue ?? "none", privacy: .public)")
    }

    private func handle(_ event: ReviewEvent, mrKey: String) {
        let progress = progress[mrKey]
        guard let run = activeRuns[mrKey] else { return }
        switch event {
        case .planned(let paths):
            progress?.plan(paths)
        case .fileStarted(let path):
            progress?.set(path, .running)
        case .fileFinished(let output):
            Self.store(output, in: run, context: context)
            save()
            switch output.outcome {
            case .reviewed(let result): progress?.set(output.path, .reviewed(concerns: result.concerns.count))
            case .skipped(let reason): progress?.set(output.path, .skipped(reason))
            case .failed(let failure): progress?.set(output.path, .failed(failure.title))
            }
        case .mergeStarted:
            progress?.isMerging = true
        }
    }

    private func finish(_ run: AIReviewRun, status: RunStatus, error: String?) {
        run.status = status
        run.errorMessage = error
        run.finishedAt = .now
        save()
        revision += 1
    }

    /// Shared by live reviews and eval batches.
    static func store(_ output: FileReviewOutput, in run: AIReviewRun, context: ModelContext) {
        let record = makeRecord(output)
        record.run = run
        context.insert(record)
        run.totalInputTokens += record.inputTokens
        run.totalOutputTokens += record.outputTokens
    }

    static func applyVerdict(of outcome: ReviewOutcome, to run: AIReviewRun) {
        run.skillsUsed = Array(Set(outcome.files.flatMap(\.skills).map(\.label))).sorted()
        if let verdict = outcome.verdict {
            run.verdictStatusRaw = verdict.status.rawValue
            run.criteriaCoverage = verdict.criteriaCoverage
            run.topConcerns = verdict.topConcerns
            run.rationale = verdict.rationale
        }
        run.verdictFailure = outcome.verdictFailure?.message
        if let call = outcome.verdictCall {
            run.mergeCallData = try? JSONEncoder().encode(call)
            run.totalInputTokens += call.inputTokens ?? 0
            run.totalOutputTokens += call.outputTokens ?? 0
        }
    }

    static func makeRecord(_ output: FileReviewOutput) -> FileReviewRecord {
        let status: FileReviewStatus = switch output.outcome {
        case .reviewed: .reviewed
        case .skipped: .skipped
        case .failed: .failed
        }
        let record = FileReviewRecord(order: output.index, path: output.path, status: status)
        switch output.outcome {
        case .reviewed(let result):
            record.summary = result.summary
            record.meetsCriteriaRaw = result.meetsCriteria.rawValue
            record.confidenceRaw = result.confidence.rawValue
            record.concerns = result.concerns.enumerated().map { ConcernRecord(order: $0, concern: $1) }
        case .skipped(let reason):
            record.skipReason = reason
        case .failed(let failure):
            record.failureRaw = try? JSONEncoder().encode(failure)
        }
        record.partCount = output.partCount
        record.skillsUsed = output.skills.map(\.label)
        record.staticFlags = output.flags.map { "line \($0.line): \($0.kind.label) (\($0.rule))" }
        record.callsData = try? JSONEncoder().encode(output.calls)
        record.inputTokens = output.calls.compactMap(\.inputTokens).reduce(0, +)
        record.outputTokens = output.calls.compactMap(\.outputTokens).reduce(0, +)
        record.latency = output.calls.map(\.latency).reduce(0, +)
        return record
    }

    static func summary(of report: CheckReport) -> String {
        let failing = report.results.filter { $0.outcome == .fail }.map(\.title)
        let warnings = report.results.filter { $0.outcome == .warning }.map(\.title)
        var parts: [String] = []
        if !failing.isEmpty { parts.append("failing: " + failing.joined(separator: "; ")) }
        if !warnings.isEmpty { parts.append("warnings: " + warnings.joined(separator: "; ")) }
        return parts.isEmpty ? "all passing" : parts.joined(separator: ". ")
    }

    /// The MR plus its Jira story (summary, description, acceptance criteria) when available.
    func storyContext(for mr: TrackedMR) -> ReviewContext {
        var context = ReviewContext(mrTitle: mr.title, mrDescription: mr.descriptionText, jiraKey: mr.jiraKey)
        if let details = jira.details(for: mr.jiraKey), mr.jiraLookup == .found || mr.jiraLookup == .failed {
            context.jiraSummary = details.summary
            context.storyDescription = details.description
            context.acceptanceCriteria = details.acceptanceCriteria
        } else if mr.jiraKey == nil {
            context.storyUnavailableReason = "no Jira key in the branch name"
        } else if mr.jiraLookup == .notFound {
            context.storyUnavailableReason = "the Jira issue wasn't found"
        } else {
            context.storyUnavailableReason = "Jira is not connected"
        }
        return context
    }

    func enabledSkills() -> [SkillSnapshot] {
        let skills = (try? context.fetch(FetchDescriptor<ReviewSkill>(predicate: #Predicate { $0.isEnabled }, sortBy: [SortDescriptor(\.name)]))) ?? []
        return skills.map(\.snapshot)
    }

    private func save() {
        do { try context.save() } catch {
            Log.persistence.error("Saving AI review failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Setup

    private func seedDefaults() {
        let settings = AccountSettings.current(in: context)
        if ((try? context.fetchCount(FetchDescriptor<PromptVersion>())) ?? 0) == 0 {
            let v1 = PromptVersion(name: "v1", fileInstructions: PromptVersion.defaultFileInstructions,
                                   mergeInstructions: PromptVersion.defaultMergeInstructions, notes: "Built-in default")
            context.insert(v1)
            settings.activePromptVersionID = v1.id
        }
        if !settings.didSeedDefaultSkills {
            for skill in DefaultSkills.all {
                context.insert(ReviewSkill(name: skill.name, appliesTo: skill.appliesTo, content: skill.content, isBuiltIn: true))
            }
            settings.didSeedDefaultSkills = true
        } else {
            DefaultSkills.upgrade((try? context.fetch(FetchDescriptor<ReviewSkill>())) ?? [])
        }
        save()
    }

    /// Runs left "running" by a quit or crash are marked cancelled on launch.
    private func markInterruptedRuns() {
        let running = RunStatus.running.rawValue
        let stale = (try? context.fetch(FetchDescriptor<AIReviewRun>(predicate: #Predicate { $0.statusRaw == running }))) ?? []
        for run in stale {
            run.status = .cancelled
            run.errorMessage = "Interrupted (the app quit during the review)"
        }
        if !stale.isEmpty { save() }
    }
}

/// Fetches each file once per review for the file-reading tool.
actor FileContentCache {
    private let client: any GitLabAPI
    private let projectID: Int
    private let ref: String
    private var cache: [String: String] = [:]

    init(client: any GitLabAPI, projectID: Int, ref: String) {
        self.client = client
        self.projectID = projectID
        self.ref = ref
    }

    func content(of path: String) async throws -> String {
        if let cached = cache[path] { return cached }
        let content = try await client.fileContent(projectID: projectID, path: path, ref: ref)
        cache[path] = content
        return content
    }
}
