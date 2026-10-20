import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

@MainActor
struct TriageTests {
    private func loaded(_ spy: SpyGitLabClient = SpyGitLabClient()) async -> AppModel {
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        return app
    }

    private func situation(_ app: AppModel, _ iid: Int) throws -> MRSituation {
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
        return app.commandCenter.situation(for: mr)
    }

    @Test func everyMockMRLandsInTheExpectedLane() async throws {
        let app = await loaded()
        let expected: [Int: Lane] = [
            412: .yourMove,      // Priya replied to your thread
            1884: .yourMove,     // waiting on your approval
            1290: .yourMove,     // your pipeline failed
            233: .readyToMerge,  // yours, all green
            1295: .readyToMerge, // dependency bump, all green, no rule yet
            1873: .inFlight,     // Marco's pipeline failed
            77: .inFlight,       // pipeline running
            1880: .inFlight,     // conflicts
            80: .inFlight,       // pipeline canceled
            420: .inFlight,      // you approved; manual job pending
            415: .drafts,
        ]
        for (iid, lane) in expected {
            #expect(try situation(app, iid).lane == lane, "!\(iid)")
        }
    }

    @Test func headlinesSayWhoHasToAct() async throws {
        let app = await loaded()

        let replied = try situation(app, 412)
        #expect(replied.headline == "Priya replied to your thread")
        #expect(replied.ballWith == .you)

        #expect(try situation(app, 1884).headline == "Waiting on your approval")
        #expect(try situation(app, 1290).headline == "Your pipeline failed")

        let failed = try situation(app, 1873)
        #expect(failed.headline == "Waiting on Marco to fix the failed pipeline")
        #expect(failed.ballWith == .author("Marco"))

        let mine = try situation(app, 233)
        #expect(mine.headline == "Ready. Merge it in GitLab.")
        #expect(mine.readiness.isReady)
    }

    @Test func approvingMovesAnMRToTheNextPerson() async throws {
        let app = await loaded()
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1884 })
        #expect(app.commandCenter.situation(for: mr).lane == .yourMove)

        // What the next refresh brings back after you approve in GitLab.
        mr.approvedByUsernames = ["aj"]
        mr.approvalsGiven = 1
        mr.detailedMergeStatus = "mergeable"

        let after = app.commandCenter.situation(for: mr)
        #expect(after.lane == .readyToMerge)
    }

    @Test func briefingOrderStartsWithYourMove() async throws {
        let app = await loaded()
        let order = app.commandCenter.orderedKeys(for: .briefing)
        let lanes = app.commandCenter.lanes()
        #expect(order.prefix(lanes[.yourMove]?.count ?? 0).allSatisfy { key in lanes[.yourMove]!.contains { $0.key == key } })
        #expect(!order.contains { key in lanes[.drafts]?.contains { $0.key == key } ?? false }, "Drafts stay out of the briefing")
    }
}

@MainActor
struct MergeRuleTests {
    @Test(arguments: [
        ("", "anything", true),
        ("main", "main", true),
        ("main", "maintenance", false),
        ("platform/*", "platform/infra", true),
        ("platform/*", "payments/api", false),
        ("renovate/*", "renovate/swift-collections-1.x", true),
        ("*/api", "payments/api", true),
        ("release-?", "release-7", true),
        ("main, release/*", "release/26.4", true),
        ("MAIN", "main", true),
    ])
    func globs(pattern: String, value: String, matches: Bool) {
        #expect(MergeRuleEngine.glob(pattern, matches: value) == matches)
    }

    private func dependencyRule(_ app: AppModel) -> MergeRule {
        let rule = app.commandCenter.addRule()
        rule.name = "Dependency bumps"
        rule.sourceBranchPattern = "renovate/*"
        rule.requiredLabels = ["dependencies"]
        rule.targetBranchPattern = "main"
        return rule
    }

