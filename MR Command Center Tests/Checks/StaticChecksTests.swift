import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

struct MetadataChecksTests {
    private var base: MRCheckInput {
        MRCheckInput(headSHA: "abc12345", hasLoadedDetails: true, pipelineStatus: .success, pipelineSHA: "abc12345",
                     approvalsGiven: 2, approvalsRequired: 2, hasConflicts: false, isDraft: false,
                     unresolvedDiscussions: 0, jiraKey: "PAY-1")
    }

    @Test func healthyMRPassesEverythingButJiraPending() {
        let outcomes = Dictionary(uniqueKeysWithValues: StaticChecks.metadataChecks(base).map { ($0.id, $0.outcome) })
        #expect(outcomes == [.pipeline: .pass, .jira: .pending, .priority: .pending, .approvals: .pass, .conflicts: .pass, .draft: .pass, .discussions: .pass])
    }

    @Test(arguments: [
        (PipelineStatus.success, "abc12345", CheckOutcome.pass),
        (.success, "old00000", .warning),
        (.failed, "abc12345", .fail),
        (.running, "abc12345", .pending),
        (.pending, "abc12345", .pending),
        (.manual, "abc12345", .warning),
        (.canceled, "abc12345", .warning),
    ])
    func pipelineOutcomes(status: PipelineStatus, sha: String, expected: CheckOutcome) {
        var input = base
        input.pipelineStatus = status
        input.pipelineSHA = sha
        #expect(StaticChecks.pipeline(input).outcome == expected)
    }

    @Test func missingPipelineAndUnloadedDetails() {
        var input = base
        input.pipelineStatus = nil
        #expect(StaticChecks.pipeline(input).outcome == .warning)
        input.hasLoadedDetails = false
        #expect(StaticChecks.pipeline(input).outcome == .pending)
        #expect(StaticChecks.approvals(input).outcome == .pending)
    }

    @Test func approvalsConflictsDraftThreadsAndJira() {
        var input = base
        input.approvalsGiven = 1
        #expect(StaticChecks.approvals(input).outcome == .warning)
        #expect(StaticChecks.approvals(input).detail.contains("needs 1 more"))
        input.approvalsRequired = 0
        #expect(StaticChecks.approvals(input).outcome == .pass)
        input.hasConflicts = true
        #expect(StaticChecks.conflicts(input).outcome == .fail)
        input.isDraft = true
        #expect(StaticChecks.draft(input).outcome == .warning)
        input.unresolvedDiscussions = 3
        #expect(StaticChecks.discussions(input).detail == "3 unresolved threads.")
        input.jiraKey = nil
        #expect(StaticChecks.jira(input).outcome == .warning)
    }
}

struct DiffChecksTests {
    private func diff(_ iid: Int) -> MRDiff {
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == iid }!
        return MRDiff(headSHA: entry.detail.sha!, diffs: entry.diffs, changesCount: entry.detail.changesCount, fetchedAt: .now)
    }

    private func outcomes(_ iid: Int, _ configuration: CheckConfiguration = .default) -> [CheckID: CheckResult] {
        Dictionary(uniqueKeysWithValues: StaticChecks.diffChecks(diff(iid), configuration: configuration).map { ($0.id, $0) })
    }

    @Test func webhookRetriesFlagsPrintAndTodoButHasTests() {
        let results = outcomes(412)
        #expect(results[.tests]?.outcome == .pass)
        #expect(results[.secrets]?.outcome == .pass)
        #expect(results[.debugOutput]?.findings.map(\.line) == [42])
        #expect(results[.todos]?.findings.map(\.rule) == ["TODO"])
        #expect(results[.diffSize]?.outcome == .pass, "poetry.lock is generated and not counted")
    }

    @Test func savedCartsHasNoTestsAndConsoleLog() {
        let results = outcomes(1873)
        #expect(results[.tests]?.outcome == .warning)
        #expect(results[.debugOutput]?.findings.first?.rule == "console.log")
    }

    @Test func vaultRotationLeaksAnAWSKey() throws {
        let results = outcomes(80)
        let secrets = try #require(results[.secrets])
        #expect(secrets.outcome == .fail)
        #expect(secrets.findings.first?.path == "deploy/staging/db.tf")
        #expect(results[.tests]?.outcome == .notApplicable, "Terraform isn't treated as source")
    }

    @Test func refundIdempotencyFlagsFixme() {
        #expect(outcomes(420)[.todos]?.findings.map(\.rule) == ["FIXME"])
    }

    @Test func diffSizeLimitAndOverflow() {
        var configuration = CheckConfiguration.default
        configuration.diffSizeLimit = 100
        #expect(outcomes(415, configuration)[.diffSize]?.outcome == .warning)
        #expect(outcomes(1884)[.diffSize]?.outcome == .warning, "GitLab overflow is always over the limit")
    }

    @Test func fingerprintChangesWithConfiguration() {
        var configuration = CheckConfiguration.default
        let original = configuration.fingerprint
        configuration.debugPatterns.append("puts")
        #expect(configuration.fingerprint != original)
    }
}

struct StaticCheckServiceTests {
    @Test func refreshAnalyzesEveryMROncePerSHA() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.refresh(.automatic)

        #expect(spy.count("diffs") == 11)
        let vault = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 80 })
        let report = model.staticChecks.report(for: vault)
        #expect(report.diffChecksAvailable)
        #expect(report.result(.secrets)?.outcome == .fail)
        #expect(vault.diffCheckSHA == vault.headSHA)
        #expect(MRStatusLine.checksItem(for: vault).tone == .negative)

        await model.refresh(.automatic)
        #expect(spy.count("diffs") == 11, "Unchanged SHAs aren't re-analyzed")
    }

    @Test func newHeadSHAIsReanalyzed() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first)

        mr.headSHA = String(repeating: "e", count: 40)
        #expect(!model.staticChecks.report(for: mr).diffChecksAvailable)
        #expect(MRStatusLine.checksItem(for: mr).title == "Checking" || MRStatusLine.checksItem(for: mr).tone == .negative)
        await model.staticChecks.evaluate(mr)
        #expect(model.staticChecks.report(for: mr).diffChecksAvailable)
        #expect(spy.count("diffs") == 12)
    }

    @Test func changingCheckSettingsInvalidatesTheCache() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        #expect(model.staticChecks.report(for: mr).result(.debugOutput)?.outcome == .warning)

        AccountSettings.current(in: model.modelContainer.mainContext).debugPatterns = ["puts"]
        #expect(!model.staticChecks.report(for: mr).diffChecksAvailable)
        await model.staticChecks.evaluate(mr)
        #expect(model.staticChecks.report(for: mr).result(.debugOutput)?.outcome == .pass)
        #expect(spy.count("diffs") == 11, "The diff itself is still cached per SHA")
    }

    @Test func diffFailureLeavesChecksPendingWithReason() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first)
        spy.edit { $0.data.entries.removeAll { $0.detail.key == mr.key } }

        await model.staticChecks.evaluate(mr)
        let report = model.staticChecks.report(for: mr)
        #expect(!report.diffChecksAvailable)
        #expect(report.result(.tests)?.detail.contains("Couldn't analyze") == true)
    }

    @Test func reportExposesFindingsPerFileForTheAIReview() async throws {
        let model = AppModel.testing()
        await model.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let findings = model.staticChecks.report(for: mr).findings(forPath: "app/webhooks/delivery.py")
        #expect(Set(findings.map(\.kind)) == [.debugOutput, .todo])
    }
}
