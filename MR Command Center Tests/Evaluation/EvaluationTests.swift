import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

struct EvalMetricsTests {
    let a = UUID(), b = UUID(), c = UUID()

    private func run(_ id: UUID, _ verdict: VerdictStatus?, _ concerns: [EvalRunFacts.Concern] = [], latency: Double = 10,
                     tokens: Int = 1000, failedFiles: Int = 0) -> EvalRunFacts {
        EvalRunFacts(caseID: id, verdict: verdict, concerns: concerns, latency: latency, tokens: tokens, failedFiles: failedFiles, runFailed: false)
    }

    @Test func computesAgreementRecallRatingsAndAverages() throws {
        let cases = [
            EvalCaseFacts(id: a, expectedVerdict: .likelyProblem, expectedConcerns: [
                ExpectedConcern(path: "x.py", line: 40, description: "429"),
                ExpectedConcern(path: "y.py", line: nil, description: "anything in y"),
            ]),
            EvalCaseFacts(id: b, expectedVerdict: .looksGood, expectedConcerns: []),
            EvalCaseFacts(id: c, expectedVerdict: .needsHumanReview, expectedConcerns: [ExpectedConcern(path: "z.py", line: 10, description: "")]),
        ]
        let runs = [
            run(a, .likelyProblem, [
                .init(path: "x.py", line: 42, feedback: .helpful),   // within 3 lines of 40
                .init(path: "y.py", line: 7, feedback: .none),        // any line in y.py
                .init(path: "x.py", line: 90, feedback: .wrong),
            ], latency: 20, tokens: 3000),
            run(b, .needsHumanReview, [.init(path: "q.py", line: 1, feedback: .wrong)], latency: 10, tokens: 1000, failedFiles: 1),
            run(c, nil, [.init(path: "z.py", line: 20, feedback: .none)], latency: 30, tokens: 2000),
        ]
        let metrics = EvalMetrics.compute(cases: cases, runs: runs)

        #expect(metrics.cases == 3)
        #expect(metrics.runsWithVerdict == 2)
        #expect(metrics.verdictMatches == 1)
        #expect(metrics.verdictAgreement == 0.5)
        #expect(metrics.expectedConcerns == 3)
        #expect(metrics.expectedFound == 2, "z.py:20 is more than 3 lines from 10")
        #expect(metrics.helpful == 1 && metrics.wrong == 2 && metrics.unrated == 2)
        #expect(try #require(metrics.precision) == 1.0 / 3.0)
        #expect(metrics.averageLatency == 20)
        #expect(metrics.averageTokens == 2000)
        #expect(metrics.errors == 1)
    }

    @Test func missingRunsAndEmptySetsDontDivideByZero() {
        let metrics = EvalMetrics.compute(cases: [EvalCaseFacts(id: a, expectedVerdict: .looksGood, expectedConcerns: [])], runs: [])
        #expect(metrics.verdictAgreement == nil)
        #expect(metrics.expectedRecall == nil)
        #expect(metrics.averageLatency == nil)
    }
}

