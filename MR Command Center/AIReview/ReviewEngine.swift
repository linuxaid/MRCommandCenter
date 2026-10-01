import Foundation

/// Everything one review needs, captured as values so the engine can run off the main actor.
nonisolated struct ReviewJob: Sendable {
    var files: [DiffFile]
    var context: ReviewContext
    var flagsByPath: [String: [PatternFinding]]
    var staticSummary: String
    var skills: [SkillSnapshot]
    var prompt: PromptSnapshot
    var options: ReviewOptions
    var concurrency: Int
    /// Builds a fresh tool set per file (when tools are enabled).
    var makeTools: (@Sendable () -> ReviewTools)?
}

nonisolated enum FileOutcome: Sendable, Equatable {
    case reviewed(FileReviewResult)
    case skipped(String)
    case failed(ReviewFailure)
}

nonisolated struct FileReviewOutput: Sendable, Equatable {
    var index: Int
    var path: String
    var outcome: FileOutcome
    var calls: [ModelCallRecord]
    var partCount: Int
    var skills: [SkillSnapshot]
    var flags: [PatternFinding]
}

nonisolated enum ReviewEvent: Sendable {
    case planned([String])
    case fileStarted(String)
    case fileFinished(FileReviewOutput)
    case mergeStarted
}

nonisolated struct ReviewOutcome: Sendable {
    var files: [FileReviewOutput]
    var verdict: VerdictResult?
    var verdictCall: ModelCallRecord?
    var verdictFailure: ReviewFailure?
    var wasCancelled: Bool
}