    @Test func ruleCoversOnlyMatchingMRsAndMovesThemToAutoMerge() async throws {
        let app = AppModel.testing()
        await app.mergeRequests.refresh(.automatic)
        let rule = dependencyRule(app)

        let covered = app.commandCenter.coveredMergeRequests(by: rule).map(\.iid)
        #expect(covered == [1295], "!77 has the label but not a renovate branch")

        let bump = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1295 })
        let situation = app.commandCenter.situation(for: bump)
        #expect(situation.lane == .autoMerge)
        #expect(situation.rule?.isReady == true)
        #expect(situation.rule?.isLive == false, "Merging starts switched off")
    }

    @Test func unmetRequirementsAreSpelledOut() async throws {
        let app = AppModel.testing()
        await app.mergeRequests.refresh(.automatic)
        let rule = app.commandCenter.addRule()
        rule.projectPattern = "platform/infra"
        rule.requireAILooksGood = true
        rule.quietMinutes = 30
        let terraform = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 77 })
        terraform.headChangedAt = .now

        let unmet = MergeRuleEngine.unmet(rule, terraform)

        #expect(unmet.contains("the pipeline passes on the latest commit"))
        #expect(unmet.contains("the AI review says it looks good"))
        #expect(unmet.contains { $0.hasPrefix("no one has pushed for 30 min") })
        #expect(app.commandCenter.situation(for: terraform).headline == "Will merge once the pipeline passes on the latest commit")
    }

    @Test func firstRuleInOrderWins() async throws {
        let app = AppModel.testing()
        await app.mergeRequests.refresh(.automatic)
        let broad = app.commandCenter.addRule()
        broad.name = "Anything into main"
        let narrow = dependencyRule(app)
        let bump = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1295 })

        #expect(app.commandCenter.ruleStatus(for: bump)?.ruleName == "Anything into main")
        app.commandCenter.move(narrow, by: -1)
        #expect(app.commandCenter.ruleStatus(for: bump)?.ruleName == "Dependency bumps")
        broad.isEnabled = false
        #expect(app.commandCenter.ruleStatus(for: bump)?.ruleName == "Dependency bumps")
    }

    @Test func ruleFromAnMRCopiesItsShape() async throws {
        let app = AppModel.testing()
        await app.mergeRequests.refresh(.automatic)
        let mine = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 233 })

        let rule = app.commandCenter.addRule(like: mine)

        #expect(rule.projectPattern == "platform/gateway")
        #expect(rule.targetBranchPattern == "main")
        #expect(rule.onlyMine)
        #expect(app.commandCenter.coveredMergeRequests(by: rule).map(\.iid) == [233])
        #expect(app.commandCenter.selectedRuleID == rule.id)
    }
}

@MainActor
struct AutoMergeTests {
    private func setUp(live: Bool) async -> (AppModel, SpyGitLabClient, MergeRule) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.mergeRequests.refresh(.automatic)
        let rule = app.commandCenter.addRule()
        rule.name = "Dependency bumps"
        rule.sourceBranchPattern = "renovate/*"
        rule.squash = true
        app.commandCenter.setAutoMergeLive(live)
        return (app, spy, rule)
    }

    private func events(_ app: AppModel, _ kind: ActivityKind) throws -> [ActivityEvent] {
        try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>()).filter { $0.kind == kind }
    }

    @Test func dryRunReportsOnceAndMergesNothing() async throws {
        let (app, spy, _) = await setUp(live: false)

        await app.commandCenter.runRules()
        await app.commandCenter.runRules()

        #expect(spy.count("merge") == 0)
        #expect(try events(app, .autoMergeWouldMerge).count == 1, "Reported once per commit")
    }

    @Test func liveRuleMergesAtTheCheckedCommit() async throws {
        let (app, spy, rule) = await setUp(live: true)
        let bump = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1295 })
        let sha = bump.headSHA

        await app.commandCenter.runRules()

        #expect(spy.state.withLock { $0.merges } == [MergeOptions(sha: sha, squash: true, shouldRemoveSourceBranch: true)])
        #expect(rule.mergeCount == 1)
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.iid == 1295 })
        #expect(try events(app, .autoMerged).count == 1)

        await app.refresh(.automatic)
        #expect(try events(app, .left).isEmpty, "An MR the rule merged isn't reported again as closed")
    }

    @Test func doesNotMergeWhatTheRuleDoesNotCover() async throws {
        let (app, spy, rule) = await setUp(live: true)
        rule.sourceBranchPattern = "nothing-matches/*"

        await app.commandCenter.runRules()

        #expect(spy.count("merge") == 0)
    }

    @Test func failedMergeIsRecordedAndNotRetriedForTheSameCommit() async throws {
        let (app, spy, _) = await setUp(live: true)
        spy.edit { $0.mergeFailure = .server(status: 405) }

        await app.commandCenter.runRules()
        await app.commandCenter.runRules()

        #expect(spy.count("merge") == 1)
        let bump = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1295 })
        #expect(bump.autoMergeError?.contains("405") == true)
        #expect(try events(app, .autoMergeFailed).count == 1)
    }

    @Test func offlineMergeIsRetried() async throws {
        let (app, spy, _) = await setUp(live: true)
        spy.edit { $0.mergeFailure = .offline }
        await app.commandCenter.runRules()

        spy.edit { $0.mergeFailure = nil }
        await app.commandCenter.runRules()

        #expect(spy.count("merge") == 2)
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.iid == 1295 })
    }

    @Test func refreshRunsTheRules() async throws {
        let (app, spy, _) = await setUp(live: true)

        await app.refresh(.automatic)

        #expect(spy.count("merge") == 1)
    }
}

