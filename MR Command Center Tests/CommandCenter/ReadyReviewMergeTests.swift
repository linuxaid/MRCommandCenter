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

    init() {
        app = AppModel.testing(gitLab: spy)
    }

    private func loaded() async throws -> TrackedMR {
        await app.refresh(.automatic)
        return try #require(app.mergeRequests.trackedMergeRequests.first {
            $0.isReviewer && !$0.isAuthor && Readiness($0).isReady
        }, "The mock data has a ready MR you're reviewing")
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
        let defaults = UserDefaults.standard
        let previous = (defaults.object(forKey: "mergeSquash"), defaults.object(forKey: "mergeRemoveSourceBranch"))
        defer {
            defaults.set(previous.0, forKey: "mergeSquash")
            defaults.set(previous.1, forKey: "mergeRemoveSourceBranch")
        }
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