/// Runs a review: one session per file (or per part of a large file), then a merge session.
nonisolated struct ReviewEngine {
    let model: any ReviewLanguageModel

    /// Why a file isn't sent to the model, or nil if it should be.
    static func skipReason(for file: DiffFile) -> String? {
        switch file.unavailable {
        case .binary: return "Binary file"
        case .tooLarge, .collapsed: return "GitLab didn't include the diff"
        case .renamedWithoutChanges: return "Renamed without changes"
        case .empty: return "No line changes"
        case nil: break
        }
        if file.isGenerated { return "Generated file" }
        if file.change == .deleted { return "Deleted file" }
        if file.additions == 0 && file.deletions == 0 { return "No line changes" }
        return nil
    }

    func run(_ job: ReviewJob, onEvent: @escaping @Sendable (ReviewEvent) async -> Void) async -> ReviewOutcome {
        await onEvent(.planned(job.files.map(\.path)))
        let indexed = Array(job.files.enumerated())
        var outputs: [FileReviewOutput] = []

        await withTaskGroup(of: FileReviewOutput.self) { group in
            var pending = indexed.makeIterator()
            func addNext() {
                guard let (index, file) = pending.next() else { return }
                group.addTask {
                    await onEvent(.fileStarted(file.path))
                    return await review(file, index: index, job: job)
                }
            }
            for _ in 0..<max(1, job.concurrency) { addNext() }
            while let output = await group.next() {
                outputs.append(output)
                await onEvent(.fileFinished(output))
                if !Task.isCancelled { addNext() }
            }
        }
        outputs.sort { $0.index < $1.index }

        if Task.isCancelled {
            return ReviewOutcome(files: outputs, verdict: nil, verdictCall: nil, verdictFailure: nil, wasCancelled: true)
        }
        guard outputs.contains(where: { if case .reviewed = $0.outcome { true } else { false } }) else {
            return ReviewOutcome(files: outputs, verdict: nil, verdictCall: nil,
                                 verdictFailure: .other("No files could be reviewed, so there's no verdict."), wasCancelled: false)
        }

        await onEvent(.mergeStarted)
        do {
            let summaries = outputs.map { output -> PromptBuilder.FileSummary in
                switch output.outcome {
                case .reviewed(let result): PromptBuilder.FileSummary(path: output.path, result: result)
                case .skipped(let reason): PromptBuilder.FileSummary(path: output.path, problem: "skipped: \(reason)")
                case .failed(let failure): PromptBuilder.FileSummary(path: output.path, problem: "failed: \(failure.title)")
                }
            }
            let counter = model.tokenCounter
            let budget = model.contextSize - 900 - (try await counter.count(job.prompt.mergeInstructions)) - (try await counter.verdictSchemaTokens())
            let prompt = try await PromptBuilder.mergePrompt(context: job.context, files: summaries, staticSummary: job.staticSummary,
                                                             budgetTokens: budget, counter: counter)
            let (verdict, call) = try await model.verdict(instructions: QuoteSafety.encode(job.prompt.mergeInstructions),
                                                          prompt: QuoteSafety.encode(prompt), options: job.options)
            return ReviewOutcome(files: outputs, verdict: verdict, verdictCall: call, verdictFailure: nil, wasCancelled: false)
        } catch {
            return ReviewOutcome(files: outputs, verdict: nil, verdictCall: nil,
                                 verdictFailure: ReviewFailureMapper.map(error), wasCancelled: Task.isCancelled)
        }
    }

    /// One model call, retried once with sampling if the structured output couldn't be parsed.
    private func reviewPart(_ part: String, instructions: String, job: ReviewJob,
                            calls: inout [ModelCallRecord]) async throws -> (FileReviewResult, ModelCallRecord) {
        let instructions = QuoteSafety.encodeInstructions(instructions)
        let prompt = QuoteSafety.encode(part)
        do {
            return try await model.reviewFile(instructions: instructions, prompt: prompt, options: job.options,
                                              tools: job.options.toolsEnabled ? job.makeTools?() : nil)
        } catch let error as ReviewModelError where error.failure == .decodingFailure {
            calls.append(ModelCallRecord(instructions: instructions, prompt: prompt,
                                         transcript: "Retried after a parse failure.\n\n" + error.transcript, rawOutput: "", latency: 0))
            var retry = job.options
            retry.greedy = false
            return try await model.reviewFile(instructions: instructions, prompt: prompt, options: retry,
                                              tools: job.options.toolsEnabled ? job.makeTools?() : nil)
        }
    }

    private func review(_ file: DiffFile, index: Int, job: ReviewJob) async -> FileReviewOutput {
        let flags = job.flagsByPath[file.path] ?? []
        if let reason = Self.skipReason(for: file) {
            return FileReviewOutput(index: index, path: file.path, outcome: .skipped(reason), calls: [], partCount: 0, skills: [], flags: flags)
        }

        var calls: [ModelCallRecord] = []
        var skills: [SkillSnapshot] = []
        var partCount = 0
        // On a context overflow, retry once with half the budget (more, smaller parts).
        for budgetScale in [1.0, 0.5] {
            calls = []
            do {
                let tools = job.options.toolsEnabled ? job.makeTools?() : nil
                var budget = PromptBudget(contextSize: model.contextSize)
                budget.toolReserve = tools == nil ? 0 : 1_500
                budget.contextSize = Int(Double(budget.contextSize) * budgetScale)
                let plan = try await PromptBuilder.plan(
                    file: file, context: job.context, flags: flags, skills: job.skills,
                    baseInstructions: job.prompt.fileInstructions, budget: budget, counter: model.tokenCounter
                )
                skills = plan.skills
                partCount = plan.parts.count
                var results: [FileReviewResult] = []
                for part in plan.parts {
                    try Task.checkCancellation()
                    let (result, call) = try await reviewPart(part, instructions: plan.instructions, job: job, calls: &calls)
                    results.append(result)
                    calls.append(call)
                }
                guard let merged = FileReviewResult.merged(results) else { throw ReviewFailure.other("Empty diff") }
                return FileReviewOutput(index: index, path: file.path, outcome: .reviewed(merged), calls: calls,
                                        partCount: partCount, skills: skills, flags: flags)
            } catch let error as ReviewModelError where error.failure == .contextSizeExceeded && budgetScale == 1.0 {
                continue
            } catch is CancellationError {
                return FileReviewOutput(index: index, path: file.path, outcome: .failed(.other("Cancelled")), calls: calls,
                                        partCount: partCount, skills: skills, flags: flags)
            } catch {
                var failedCalls = calls
                if let error = error as? ReviewModelError, !error.transcript.isEmpty {
                    failedCalls.append(ModelCallRecord(instructions: "", prompt: "", transcript: error.transcript, rawOutput: "", latency: 0))
                }
                return FileReviewOutput(index: index, path: file.path, outcome: .failed(ReviewFailureMapper.map(error)), calls: failedCalls,
                                        partCount: partCount, skills: skills, flags: flags)
            }
        }
        return FileReviewOutput(index: index, path: file.path, outcome: .failed(.contextSizeExceeded), calls: calls,
                                partCount: partCount, skills: skills, flags: flags)
    }
}