struct ActivityDetectorTests {
    private func snapshot(head: String = "a", pipeline: PipelineStatus? = .running, approvers: [String: String] = [:],
                          conflicts: Bool = false, unresolved: Int = 1, awaitingMe: Int = 0, ready: Bool = false) -> MRSnapshot {
        var snapshot = MRSnapshot(TrackedMR(from: MockGitLabData.sample.entries[0].listItem))
        snapshot.hasLoadedDetails = true
        snapshot.headSHA = head
        snapshot.pipelineStatus = pipeline
        snapshot.approvers = Set(approvers.keys)
        snapshot.approverNames = approvers
        snapshot.hasConflicts = conflicts
        snapshot.unresolvedThreads = unresolved
        snapshot.threadsAwaitingMe = awaitingMe
        snapshot.lastReplyFrom = awaitingMe > 0 ? "Priya Natarajan" : nil
        snapshot.isReady = ready
        return snapshot
    }

    @Test func reportsEachKindOfChange() {
        let old = snapshot()
        let new = snapshot(head: "b1234567890", pipeline: .success, approvers: ["dana": "Dana Okafor"],
                           unresolved: 0, awaitingMe: 1, ready: true)

        let kinds = ActivityDetector.changes(from: old, to: new).map(\.kind)

        #expect(kinds == [.pushed, .pipelinePassed, .approved, .replied, .threadsResolved, .readyToMerge])
    }

    @Test func quietWhenNothingChanged() {
        #expect(ActivityDetector.changes(from: snapshot(), to: snapshot()).isEmpty)
    }

    @Test func silentUntilDetailsHaveLoaded() {
        var old = snapshot()
        old.hasLoadedDetails = false
        #expect(ActivityDetector.changes(from: old, to: snapshot(pipeline: .failed)).isEmpty)
    }

    @Test func conflictsAndRevokedApprovals() {
        let old = snapshot(approvers: ["dana": "Dana Okafor"])
        let new = snapshot(conflicts: true)
        let changes = ActivityDetector.changes(from: old, to: new)
        #expect(changes.map(\.kind) == [.approvalRevoked, .conflicts])
        #expect(changes.first?.message == "Dana Okafor removed their approval")
    }
}

struct ThreadTurnsTests {
    private let me = GitLabUserRef(id: 1, username: "me", name: "Me Myself")
    private let priya = GitLabUserRef(id: 2, username: "priya", name: "Priya Natarajan")
    private let dana = GitLabUserRef(id: 3, username: "dana", name: "Dana Okafor")

    private func thread(_ authors: [GitLabUserRef], resolved: Bool = false) -> GitLabDiscussion {
        GitLabDiscussion(id: UUID().uuidString, individualNote: false, notes: authors.enumerated().map { index, author in
            GitLabDiscussion.Note(id: index, resolvable: true, resolved: resolved, system: false, author: author,
                                  createdAt: Date(timeIntervalSince1970: TimeInterval(index)))
        })
    }

    @Test func reviewerSeesRepliesToTheirThreads() {
        let turns = ThreadTurns(discussions: [
            thread([me, priya]),          // replied to me
            thread([me]),                 // waiting on others
            thread([dana, priya]),        // not mine
            thread([me, priya], resolved: true),
        ], me: "me", isMyMR: false)

        #expect(turns.awaitingMe == 1)
        #expect(turns.awaitingOthers == 1)
        #expect(turns.lastReplyFrom == "Priya Natarajan")
    }

    @Test func authorOwesAReplyOnEveryOpenThread() {
        let turns = ThreadTurns(discussions: [thread([dana]), thread([priya, me])], me: "me", isMyMR: true)
        #expect(turns.awaitingMe == 1)
        #expect(turns.awaitingOthers == 1)
    }

    @Test func unknownUserCountsNothing() {
        #expect(ThreadTurns(discussions: [thread([priya])], me: nil, isMyMR: true) == ThreadTurns(discussions: [], me: nil, isMyMR: true))
    }
}
