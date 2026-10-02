import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

struct MergeRequestStoreTests {
    @Test func initialRefreshLoadsListAndAllDetails() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests

        let outcome = try #require(await store.refresh(.manual))

        #expect(store.reviewerMergeRequests.count == 8)
        #expect(outcome.wasInitialLoad)
        #expect(outcome.newMergeRequestKeys.count == 8)
        #expect(outcome.detailFetches == 8)
        #expect(spy.count("currentUser") == 1)
        #expect(store.problem == nil)
        #expect(store.lastRefreshedAt != nil)

        let pay142 = try #require(store.mergeRequests.first { $0.iid == 412 })
        #expect(pay142.jiraKey == "PAY-142")
        #expect(pay142.pipelineStatus == .success)
        #expect(pay142.approvalsGiven == 1 && pay142.approvalsRequired == 2)
        #expect(pay142.unresolvedDiscussions == 2)
        #expect(store.mergeRequests.first { $0.iid == 77 }?.jiraKey == nil)
    }

    @Test func secondRefreshSkipsUnchangedMRsButRepollsActivePipelines() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)

        let outcome = try #require(await store.refresh(.automatic))

        #expect(outcome.detailFetches == 0)
        #expect(spy.count("detail") == 8)
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
        #expect(store.mergeRequests.contains { $0.title == "Renamed title" })
    }

    @Test func reportsPipelineThatTurnedFailed() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)
        let running = try #require(store.mergeRequests.first { $0.pipelineStatus == .running })
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
        let removedKey = try #require(store.reviewerMergeRequests.last?.key)

        spy.edit { $0.data.entries.removeAll { $0.detail.key == removedKey } }
        await store.refresh(.automatic)

        #expect(store.reviewerMergeRequests.count == 7)
        #expect(!store.reviewerMergeRequests.contains { $0.key == removedKey })
    }

    @Test func keepsCachedDataAndFlagsCredentialsOn401() async throws {
        let spy = SpyGitLabClient()
        let store = AppModel.testing(gitLab: spy).mergeRequests
        await store.refresh(.automatic)

        spy.edit { $0.listFailure = .unauthorized }
        let outcome = await store.refresh(.manual)

        #expect(outcome == nil)
        #expect(store.reviewerMergeRequests.count == 8)
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
        #expect(store.reviewerMergeRequests.count == 8)
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

        #expect(store.reviewerMergeRequests.count == 8)
        #expect(store.problem == nil)
        #expect(store.mergeRequests.allSatisfy { $0.detailsError != nil && !$0.hasLoadedDetails })
    }

    @Test func draftsAreHiddenUntilTurnedOn() async throws {
        let app = AppModel.testing(gitLab: SpyGitLabClient())
        let store = app.mergeRequests
        await store.refresh(.automatic)

        #expect(store.mergeRequests.count == 7)
        #expect(!store.mergeRequests.contains { $0.isDraft })
        #expect(store.hiddenDraftCount == 1)

        store.setShowsDrafts(true)
        #expect(store.mergeRequests.count == 8)
        #expect(store.hiddenDraftCount == 0)
        #expect(AccountSettings.current(in: app.modelContainer.mainContext).showDraftMergeRequests, "The choice is saved")
    }

    @Test func hidingDraftsClearsADraftSelection() async throws {
        let store = AppModel.testing(gitLab: SpyGitLabClient()).mergeRequests
        store.setShowsDrafts(true)
        await store.refresh(.automatic)
        store.selectedKey = try #require(store.mergeRequests.first { $0.isDraft }).key

        store.setShowsDrafts(false)

        #expect(store.selectedKey == nil)
    }

    @Test func notConfiguredWithoutToken() async {
        let store = AppModel.testing(token: nil).mergeRequests
        await store.refresh(.manual)
        #expect(store.problem == .notConfigured)
    }

    @Test func selectionMovesThroughTheList() async {
        let store = AppModel.testing().mergeRequests
        await store.refresh(.automatic)

        store.selectNext()
        #expect(store.selectedKey == store.mergeRequests.first?.key)
        store.selectNext()
        #expect(store.selectedKey == store.mergeRequests[1].key)
        store.selectPrevious()
        store.selectPrevious()
        #expect(store.selectedKey == store.mergeRequests.first?.key, "Clamps at the top")
    }
}
