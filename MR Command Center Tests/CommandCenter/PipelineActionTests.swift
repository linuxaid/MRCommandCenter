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
        #expect(CommandCenter.pipelineAction(status: .success, isForHead: true) == .run)
        #expect(CommandCenter.pipelineAction(status: .manual, isForHead: true) == .run)
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

    @Test func fallsBackToABranchPipelineWhenTheProjectHasNoMRPipelines() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeRequestPipelineFailure = .server(status: 400) }
        let passed = try mr(app, 412)

        await app.commandCenter.startPipeline(passed)

        #expect(spy.count("createPipeline") == 1)
        #expect(spy.state.withLock { $0.pipelineRefs } == [passed.sourceBranch])
        #expect(passed.pipelineStatus == .running)
        #expect(app.commandCenter.pipelineErrors[passed.key] == nil)
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
    }

    @Test func otherErrorsDontFallBack() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeRequestPipelineFailure = .forbidden }
        let passed = try mr(app, 412)

        await app.commandCenter.startPipeline(passed)

        #expect(spy.count("createPipeline") == 0)
        #expect(app.commandCenter.pipelineErrors[passed.key] != nil)
    }

    @Test func startingIsRecordedInActivity() async throws {
        let (app, _) = await loaded()
        let failed = try mr(app, 1873)

        await app.commandCenter.startPipeline(failed)

        let events = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
        let messages = events.filter { $0.mrKey == failed.key }.map(\.message)
        #expect(messages.contains("You retried the pipeline"))
    }
}
