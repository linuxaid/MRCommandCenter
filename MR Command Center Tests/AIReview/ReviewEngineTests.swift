import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

struct ReviewEngineTests {
    private func job(_ iid: Int, concurrency: Int = 1) -> ReviewJob {
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == iid }!
        return ReviewJob(
            files: entry.diffs.enumerated().map { DiffFile($1, index: $0) },
            context: ReviewContext(mrTitle: entry.detail.title, mrDescription: ""),
            flagsByPath: [:], staticSummary: "all passing", skills: [],
            prompt: PromptSnapshot(id: UUID(), name: "v1", fileInstructions: "File.", mergeInstructions: "Merge."),
            options: ReviewOptions(), concurrency: concurrency
        )
    }

    @Test func skipsFilesThatCantBeReviewed() async {
        let model = FakeReviewModel()
        let outcome = await ReviewEngine(model: model).run(job(1873)) { _ in }
        let outcomes = Dictionary(uniqueKeysWithValues: outcome.files.map { ($0.path, $0.outcome) })
        #expect(outcomes["public/images/saved-cart-empty.png"] == .skipped("Binary file"))
        #expect(Set(model.fileCalls.map(\.path)) == ["src/cart/savedCarts.ts", "src/checkout/CheckoutPage.tsx", "src/cart/store/cartStore.ts"])
        #expect(outcome.verdict != nil)
    }

    @Test func generatedDeletedAndRenameOnlyFilesAreSkipped() async {
        let outcome = await ReviewEngine(model: FakeReviewModel()).run(job(415)) { _ in }
        let skipped = outcome.files.compactMap { if case .skipped(let reason) = $0.outcome { reason } else { nil } }
        #expect(Set(skipped) == ["Deleted file", "Renamed without changes"])
        let poetry = await ReviewEngine(model: FakeReviewModel()).run(job(412)) { _ in }
        #expect(poetry.files.last?.outcome == .skipped("GitLab didn't include the diff"))
    }

    @Test func oneFileFailingDoesNotFailTheReview() async {
        let model = FakeReviewModel()
        model.edit { $0.failures["app/webhooks/backoff.py"] = .guardrailViolation }
        let outcome = await ReviewEngine(model: model).run(job(412)) { _ in }
        #expect(outcome.files.first { $0.path == "app/webhooks/backoff.py" }?.outcome == .failed(.guardrailViolation))
        #expect(outcome.files.filter { if case .reviewed = $0.outcome { true } else { false } }.count == 2)
        #expect(outcome.verdict != nil)
        #expect(model.verdictCalls.first?.prompt.contains("backoff.py: not reviewed (failed: Blocked by safety guardrails)") == true)
    }

    @Test func contextOverflowRetriesWithSmallerParts() async {
        // A small context: the full-budget plan is one part that overflows; the half-budget
        // retry splits the file into parts that fit.
        let model = FakeReviewModel(contextSize: 2400)
        model.edit { $0.overflowAbove["app/webhooks/delivery.py"] = 1500 }
        let outcome = await ReviewEngine(model: model).run(job(412)) { _ in }
        let delivery = outcome.files.first { $0.path == "app/webhooks/delivery.py" }
        guard case .reviewed = delivery?.outcome else {
            Issue.record("Expected a retry to succeed, got \(String(describing: delivery?.outcome))")
            return
        }
        #expect((delivery?.partCount ?? 0) > 1)
    }

    @Test func respectsTheConcurrencyLimit() async {
        let model = FakeReviewModel()
        model.edit { $0.delay = .milliseconds(30) }
        _ = await ReviewEngine(model: model).run(job(412, concurrency: 1)) { _ in }
        #expect(model.maxInFlight == 1)

        let parallel = FakeReviewModel()
        parallel.edit { $0.delay = .milliseconds(30) }
        _ = await ReviewEngine(model: parallel).run(job(412, concurrency: 3)) { _ in }
        #expect(parallel.maxInFlight > 1)
    }

    @Test func cancellationStopsBeforeTheVerdict() async {
        let model = FakeReviewModel()
        model.edit { $0.delay = .milliseconds(200) }
        let task = Task { await ReviewEngine(model: model).run(job(412)) { _ in } }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let outcome = await task.value
        #expect(outcome.wasCancelled)
        #expect(outcome.verdict == nil)
        #expect(model.verdictCalls.isEmpty)
    }

    @Test func noReviewableFilesMeansNoVerdict() async {
        var onlyBinary = job(1873)
        onlyBinary.files = onlyBinary.files.filter { $0.unavailable == .binary }
        let model = FakeReviewModel()
        let outcome = await ReviewEngine(model: model).run(onlyBinary) { _ in }
        #expect(outcome.verdict == nil)
        #expect(outcome.verdictFailure != nil)
        #expect(model.verdictCalls.isEmpty)
    }

    @Test func mapsNonModelErrors() {
        #expect(ReviewFailureMapper.map(ReviewFailure.refusal) == .refusal)
        #expect(ReviewFailureMapper.map(ReviewModelError(failure: .timeout, transcript: "")) == .timeout)
        #expect(ReviewFailureMapper.map(URLError(.badURL)) != .refusal)
    }
}

