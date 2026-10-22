import Foundation
import Testing
@testable import MR_Command_Center

/// Merged or closed MRs stay reachable from Activity, read only, from their last snapshot.
struct PastMergeRequestTests {
    private let spy = SpyGitLabClient()
    private let app: AppModel
    private var store: MergeRequestStore { app.mergeRequests }

    init() {
        app = AppModel.testing(gitLab: spy)
    }

    /// Refreshes, then refreshes again after MR !77 merged (left GitLab's open list).
    private func mergeOne() async throws -> String {
        await store.refresh(.automatic)
        let key = try #require(store.trackedMergeRequests.first { $0.iid == 77 }).key
        spy.edit { $0.data.entries.removeAll { $0.detail.iid == 77 } }
        await store.refresh(.automatic)
        return key
    }

    @Test func mergedMRCanBeOpenedFromActivityReadOnly() async throws {
        let key = try await mergeOne()
        #expect(store.mergeRequest(forKey: key) == nil, "It's no longer in the open list")
        #expect(store.canOpenActivity(forKey: key))

        store.selectActivity(forKey: key)

        #expect(store.selectedPastKey == key)
        #expect(store.selectedKey == nil, "It isn't selected as an open MR, so no actions apply")
        #expect(store.selected == nil)
        let past = try #require(store.selectedPast)
        #expect(past.iid == 77)
        #expect(!past.webURL.isEmpty, "The GitLab link is kept")
    }

    @Test func openMRFromActivityStillOpensItsBrief() async throws {
        await store.refresh(.automatic)
        let key = try #require(store.trackedMergeRequests.first).key
        #expect(store.pastMergeRequest(forKey: key) == nil)

        store.selectActivity(forKey: key)

        #expect(store.selectedKey == key)
        #expect(store.selectedPastKey == nil)
    }

    @Test func unknownMRCantBeOpened() async throws {
        await store.refresh(.automatic)
        #expect(!store.canOpenActivity(forKey: "nope"))
        store.selectActivity(forKey: "nope")
        #expect(store.selectedKey == nil && store.selectedPastKey == nil)
    }

    @Test func pickingAnOpenMRClearsThePastOneAndViceVersa() async throws {
        let pastKey = try await mergeOne()
        let openKey = try #require(store.trackedMergeRequests.first).key

        store.selectActivity(forKey: pastKey)
        store.selectedKey = openKey
        #expect(store.selectedPastKey == nil)

        store.selectActivity(forKey: pastKey)
        #expect(store.selectedKey == nil)
        #expect(store.selectedPastKey == pastKey)
    }

    @Test func leavingActivityClearsThePastSelection() async throws {
        let key = try await mergeOne()
        app.commandCenter.destination = .activity
        store.selectActivity(forKey: key)

        app.commandCenter.destination = .activity
        #expect(store.selectedPastKey == key)

        app.commandCenter.destination = .briefing
        #expect(store.selectedPastKey == nil)
    }

    @Test func reopenedMRIsOpenAgainNotPast() async throws {
        let key = try await mergeOne()
        spy.edit { $0.data = MockGitLabData.sample }
        await store.refresh(.automatic)

        #expect(store.pastMergeRequest(forKey: key) == nil)
        store.selectActivity(forKey: key)
        #expect(store.selectedKey == key)
    }
}
