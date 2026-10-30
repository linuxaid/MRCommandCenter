import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

/// Running and retrying an MR's pipeline from the brief (#34).
@MainActor
struct PipelineActionTests {
    private func loaded() async -> (AppModel, SpyGitLabClient) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        return (app, spy)
    }

    private func mr(_ app: AppModel, _ iid: Int) throws -> TrackedMR {
        try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
    }

    @Test func whatTheButtonOffers() {
        #expect(CommandCenter.pipelineAction(status: nil, isForHead: true) == .run, "No pipeline yet")
        #expect(CommandCenter.pipelineAction(status: .failed, isForHead: true) == .retry)
        #expect(CommandCenter.pipelineAction(status: .canceled, isForHead: true) == .retry)
        #expect(CommandCenter.pipelineAction(status: .failed, isForHead: false) == .run,
                "Retrying an older commit's pipeline wouldn't test the latest code")
        // #40: no button once the latest commit's pipeline passed.
        #expect(CommandCenter.pipelineAction(status: .success, isForHead: true) == nil)
        #expect(CommandCenter.pipelineAction(status: .manual, isForHead: true) == nil, "Ran, waiting on a manual job")
        #expect(CommandCenter.pipelineAction(status: .success, isForHead: false) == .run,
                "An older commit passed; the latest hasn't run")
        #expect(CommandCenter.pipelineAction(status: .skipped, isForHead: true) == .run, "Skipped means it didn't run")
        #expect(CommandCenter.pipelineAction(status: .unknown, isForHead: true) == .run)
        for status in PipelineStatus.allCases where status.isActive {
            #expect(CommandCenter.pipelineAction(status: status, isForHead: true) == nil, "Nothing while \(status) is going")
        }
    }

    @Test func retryingAFailedPipelineSetsItRunning() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        #expect(app.commandCenter.pipelineAction(for: failed) == .retry)

        await app.commandCenter.startPipeline(failed)

        #expect(spy.count("retryPipeline") == 1)
        #expect(failed.pipelineStatus == .running)
        #expect(app.commandCenter.pipelineAction(for: failed) == nil, "No second start while it runs")
        #expect(app.commandCenter.pipelineErrors[failed.key] == nil)
    }

    @Test func runningStartsAMergeRequestPipeline() async throws {
        let (app, spy) = await loaded()
        let none = try mr(app, 1884)
        #expect(none.pipelineID == nil)

        await app.commandCenter.startPipeline(none)

        #expect(spy.count("createMergeRequestPipeline") == 1)
        #expect(spy.count("createPipeline") == 0)
        #expect(none.pipelineStatus == .running)
        #expect(none.pipelineSHA == none.headSHA)
    }

    @Test(arguments: [400, 422])
    func fallsBackToABranchPipelineWhenTheProjectHasNoMRPipelines(status: Int) async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeRequestPipelineFailure = .server(status: status) }
        let none = try mr(app, 1884)

        await app.commandCenter.startPipeline(none)

        #expect(spy.count("createPipeline") == 1)
        #expect(spy.state.withLock { $0.pipelineRefs } == [none.sourceBranch])
        #expect(none.pipelineStatus == .running)
        #expect(app.commandCenter.pipelineErrors[none.key] == nil)
    }

    @Test func failureIsExplainedAndNothingChanges() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.pipelineFailure = .forbidden }
        let failed = try mr(app, 1873)

        await app.commandCenter.startPipeline(failed)

        #expect(failed.pipelineStatus == .failed)
        let error = try #require(app.commandCenter.pipelineErrors[failed.key])
        #expect(error.contains("api scope"))
        #expect(app.commandCenter.actionErrors[failed.key] == nil, "Kept apart from approve/merge errors")
        #expect(try messages(app, failed).filter { $0.contains("pipeline") }.isEmpty, "Nothing recorded")
    }

    @Test func nothingIsOfferedBeforeTheDetailsLoad() async throws {
        let (app, _) = await loaded()
        let none = try mr(app, 1884)
        none.detailsFetchedForUpdatedAt = nil
        #expect(app.commandCenter.pipelineAction(for: none) == nil, "GitLab may already have one running")
    }

    @Test func aFailedPipelineOfAnOlderCommitStartsANewOne() async throws {
        let (app, spy) = await loaded()
        let failed = try mr(app, 1873)
        failed.pipelineSHA = "0123456789abcdef"
        #expect(app.commandCenter.pipelineAction(for: failed) == .run)

        await app.commandCenter.startPipeline(failed)

        #expect(spy.count("retryPipeline") == 0)
        #expect(spy.count("createMergeRequestPipeline") == 1)
        #expect(failed.pipelineSHA == failed.headSHA)
    }

    @Test func otherErrorsDontFallBack() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeRequestPipelineFailure = .forbidden }
        let none = try mr(app, 1884)

        await app.commandCenter.startPipeline(none)

        #expect(spy.count("createPipeline") == 0)
        #expect(app.commandCenter.pipelineErrors[none.key] != nil)
    }

    @Test func aPassedPipelineHasNoButton() async throws {
        let (app, spy) = await loaded()
        let passed = try mr(app, 412)
        #expect(passed.pipelineStatus == .success)
        #expect(app.commandCenter.pipelineAction(for: passed) == nil)

        await app.commandCenter.startPipeline(passed)
        #expect(spy.count("createMergeRequestPipeline") == 0 && spy.count("retryPipeline") == 0)

        // A push makes the passed pipeline an older commit's: the new commit hasn't run.
        passed.pipelineSHA = "0123456789abcdef"
        #expect(app.commandCenter.pipelineAction(for: passed) == .run)
    }

    @Test func startingIsRecordedInActivity() async throws {
        let (app, _) = await loaded()
        let failed = try mr(app, 1873)

        await app.commandCenter.startPipeline(failed)

        #expect(try messages(app, failed).contains("You retried the pipeline"))
        let none = try mr(app, 1884)
        await app.commandCenter.startPipeline(none)
        #expect(try messages(app, none).contains("You started a pipeline"))
    }

    private func messages(_ app: AppModel, _ mr: TrackedMR) throws -> [String] {
        try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
            .filter { $0.mrKey == mr.key }.map(\.message)
    }
}