struct AIReviewServiceTests {
    private func setUp(model: FakeReviewModel = FakeReviewModel(), status: ModelStatus = .available) async -> (AppModel, FakeReviewModel) {
        let app = AppModel.testing(model: model, modelStatus: status)
        await app.refresh(.automatic)
        return (app, model)
    }

    private func review(_ app: AppModel, _ mr: TrackedMR, rerun: Bool = false) async {
        app.aiReview.start(mr, rerun: rerun)
        await app.aiReview.wait(for: mr.key)
    }

    @Test func seedsPromptVersionAndStarterSkills() async throws {
        let (app, _) = await setUp()
        let context = app.modelContainer.mainContext
        #expect(app.aiReview.activePrompt.name == "v1")
        #expect(try context.fetchCount(FetchDescriptor<ReviewSkill>()) == DefaultSkills.all.count)
    }

    @Test func uneditedBuiltInSkillsUpgradeAndEditedOnesStay() throws {
        let old = try #require(DefaultSkills.previousContents["Swift"]?.first)
        let current = try #require(DefaultSkills.all.first { $0.name == "Swift" }).content
        let unedited = ReviewSkill(name: "Swift", appliesTo: ["*.swift"], content: old, isBuiltIn: true)
        let edited = ReviewSkill(name: "Swift", appliesTo: ["*.swift"], content: "- Our own rules.", isBuiltIn: true)

        DefaultSkills.upgrade([unedited, edited])

        #expect(unedited.content == current)
        #expect(unedited.version == 2)
        #expect(edited.content == "- Our own rules.")
        #expect(edited.version == 1)
    }

    @Test func swiftSkillFitsTheSkillBudget() async throws {
        let swift = try #require(DefaultSkills.all.first { $0.name == "Swift" })
        let tokens = try await EstimatingTokenCounter().count(swift.content) + 6
        #expect(tokens <= PromptBuilder.maxSkillTokens)
    }

    @Test func runIsPersistedWithFilesConcernsSkillsAndVerdict() async throws {
        let model = FakeReviewModel()
        model.edit { $0.concernsByPath["app/webhooks/delivery.py"] = [ConcernResult(lineHint: "42", severity: .high, explanation: "Debug print.")] }
        let (app, _) = await setUp(model: model)
        let mr = try #require(app.mergeRequests.mergeRequests.first { $0.iid == 412 })

        await review(app, mr)

        let run = try #require(app.aiReview.latestRun(for: mr.key))
        #expect(run.status == .completed)
        #expect(run.headSHA == mr.headSHA)
        #expect(run.verdictStatus == .likelyProblem)
        #expect(run.skillsUsed == ["Python v1"])
        #expect(!run.usedAcceptanceCriteria)
        #expect(run.orderedFiles.map(\.path) == ["app/webhooks/delivery.py", "app/webhooks/backoff.py", "tests/webhooks/test_delivery.py", "poetry.lock"])
        let delivery = run.orderedFiles[0]
        #expect(delivery.orderedConcerns.first?.lineNumber == 42)
        #expect(delivery.staticFlags.contains { $0.contains("debug output") })
        #expect(!delivery.calls.isEmpty)
        #expect(mr.aiVerdictRaw == VerdictStatus.likelyProblem.rawValue)
        #expect(mr.aiReviewedSHA == mr.headSHA)

        // The prompt for delivery.py carried its static flags and the Python skill.
        let call = try #require(model.fileCalls.first { $0.path == "app/webhooks/delivery.py" })
        #expect(call.prompt.contains("line 42: debug output (print()"))
        #expect(call.instructions.contains("### Python"))
    }

    @Test func doesNotRerunTheSameSHAUnlessAsked() async throws {
        let (app, model) = await setUp()
        let mr = try #require(app.mergeRequests.mergeRequests.first { $0.iid == 1880 })
        await review(app, mr)
        let calls = model.fileCalls.count
        #expect(!app.aiReview.needsReview(mr))

        await review(app, mr)
        #expect(model.fileCalls.count == calls, "Same SHA and prompt: no new run")
        #expect(app.aiReview.runs(for: mr.key).count == 1)

        await review(app, mr, rerun: true)
        #expect(app.aiReview.runs(for: mr.key).count == 2)

        mr.headSHA = String(repeating: "f", count: 40)
        #expect(app.aiReview.needsReview(mr))
        #expect(MRStatusLine.aiItem(for: mr).title.hasSuffix("(outdated)"))
    }

    @Test func aNewPromptVersionNeedsAFreshReview() async throws {
        let (app, _) = await setUp()
        let mr = try #require(app.mergeRequests.mergeRequests.first { $0.iid == 1880 })
        await review(app, mr)
        let context = app.modelContainer.mainContext
        let v2 = PromptVersion(name: "v2", fileInstructions: "Stricter.", mergeInstructions: "Merge.")
        context.insert(v2)
        AccountSettings.current(in: context).activePromptVersionID = v2.id
        #expect(app.aiReview.needsReview(mr))
    }

