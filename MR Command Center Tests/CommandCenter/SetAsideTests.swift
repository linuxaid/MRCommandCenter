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

    @Test func outOfYourMoveItShowsInItsOwnLaneAndStaysSetAsideQuietly() async throws {
        await app.refresh(.automatic)
        let other = try #require(app.mergeRequests.trackedMergeRequests.first { center.situation(for: $0).lane == .inFlight })
        other.setAsideAt = .now
        other.setAsideSHA = other.headSHA
        other.setAsideReason = YourMoveReason.approval.rawValue

        center.releaseSetAside()

        #expect(center.situation(for: other).lane == .inFlight, "Nothing to park while it isn't your move")
        #expect(other.setAsideAt != nil, "Kept, in case the same reason comes back")
        #expect(try events(.broughtBack, for: other).isEmpty)
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

    @Test func fewerThreadsWaitingIsNotNew() async throws {
        let mr = try await loaded()
        mr.threadsAwaitingMe = 2
        let newest = try #require(mr.lastReplyToMeAt)
        center.setAside(mr)
        #expect(center.situation(for: mr).headline.contains("2 threads"))

        // The newest thread was resolved: one fewer waiting, and the latest reply is older.
        mr.threadsAwaitingMe = 1
        mr.lastReplyToMeAt = newest.addingTimeInterval(-3600)
        center.releaseSetAside()

        #expect(center.situation(for: mr).lane == .setAside)
        #expect(mr.setAsideAt != nil)
    }

    @Test func aDifferentReasonBringsItBack() async throws {
        let mr = try await loaded()
        center.setAside(mr)

        // The threads were answered, and now it's waiting on your approval instead.
        mr.threadsAwaitingMe = 0
        mr.threadsAwaitingOthers = 0
        let natural = MRSituation.ignoringSetAside(for: mr, me: app.mergeRequests.username, rule: nil)
        try #require(natural.yourMoveReason == .approval)
        center.releaseSetAside()

        #expect(center.situation(for: mr).lane == .yourMove)
        #expect(mr.setAsideAt == nil)
        #expect(try events(.broughtBack, for: mr).count == 1)
    }

    /// A pipeline rerun on the same commit, or GitLab rechecking conflicts, takes the MR out of
    /// Your move for a refresh or two. That's not news, so it must still be set aside after.
    @Test func aPassingStateDoesntReleaseIt() async throws {
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first {
            let reason = center.situation(for: $0).yourMoveReason
            return reason == .pipeline || reason == .conflicts
        })
        let reason = try #require(center.situation(for: mr).yourMoveReason)
        center.setAside(mr)
        let pipeline = mr.pipelineStatusRaw, conflicts = mr.hasConflicts, status = mr.detailedMergeStatus

        if reason == .pipeline {
            mr.pipelineStatusRaw = PipelineStatus.running.rawValue
        } else {
            mr.hasConflicts = false
            mr.detailedMergeStatus = "checking"
        }
        #expect(center.situation(for: mr).lane != .yourMove, "Out of Your move while it reruns")
        center.releaseSetAside()
        #expect(mr.setAsideAt != nil, "Still set aside")

        mr.pipelineStatusRaw = pipeline
        mr.hasConflicts = conflicts
        mr.detailedMergeStatus = status
        center.releaseSetAside()
        #expect(center.situation(for: mr).lane == .setAside)
        #expect(try events(.broughtBack, for: mr).isEmpty)
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

    @Test func aReplyWrittenBeforeSettingAsideButFetchedAfterIsNew() {
        // GitLab time 950 is before the local set-aside time (1000), but you never saw it.
        let mr = parked()
        mr.lastReplyToMeAt = Date(timeIntervalSince1970: 950)
        #expect(!MRSituation.isStillSetAside(mr, reason: .threads))
    }

    @Test func anUnknownReplyTimeIsNotTakenAsNew() {
        // A store from before reply times were kept: the first time we learn isn't news.
        let mr = parked()
        mr.setAsideReplyAt = nil
        #expect(MRSituation.isStillSetAside(mr, reason: .threads))
    }

    @Test func outOfYourMoveForAWhileIsNotNew() {
        #expect(!MRSituation.somethingNewSinceSetAside(parked(), reason: nil))
    }

    @Test func neverSetAsideIsntParked() {
        let mr = parked()
        mr.setAsideAt = nil
        #expect(!MRSituation.isStillSetAside(mr, reason: .threads))
    }
}
