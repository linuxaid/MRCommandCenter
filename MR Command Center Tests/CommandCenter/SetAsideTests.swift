import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

/// Issue #6: park a Your move MR you can't act on, so Your move can get back to zero.
@MainActor
struct SetAsideTests {
    private let spy = SpyGitLabClient()
    private let app: AppModel
    private var center: CommandCenter { app.commandCenter }

    init() {
        app = AppModel.testing(gitLab: spy)
    }

    /// !412: Priya replied to your thread, so it's your move.
    private func loaded() async throws -> TrackedMR {
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        try #require(center.situation(for: mr).lane == .yourMove)
        return mr
    }

    private func events(_ kind: ActivityKind, for mr: TrackedMR) throws -> [ActivityEvent] {
        try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
            .filter { $0.mrKey == mr.key && $0.kind == kind }
    }

    @Test func settingAsideMovesItToItsOwnLane() async throws {
        let mr = try await loaded()
        let yourMoveBefore = center.lanes()[.yourMove]?.count ?? 0

        center.setAside(mr)

        let situation = center.situation(for: mr)
        #expect(situation.lane == .setAside)
        #expect(situation.headline.hasPrefix("Set aside: "))
        #expect(center.lanes()[.yourMove]?.count ?? 0 == yourMoveBefore - 1, "Your move gets closer to zero")
        #expect(!center.orderedKeys(for: .briefing).contains(mr.key), "Not mixed into the briefing")
        #expect(center.orderedKeys(for: .lane(.setAside)) == [mr.key])
    }

    @Test func settingAsideIsRecordedLocallyOnly() async throws {
        let mr = try await loaded()
        let callsBefore = spy.state.withLock { $0.calls }

        center.setAside(mr)

        #expect(try events(.setAside, for: mr).count == 1)
        #expect(spy.state.withLock { $0.calls } == callsBefore, "Nothing is sent to GitLab")
    }

    @Test func staysSetAsideWhileNothingChanges() async throws {
        let mr = try await loaded()
        center.setAside(mr)

        await app.refresh(.manual)

        #expect(center.situation(for: mr).lane == .setAside)
        #expect(mr.setAsideAt != nil)
    }

    @Test func aNewPushBringsItBack() async throws {
        let mr = try await loaded()
        center.setAside(mr)

        mr.headSHA = String(repeating: "f", count: 40)
        center.releaseSetAside()

        #expect(center.situation(for: mr).lane == .yourMove)
        #expect(mr.setAsideAt == nil, "Released for good")
        #expect(try events(.broughtBack, for: mr).count == 1)
    }

    @Test func bringingBackUndoesIt() async throws {
        let mr = try await loaded()
        center.setAside(mr)

        center.bringBack(mr)

        #expect(center.situation(for: mr).lane == .yourMove)
        #expect(mr.setAsideAt == nil && mr.setAsideSHA == nil && mr.setAsideReason == nil)
        #expect(try events(.broughtBack, for: mr).count == 1)
    }

    @Test func onlyYourMoveMRsCanBeSetAside() async throws {
        await app.refresh(.automatic)
        let other = try #require(app.mergeRequests.trackedMergeRequests.first { center.situation(for: $0).lane == .inFlight })

        center.setAside(other)

        #expect(other.setAsideAt == nil)
        #expect(center.situation(for: other).lane == .inFlight)
    }

    @Test func leavingYourMoveOnItsOwnClearsItQuietly() async throws {
        await app.refresh(.automatic)
        let other = try #require(app.mergeRequests.trackedMergeRequests.first { center.situation(for: $0).lane == .inFlight })
        other.setAsideAt = .now
        other.setAsideSHA = other.headSHA
        other.setAsideReason = YourMoveReason.approval.rawValue

        center.releaseSetAside()

        #expect(other.setAsideAt == nil)
        #expect(try events(.broughtBack, for: other).isEmpty, "It isn't back in Your move, so nothing to announce")
    }