    @Test func unavailableModelDoesNothing() async throws {
        let (app, model) = await setUp(status: .appleIntelligenceNotEnabled)
        let mr = try #require(app.mergeRequests.mergeRequests.first)
        app.aiReview.start(mr)
        #expect(!app.aiReview.isRunning(mr.key))
        #expect(model.fileCalls.isEmpty)
        #expect(app.aiReview.modelStatus.explanation.contains("System Settings"))
    }

    @Test func disabledSkillsAreNotUsed() async throws {
        let (app, model) = await setUp()
        let context = app.modelContainer.mainContext
        for skill in try context.fetch(FetchDescriptor<ReviewSkill>()) { skill.isEnabled = false }
        let mr = try #require(app.mergeRequests.mergeRequests.first { $0.iid == 412 })
        await review(app, mr)
        #expect(model.fileCalls.allSatisfy { !$0.instructions.contains("###") })
        #expect(app.aiReview.latestRun(for: mr.key)?.skillsUsed.isEmpty == true)
    }

    @Test func interruptedRunsAreMarkedCancelledOnLaunch() async throws {
        let container = try AppModelContainer.make(inMemory: true)
        let context = container.mainContext
        let mr = TrackedMR(from: MockGitLabData.sample.entries[0].listItem)
        context.insert(mr)
        let run = AIReviewRun(mr: mr, prompt: PromptSnapshot(id: UUID(), name: "v1", fileInstructions: "", mergeInstructions: ""), modelIdentifier: "x")
        context.insert(run)
        try context.save()

        _ = AppModel(dependencies: .mock(), modelContainer: container)
        #expect(run.status == .cancelled)
        #expect(run.errorMessage?.contains("Interrupted") == true)
    }

    @Test func cachePolicyForAIReview() {
        #expect(CachePolicy.shouldRunAIReview(lastSuccessfulSHA: nil, headSHA: "a"))
        #expect(!CachePolicy.shouldRunAIReview(lastSuccessfulSHA: "a", headSHA: "a"))
        #expect(CachePolicy.shouldRunAIReview(lastSuccessfulSHA: "a", headSHA: "b"))
    }
}

struct QuoteSafetyTests {
    @Test func modelNeverSeesDoubleQuotes() async {
        let model = FakeReviewModel()
        model.edit {
            $0.concernsByPath["src/components/ProductImage.tsx"] = [
                ConcernResult(lineHint: "12", severity: .low, explanation: "Uses loading='lazy'.")
            ]
        }
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == 1884 }!
        let job = ReviewJob(files: entry.diffs.enumerated().map { DiffFile($1, index: $0) },
                            context: ReviewContext(mrTitle: "Say \"hi\"", mrDescription: ""), flagsByPath: [:],
                            staticSummary: "all passing", skills: [],
                            prompt: PromptSnapshot(id: UUID(), name: "v1", fileInstructions: "Lines marked \"+\" were added.", mergeInstructions: "Merge \"it\"."),
                            options: ReviewOptions(), concurrency: 1)
        let outcome = await ReviewEngine(model: model).run(job) { _ in }

        #expect(model.fileCalls.allSatisfy { !$0.prompt.contains("\"") && !$0.instructions.contains("\"") })
        #expect(model.fileCalls.first?.prompt.contains("loading='lazy'") == true)
        #expect(model.fileCalls.first?.instructions.hasSuffix(QuoteSafety.note) == true)
        #expect(model.verdictCalls.allSatisfy { !$0.prompt.contains("\"") && !$0.instructions.contains("\"") })
        guard case .reviewed(let result) = outcome.files.first?.outcome else {
            Issue.record("Expected a review")
            return
        }
        #expect(result.concerns.first?.explanation == "Uses loading='lazy'.")
    }

    @Test func parseFailuresAreRetriedOnceWithSampling() async {
        let model = FakeReviewModel()
        model.edit { $0.parseFailureOnGreedy = ["src/components/ProductImage.tsx"] }
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == 1884 }!
        let job = ReviewJob(files: [DiffFile(entry.diffs[0], index: 0)], context: ReviewContext(mrTitle: "x", mrDescription: ""),
                            flagsByPath: [:], staticSummary: "", skills: [],
                            prompt: PromptSnapshot(id: UUID(), name: "v1", fileInstructions: "F", mergeInstructions: "M"),
                            options: ReviewOptions(), concurrency: 1)
        let outcome = await ReviewEngine(model: model).run(job) { _ in }
        guard case .reviewed = outcome.files.first?.outcome else {
            Issue.record("Expected the retry to succeed, got \(String(describing: outcome.files.first?.outcome))")
            return
        }
        #expect(model.fileCalls.count == 2)
        #expect(outcome.files.first?.calls.count == 2, "The failed attempt is kept for the inspector")
    }
}
