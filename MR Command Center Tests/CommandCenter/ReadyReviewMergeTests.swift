import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

/// Issue #7: with the setting on, ready MRs you're reviewing merge on their own.
@MainActor
@Suite(.serialized)
struct ReadyReviewMergeTests {
    private let spy = SpyGitLabClient()
    private let app: AppModel
    private var center: CommandCenter { app.commandCenter }

    /// Its own defaults, so the app's real remembered merge choices are never touched.
    private let defaults: UserDefaults

    init() {
        app = AppModel.testing(gitLab: spy)
        let name = "ReadyReviewMergeTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        app.commandCenter.mergeDefaults = defaults
    }

    private func isReadyReview(_ mr: TrackedMR) -> Bool {
        mr.isReviewer && !mr.isAuthor && center.situation(for: mr).lane == .readyToMerge
    }

    private func loaded() async throws -> TrackedMR {
        await app.refresh(.automatic)
        return try #require(app.mergeRequests.trackedMergeRequests.first(where: isReadyReview),
                            "The mock data has a ready MR you're reviewing")
    }

    /// Makes a second MR you're reviewing ready, so there are two to merge.
    private func makeReady(_ mr: TrackedMR) {
        mr.isDraft = false
        mr.approvalsGiven = max(mr.approvalsRequired, 1)
        mr.approvalsRequired = max(mr.approvalsRequired, 1)
        mr.approvedByUsernames = ["aj"]
        mr.pipelineStatusRaw = PipelineStatus.success.rawValue
        mr.pipelineSHA = mr.headSHA
        mr.unresolvedDiscussions = 0
        mr.threadsAwaitingMe = 0
        mr.threadsAwaitingOthers = 0
        mr.hasConflicts = false
        mr.detailedMergeStatus = "mergeable"
        mr.mergeWhenPipelineSucceeds = false
    }

    private func events(_ kind: ActivityKind, for mr: TrackedMR) throws -> [ActivityEvent] {
        try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
            .filter { $0.mrKey == mr.key && $0.kind == kind }
    }

    @Test func offByDefaultNothingMerges() async throws {
        let mr = try await loaded()
        #expect(!center.mergesReadyReviews)

        await center.runRules()

        #expect(spy.count("merge") == 0)
        #expect(center.situation(for: mr).lane == .readyToMerge)
    }

    @Test func onItShowsAsMergingAndMergesOnTheNextCheck() async throws {
        let mr = try await loaded()
        let sha = mr.headSHA
        center.setMergesReadyReviews(true)

        let situation = center.situation(for: mr)
        #expect(situation.lane == .autoMerge)
        #expect(situation.headline == "Merging on the next check")

        await center.runRules()

        #expect(spy.count("merge") == 1)
        #expect(spy.state.withLock { $0.merges.last?.sha } == sha, "Pinned to the commit that was checked")
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.key == mr.key })
        #expect(try events(.autoMerged, for: mr).count == 1)
    }

    @Test func mergesEvenWhileRulesAreADryRun() async throws {
        _ = try await loaded()
        #expect(!center.isAutoMergeLive)
        center.setMergesReadyReviews(true)

        await center.runRules()

        #expect(spy.count("merge") == 1)
    }

    @Test func yourOwnMRsAreLeftAlone() async throws {
        await app.refresh(.automatic)
        let mine = try #require(app.mergeRequests.trackedMergeRequests.first { $0.isAuthor && Readiness($0).isReady })
        center.setMergesReadyReviews(true)

        await center.runRules()

        #expect(app.mergeRequests.trackedMergeRequests.contains { $0.key == mine.key })
        #expect(center.situation(for: mine).lane == .readyToMerge)
    }

    @Test func notReadyReviewsAreLeftAlone() async throws {
        await app.refresh(.automatic)
        let waiting = app.mergeRequests.trackedMergeRequests.filter { $0.isReviewer && !$0.isAuthor && !Readiness($0).isReady }
        try #require(!waiting.isEmpty)
        center.setMergesReadyReviews(true)

        await center.runRules()

        for mr in waiting {
            #expect(app.mergeRequests.trackedMergeRequests.contains { $0.key == mr.key })
        }
    }

    @Test func usesYourRememberedMergeOptions() async throws {
        defaults.set(true, forKey: "mergeSquash")
        defaults.set(false, forKey: "mergeRemoveSourceBranch")
        _ = try await loaded()
        center.setMergesReadyReviews(true)

        await center.runRules()

        let options = try #require(spy.state.withLock { $0.merges.last })
        #expect(options.squash == true)
        #expect(options.shouldRemoveSourceBranch == false)
    }

    @Test func aRuleThatCoversItWins() async throws {
        let mr = try await loaded()
        center.addRule()
        center.setMergesReadyReviews(true)
        #expect(center.ruleStatus(for: mr)?.ruleID != CommandCenter.readyReviewsRuleID)

        await center.runRules()

        #expect(spy.count("merge") == 0, "Your rule is a dry run, and it owns this MR")
        #expect(try events(.autoMergeWouldMerge, for: mr).count == 1)
    }

    @Test func aFailureIsReportedAndNotRetriedForTheSameCommit() async throws {
        let mr = try await loaded()
        spy.edit { $0.mergeFailure = .server(status: 405) }
        center.setMergesReadyReviews(true)

        await center.runRules()
        await center.runRules()

        #expect(spy.count("merge") == 1)
        #expect(mr.autoMergeError?.contains("405") == true, "Shown on the brief")
        #expect(try events(.autoMergeFailed, for: mr).count == 1)
        #expect(center.mergeFailures.map(\.mrKey) == [mr.key], "And as a banner")
        #expect(app.mergeRequests.trackedMergeRequests.contains { $0.key == mr.key })
        #expect(center.situation(for: mr).lane == .readyToMerge, "Back where you'd merge it by hand")
    }

    @Test func aLaterSuccessClearsTheBanner() async throws {
        let mr = try await loaded()
        spy.edit { $0.mergeFailure = .server(status: 405) }
        center.setMergesReadyReviews(true)
        await center.runRules()
        #expect(center.mergeFailures.count == 1)

        // Something new is pushed and GitLab accepts it this time; the next refresh merges it.
        spy.edit { state in
            state.mergeFailure = nil
            let index = state.data.entries.firstIndex { $0.detail.iid == mr.iid }!
            var entry = state.data.entries[index]
            let d = entry.detail
            entry.detail = GitLabMergeRequest(
                id: d.id, iid: d.iid, projectId: d.projectId, title: d.title, description: d.description, state: "opened",
                createdAt: d.createdAt, updatedAt: d.updatedAt.addingTimeInterval(60),
                sourceBranch: d.sourceBranch, targetBranch: d.targetBranch, author: d.author, labels: d.labels,
                sha: String(repeating: "d", count: 40), references: d.references, webUrl: d.webUrl,
                headPipeline: d.headPipeline
            )
            state.data.entries[index] = entry
        }
        await app.refresh(.manual)

        #expect(spy.count("merge") == 2, "Tried again at the new commit")
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.key == mr.key })
        #expect(center.mergeFailures.isEmpty)
    }

    @Test func aDryRunReportDoesntHoldBackARealMergeLater() async throws {
        let mr = try await loaded()
        let rule = center.addRule()
        await center.runRules()
        #expect(try events(.autoMergeWouldMerge, for: mr).count == 1)

        rule.isEnabled = false
        center.setMergesReadyReviews(true)
        await center.runRules()

        #expect(spy.count("merge") == 1)
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.key == mr.key })
    }

    @Test func withoutAGitLabAccountItSaysSoAndTriesAgainLater() async throws {
        let mr = try await loaded()
        AccountSettings.current(in: app.modelContainer.mainContext).gitLabBaseURL = ""
        center.setMergesReadyReviews(true)

        await center.runRules()

        #expect(spy.count("merge") == 0)
        #expect(mr.autoMergeError?.contains("GitLab account") == true)
        #expect(mr.autoMergeHandledSHA == nil, "Not marked as tried")
    }

    @Test(arguments: [(false, false, false, nil), (true, false, false, "Dry run"), (true, true, false, "On"),
                      (true, false, true, "Partly on"), (false, false, true, "On")] as [(Bool, Bool, Bool, String?)])
    func sidebarBadge(rules: Bool, live: Bool, reviews: Bool, expected: String?) async throws {
        await app.refresh(.automatic)
        if rules { center.addRule() }
        center.setAutoMergeLive(live)
        center.setMergesReadyReviews(reviews)
        #expect(center.autoMergeBadge == expected)
    }

    @Test func aReplyWaitingOnYouIsNotMergedEvenIfGitLabSaysMergeable() async throws {
        let mr = try await loaded()
        mr.threadsAwaitingMe = 1
        mr.unresolvedDiscussions = 1
        mr.lastReplyFrom = "Priya Natarajan"
        mr.detailedMergeStatus = "mergeable"
        center.setMergesReadyReviews(true)
        #expect(center.situation(for: mr).lane == .yourMove, "The card says a reply is waiting on you")

        await center.runRules()

        #expect(spy.count("merge") == 0)
    }

    @Test func aSetAsideMRIsNotMerged() async throws {
        let mr = try await loaded()
        mr.threadsAwaitingMe = 1
        mr.unresolvedDiscussions = 1
        center.setAside(mr)
        try #require(center.situation(for: mr).lane == .setAside)
        center.setMergesReadyReviews(true)

        await center.runRules()

        #expect(spy.count("merge") == 0)
    }

    @Test func draftsAreLeftAlone() async throws {
        let mr = try await loaded()
        mr.isDraft = true
        center.setMergesReadyReviews(true)

        await center.runRules()

        #expect(spy.count("merge") == 0)
    }

    @Test func oneFailingDoesntStopTheOthers() async throws {
        let first = try await loaded()
        let second = try #require(app.mergeRequests.trackedMergeRequests.first {
            $0.isReviewer && !$0.isAuthor && $0.key != first.key
        })
        makeReady(second)
        try #require(isReadyReview(second))
        spy.edit { $0.mergeFailuresByIID[first.iid] = .server(status: 406) }
        center.setMergesReadyReviews(true)

        await center.runRules()

        #expect(spy.count("merge") == 2, "Both were tried")
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.key == second.key }, "The other one merged")
        #expect(app.mergeRequests.trackedMergeRequests.contains { $0.key == first.key })
        #expect(first.autoMergeError?.contains("406") == true)
        #expect(center.mergeFailures.map(\.mrKey) == [first.key])
    }

    @Test func aFailureThatWillBeRetriedHasNoBannerAndIsRetried() async throws {
        let mr = try await loaded()
        spy.edit { $0.mergeFailure = .server(status: 409) }
        center.setMergesReadyReviews(true)

        await center.runRules()
        #expect(center.mergeFailures.isEmpty, "It'll be tried again, so no banner yet")
        #expect(mr.autoMergeHandledSHA == nil)

        spy.edit { $0.mergeFailure = nil }
        await center.runRules()
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.key == mr.key }, "The retry merged it")
    }

    @Test func turningItOffStopsIt() async throws {
        let mr = try await loaded()
        center.setMergesReadyReviews(true)
        center.setMergesReadyReviews(false)

        await center.runRules()

        #expect(spy.count("merge") == 0)
        #expect(center.situation(for: mr).lane == .readyToMerge)
    }
}