    @Test func aPushSeenOnRefreshBringsItBackAndSaysSo() async throws {
        let mr = try await loaded()
        center.setAside(mr)
        spy.edit { state in
            let index = state.data.entries.firstIndex { $0.detail.iid == 412 }!
            var entry = state.data.entries[index]
            let d = entry.detail
            entry.detail = GitLabMergeRequest(
                id: d.id, iid: d.iid, projectId: d.projectId, title: d.title, description: d.description, state: "opened",
                createdAt: d.createdAt, updatedAt: d.updatedAt.addingTimeInterval(60),
                sourceBranch: d.sourceBranch, targetBranch: d.targetBranch, author: d.author, labels: d.labels,
                sha: String(repeating: "e", count: 40), references: d.references, webUrl: d.webUrl,
                headPipeline: d.headPipeline
            )
            state.data.entries[index] = entry
        }

        await app.refresh(.manual)

        #expect(center.situation(for: mr).lane == .yourMove)
        #expect(mr.setAsideAt == nil)
        #expect(try events(.broughtBack, for: mr).count == 1)
    }

    @Test func settingAsideDoesntMarkItUnseen() async throws {
        let mr = try await loaded()
        mr.seenAt = .now
        app.mergeRequests.markSeen(mr)
        center.setAside(mr)
        #expect(!mr.hasUnseenActivity, "You did it yourself; there's no news")
    }

    @Test func repliesWaitingOnYouAreTimestamped() async throws {
        let mr = try await loaded()
        #expect(mr.lastReplyToMeAt != nil)
    }
}

/// The pure rule behind "until something new happens".
@MainActor
struct SetAsideRuleTests {
    private func parked() -> TrackedMR {
        let mr = TrackedMR(from: MockGitLabData.sample.entries[0].detail)
        mr.headSHA = "aaaa"
        mr.setAsideAt = Date(timeIntervalSince1970: 1_000)
        mr.setAsideSHA = "aaaa"
        mr.setAsideReason = YourMoveReason.threads.rawValue
        mr.lastReplyToMeAt = Date(timeIntervalSince1970: 900)
        mr.setAsideReplyAt = Date(timeIntervalSince1970: 900)
        return mr
    }

    @Test func unchangedStaysParked() {
        #expect(MRSituation.isStillSetAside(parked(), reason: .threads))
    }

    @Test func aNewReplyToYouEndsIt() {
        let mr = parked()
        mr.lastReplyToMeAt = Date(timeIntervalSince1970: 1_100)
        #expect(!MRSituation.isStillSetAside(mr, reason: .threads))
    }

    @Test func aNewPushEndsIt() {
        let mr = parked()
        mr.headSHA = "bbbb"
        #expect(!MRSituation.isStillSetAside(mr, reason: .threads))
    }

    @Test func aNewReasonToNeedYouEndsIt() {
        #expect(!MRSituation.isStillSetAside(parked(), reason: .approval))
    }

    @Test func fewerThreadsWaitingIsNotNew() {
        // Someone resolved one of two threads: the headline count changes, the reason doesn't.
        #expect(MRSituation.isStillSetAside(parked(), reason: .threads))
    }

    @Test func aReplyWrittenBeforeSettingAsideButFetchedAfterIsNew() {
        // GitLab time 950 is before the local set-aside time (1000), but you never saw it.
        let mr = parked()
        mr.lastReplyToMeAt = Date(timeIntervalSince1970: 950)
        #expect(!MRSituation.isStillSetAside(mr, reason: .threads))
    }

    @Test func aFirstReplyWhenThereWasNoneIsNew() {
        let mr = parked()
        mr.setAsideReplyAt = nil
        #expect(!MRSituation.isStillSetAside(mr, reason: .threads))
    }

    @Test func neverSetAsideIsntParked() {
        let mr = parked()
        mr.setAsideAt = nil
        #expect(!MRSituation.isStillSetAside(mr, reason: .threads))
    }
}