struct EvalServiceTests {
    private func setUp(model: FakeReviewModel = FakeReviewModel()) async -> (AppModel, SpyGitLabClient, FakeReviewModel) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy, model: model)
        await app.refresh(.automatic)
        return (app, spy, model)
    }

    @Test func savingACaseSnapshotsTheDiffAndFlagsAndUpdatesInPlace() async throws {
        let (app, _, _) = await setUp()
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })

        let evalCase = try await app.evaluation.saveCase(for: mr, expectedVerdict: .likelyProblem,
            expectedConcerns: [ExpectedConcern(path: "app/webhooks/delivery.py", line: 40, description: "429s")], notes: "Good test")
        #expect(evalCase.headSHA == mr.headSHA)
        #expect(evalCase.diffs.count == 4)
        #expect(evalCase.findings.contains { $0.kind == .debugOutput })
        #expect(evalCase.staticSummary.contains("warnings"))

        let again = try await app.evaluation.saveCase(for: mr, expectedVerdict: .needsHumanReview, expectedConcerns: [], notes: "")
        #expect(again.id == evalCase.id)
        #expect(app.evaluation.cases.count == 1)
        #expect(again.expectedVerdict == .needsHumanReview)
    }

    @Test func batchesReplaySnapshotsWithTheChosenPromptAndStayOutOfLiveHistory() async throws {
        let model = FakeReviewModel()
        model.edit { $0.concernsByPath["app/webhooks/delivery.py"] = [ConcernResult(lineHint: "41", severity: .high, explanation: "429s")] }
        let (app, spy, _) = await setUp(model: model)
        let context = app.modelContainer.mainContext
        let mr412 = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let mr1880 = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1880 })
        try await app.evaluation.saveCase(for: mr412, expectedVerdict: .likelyProblem,
                                          expectedConcerns: [ExpectedConcern(path: "app/webhooks/delivery.py", line: 40, description: "429s")], notes: "")
        try await app.evaluation.saveCase(for: mr1880, expectedVerdict: .looksGood, expectedConcerns: [], notes: "")

        // The MRs vanish from GitLab (merged): batches must not need the network.
        spy.edit { $0.data.entries.removeAll() }
        let diffCallsBefore = spy.count("diffs")

        let v2 = PromptVersion(name: "v2", fileInstructions: "V2 FILE INSTRUCTIONS", mergeInstructions: "V2 MERGE")
        context.insert(v2)
        app.evaluation.runBatch(prompt: v2, cases: app.evaluation.cases)
        await app.evaluation.waitForBatch()

        #expect(spy.count("diffs") == diffCallsBefore)
        #expect(model.fileCalls.allSatisfy { $0.instructions.hasPrefix("V2 FILE INSTRUCTIONS") })
        let batch = try #require(app.evaluation.batches.first)
        #expect(batch.status == .completed)
        #expect(batch.promptVersionName == "v2")
        let runs = app.evaluation.runs(in: batch)
        #expect(runs.count == 2)
        #expect(runs.allSatisfy { $0.evalBatchID == batch.id && $0.evalCaseID != nil })
        #expect(app.aiReview.runs(for: mr412.key).isEmpty, "Eval runs don't show up as the MR's reviews")

        let metrics = app.evaluation.metrics(for: batch)
        #expect(metrics.cases == 2)
        #expect(metrics.verdictMatches == 2)
        #expect(metrics.expectedFound == 1)

        // Rating a batch concern shows up in the metrics.
        let concern = try #require(runs.flatMap(\.files).flatMap(\.concerns).first)
        concern.feedback = .helpful
        #expect(app.evaluation.metrics(for: batch).helpful == 1)
    }

    @Test func batchNeedsTheModel() async throws {
        let app = AppModel.testing(modelStatus: .modelNotReady)
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first)
        try await app.evaluation.saveCase(for: mr, expectedVerdict: .looksGood, expectedConcerns: [], notes: "")
        app.evaluation.runBatch(prompt: app.aiReview.activePrompt, cases: app.evaluation.cases)
        #expect(!app.evaluation.isRunning)
        #expect(app.evaluation.batches.isEmpty)
    }

    @Test func cancellingABatchStopsAndMarksIt() async throws {
        let model = FakeReviewModel()
        model.edit { $0.delay = .milliseconds(120) }
        let (app, _, _) = await setUp(model: model)
        for iid in [412, 1880, 420] {
            let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
            try await app.evaluation.saveCase(for: mr, expectedVerdict: .looksGood, expectedConcerns: [], notes: "")
        }
        app.evaluation.runBatch(prompt: app.aiReview.activePrompt, cases: app.evaluation.cases)
        try await Task.sleep(for: .milliseconds(80))
        app.evaluation.cancelBatch()
        await app.evaluation.waitForBatch()
        let batch = try #require(app.evaluation.batches.first)
        #expect(batch.status == .cancelled)
        #expect(app.evaluation.runs(in: batch).count < 3)
    }
}

struct ExportTests {
    @Test func exportsRunsFeedbackAndCasesAndCanLeaveCodeOut() async throws {
        let model = FakeReviewModel()
        model.edit { $0.concernsByPath["app/webhooks/delivery.py"] = [ConcernResult(lineHint: "42", severity: .low, explanation: "print")] }
        let app = AppModel.testing(model: model)
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        app.aiReview.start(mr)
        await app.aiReview.wait(for: mr.key)
        let run = try #require(app.aiReview.latestRun(for: mr.key))
        run.verdictFeedback = .wrong
        run.verdictNote = "Too harsh"
        run.orderedFiles[0].orderedConcerns[0].feedback = .helpful
        try await app.evaluation.saveCase(for: mr, expectedVerdict: .needsHumanReview, expectedConcerns: [], notes: "")
        let context = app.modelContainer.mainContext

        let lean = ExportService.makeBundle(context: context, evaluation: app.evaluation, includeContent: false)
        let decoded = try JSONDecoder.iso8601.decode(ExportBundle.self, from: ExportService.encode(lean))
        #expect(decoded.schemaVersion == 1)
        #expect(!decoded.includesContent)
        let exported = try #require(decoded.runs.first { $0.id == run.id })
        #expect(exported.verdictFeedback == "wrong")
        #expect(exported.verdictNote == "Too harsh")
        #expect(exported.files[0].concerns[0].feedback == "helpful")
        #expect(exported.files.allSatisfy { $0.calls == nil })
        #expect(exported.mergeCall == nil)
        #expect(decoded.evalCases.first?.diffs == nil)
        #expect(decoded.promptVersions.map(\.name) == ["v1"])
        #expect(decoded.skills.contains { $0.name == "Python" })

        let full = ExportService.makeBundle(context: context, evaluation: app.evaluation, includeContent: true)
        #expect(full.runs.first { $0.id == run.id }?.files[0].calls?.isEmpty == false)
        #expect(full.evalCases.first?.diffs?.count == 4)
    }
}

extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
