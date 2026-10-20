import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

struct MergeRequestStoreTests {
    @Test func initialRefreshLoadsListAndAllDetails() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests

        let outcome = try #require(await store.refresh(.manual))

        #expect(store.trackedMergeRequests.count == 11, "8 to review plus 3 you opened")
        #expect(outcome.wasInitialLoad)
        #expect(outcome.newMergeRequestKeys.count == 11)
        #expect(outcome.detailFetches == 11)
        #expect(spy.count("currentUser") == 1)
        #expect(spy.count("list") == 1 && spy.count("authoredList") == 1)
        #expect(store.problem == nil)
        #expect(store.lastRefreshedAt != nil)

        let pay142 = try #require(store.trackedMergeRequests.first { $0.iid == 412 })
        #expect(pay142.jiraKey == "PAY-142")
        #expect(pay142.pipelineStatus == .success)
        #expect(pay142.approvalsGiven == 1 && pay142.approvalsRequired == 2)
        #expect(pay142.unresolvedDiscussions == 3)
        #expect(pay142.threadsAwaitingMe == 1, "Priya answered the mock user's thread")
        #expect(pay142.lastReplyFrom == "Priya Natarajan")
        #expect(pay142.isReviewer && !pay142.isAuthor)
        let mine = try #require(store.trackedMergeRequests.first { $0.iid == 233 })
        #expect(mine.isAuthor && !mine.isReviewer)
        #expect(store.trackedMergeRequests.first { $0.iid == 77 }?.jiraKey == nil)
    }

    @Test func secondRefreshSkipsUnchangedMRsButRepollsActivePipelines() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)

        let outcome = try #require(await store.refresh(.automatic))

        #expect(outcome.detailFetches == 0)
        #expect(spy.count("detail") == 11)
        #expect(spy.count("currentUser") == 1, "User ID is cached in settings")
        // Mock data has one running and one pending pipeline.
        #expect(outcome.pipelineFetches == 2)
        #expect(outcome.newMergeRequestKeys.isEmpty)
    }

    @Test func refetchesOnlyTheMRWhoseUpdatedAtChanged() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)

        spy.edit { state in
            var entry = state.data.entries[0]
            entry.detail = GitLabMergeRequest(
                id: entry.detail.id, iid: entry.detail.iid, projectId: entry.detail.projectId,
                title: "Renamed title", description: entry.detail.description, state: "opened",
                createdAt: entry.detail.createdAt, updatedAt: entry.detail.updatedAt.addingTimeInterval(60),
                sourceBranch: entry.detail.sourceBranch, targetBranch: entry.detail.targetBranch,
                author: entry.detail.author, labels: entry.detail.labels, sha: entry.detail.sha,
                references: entry.detail.references, webUrl: entry.detail.webUrl,
                headPipeline: entry.detail.headPipeline
            )
            state.data.entries[0] = entry
        }
        let outcome = try #require(await store.refresh(.automatic))

        #expect(outcome.detailFetches == 1)
        #expect(store.trackedMergeRequests.contains { $0.title == "Renamed title" })
    }

    @Test func reportsPipelineThatTurnedFailed() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)
        let running = try #require(store.trackedMergeRequests.first { $0.pipelineStatus == .running })
        let pipelineID = try #require(running.pipelineID)

        spy.edit { $0.pipelineOverrides[pipelineID] = "failed" }
        let outcome = try #require(await store.refresh(.automatic))

        #expect(outcome.newlyFailedPipelineKeys == [running.key])
        #expect(running.pipelineStatus == .failed)
    }

    @Test func hidesMRsThatLeaveTheReviewerList() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)
        let removedKey = try #require(store.trackedMergeRequests.last?.key)

        spy.edit { $0.data.entries.removeAll { $0.detail.key == removedKey } }
        await store.refresh(.automatic)

        #expect(store.trackedMergeRequests.count == 10)
        #expect(!store.trackedMergeRequests.contains { $0.key == removedKey })
    }

    @Test func keepsCachedDataAndFlagsCredentialsOn401() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)

        spy.edit { $0.listFailure = .unauthorized }
        let outcome = await store.refresh(.manual)

        #expect(outcome == nil)
        #expect(store.trackedMergeRequests.count == 11)
        guard case .credentials = store.problem else {
            Issue.record("Expected credentials problem, got \(String(describing: store.problem))")
            return
        }
    }

    @Test func keepsCachedDataWhenOffline() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)
        let lastRefreshed = store.lastRefreshedAt

        spy.edit { $0.listFailure = .offline }
        await store.refresh(.automatic)

        #expect(store.problem == .offline)
        #expect(store.trackedMergeRequests.count == 11)
        #expect(store.lastRefreshedAt == lastRefreshed)

        spy.edit { $0.listFailure = nil }
        await store.refresh(.manual)
        #expect(store.problem == nil)
    }

    @Test func detailFailureForOneMRDoesNotLoseTheList() async throws {
        let spy = SpyGitLabClient()
        spy.edit { $0.detailFailure = .server(status: 500) }
        let store = AppModel.testing(gitLab: spy).mergeRequests

        await store.refresh(.automatic)

        #expect(store.trackedMergeRequests.count == 11)
        #expect(store.problem == nil)
        #expect(store.trackedMergeRequests.allSatisfy { $0.detailsError != nil && !$0.hasLoadedDetails })
    }

    @Test func recordsWhatChangedBetweenRefreshes() async throws {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        let store = app.mergeRequests
        await store.refresh(.automatic)
        #expect(try app.modelContainer.mainContext.fetchCount(FetchDescriptor<ActivityEvent>()) == 0,
                "The first load isn't news")

        let running = try #require(store.trackedMergeRequests.first { $0.pipelineStatus == .running })
        let pipelineID = try #require(running.pipelineID)
        spy.edit { $0.pipelineOverrides[pipelineID] = "success" }
        await store.refresh(.automatic)

        let events = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
        #expect(events.contains { $0.mrKey == running.key && $0.kind == .pipelinePassed })
        #expect(running.hasUnseenActivity)
        store.markSeen(running)
        #expect(!running.hasUnseenActivity)
    }

    @Test func reportsMergeRequestsThatLeave() async throws {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        let store = app.mergeRequests
        await store.refresh(.automatic)
        let gone = try #require(store.trackedMergeRequests.first { $0.iid == 77 })

        spy.edit { $0.data.entries.removeAll { $0.detail.iid == 77 } }
        await store.refresh(.automatic)

        let events = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
        #expect(events.contains { $0.mrKey == gone.key && $0.kind == .left })
    }

    @Test func notConfiguredWithoutToken() async {
        let store = AppModel.testing(token: nil).mergeRequests
        await store.refresh(.manual)
        #expect(store.problem == .notConfigured)
    }

    @Test func selectionMovesThroughTheList() async {
        let store = AppModel.testing().mergeRequests
        await store.refresh(.automatic)

        let order = store.trackedMergeRequests.map(\.key).reversed().map { $0 }
        store.moveSelection(by: 1, in: order)
        #expect(store.selectedKey == order[0])
        store.moveSelection(by: 1, in: order)
        #expect(store.selectedKey == order[1])
        store.moveSelection(by: -1, in: order)
        store.moveSelection(by: -1, in: order)
        #expect(store.selectedKey == order[0], "Clamps at the top")
    }
}
