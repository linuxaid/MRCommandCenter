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
        #expect(mine.headline == "Ready for you to merge")
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

@MainActor
struct ManualActionTests {
    private func loaded() async -> (AppModel, SpyGitLabClient) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        return (app, spy)
    }

    private func mr(_ app: AppModel, _ iid: Int) throws -> TrackedMR {
        try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
    }

    @Test func approvingMovesItOutOfYourMove() async throws {
        let (app, spy) = await loaded()
        let lazy = try mr(app, 1884)
        #expect(app.commandCenter.situation(for: lazy).lane == .yourMove)

        await app.commandCenter.approve(lazy)

        #expect(spy.count("approve") == 1)
        #expect(lazy.approvedByUsernames.contains("aj"))
        #expect(app.commandCenter.situation(for: lazy).lane == .readyToMerge)
        #expect(app.commandCenter.actionErrors[lazy.key] == nil)
    }

    @Test func revokingPutsItBack() async throws {
        let (app, _) = await loaded()
        let lazy = try mr(app, 1884)
        await app.commandCenter.approve(lazy)

        await app.commandCenter.revokeApproval(lazy)

        #expect(!lazy.approvedByUsernames.contains("aj"))
        #expect(app.commandCenter.situation(for: lazy).lane == .yourMove)
    }

    @Test func approvalFailureIsExplained() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeFailure = .forbidden }
        let lazy = try mr(app, 1884)

        await app.commandCenter.approve(lazy)

        #expect(app.commandCenter.actionErrors[lazy.key]?.contains("api scope") == true)
    }

    @Test func mergeIsPinnedToTheCommitYouSaw() async throws {
        let (app, spy) = await loaded()
        let gateway = try mr(app, 233)
        app.commandCenter.requestMerge(gateway)
        var draft = try #require(app.commandCenter.mergeDraft)
        #expect(draft.notReady.isEmpty)
        draft.squash = true

        await app.commandCenter.startMerge(draft)?.value

        #expect(spy.state.withLock { $0.merges.last?.sha } == draft.sha)
        #expect(spy.state.withLock { $0.merges.last?.squash } == true)
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.iid == 233 })
    }

    @Test func mergeRefusesIfTheHeadMovedAfterConfirming() async throws {
        let (app, spy) = await loaded()
        let gateway = try mr(app, 233)
        app.commandCenter.requestMerge(gateway)
        let draft = try #require(app.commandCenter.mergeDraft)
        gateway.headSHA = String(repeating: "f", count: 40)

        await app.commandCenter.startMerge(draft)?.value

        #expect(spy.count("merge") == 0)
        #expect(app.commandCenter.actionErrors[gateway.key] != nil)
    }

    @Test func runningPipelineOffersMergeWhenItSucceeds() async throws {
        let (app, spy) = await loaded()
        let terraform = try mr(app, 77)
        app.commandCenter.requestMerge(terraform)
        let draft = try #require(app.commandCenter.mergeDraft)
        #expect(draft.pipelineRunning && draft.whenPipelineSucceeds)

        await app.commandCenter.startMerge(draft)?.value

        #expect(spy.state.withLock { $0.merges.last?.mergeWhenPipelineSucceeds } == true)
        #expect(terraform.isInReviewerList, "Still open until the pipeline passes")
        #expect(terraform.mergeWhenPipelineSucceeds)
        #expect(app.commandCenter.situation(for: terraform).lane == .autoMerge)
    }
}

/// Issue #8: merging doesn't hold you in the dialog; failures come back as a banner.
@MainActor
struct BackgroundMergeTests {
    private func loaded() async -> (AppModel, SpyGitLabClient) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        return (app, spy)
    }

    private func draft(_ app: AppModel, _ iid: Int) throws -> MergeDraft {
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
        app.commandCenter.requestMerge(mr)
        return try #require(app.commandCenter.mergeDraft)
    }

    @Test func startReturnsBeforeGitLabAnswersAndTheMergeFinishesOnItsOwn() async throws {
        let (app, spy) = await loaded()
        let draft = try draft(app, 233)

        let task = try #require(app.commandCenter.startMerge(draft), "The dialog can close")
        #expect(spy.count("merge") == 0, "Nothing has been sent yet when start returns")

        await task.value
        #expect(spy.count("merge") == 1)
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.iid == 233 })
        #expect(app.commandCenter.mergeFailures.isEmpty)
        #expect(!app.commandCenter.mergingKeys.contains(draft.mrKey))
        let merged = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
            .filter { $0.mrKey == draft.mrKey && $0.kind == .autoMerged }
        #expect(merged.count == 1, "Activity records the merge")
    }

    @Test func theMRIsBusyAsSoonAsTheMergeStarts() async throws {
        let (app, spy) = await loaded()
        let draft = try draft(app, 233)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 233 })

        let task = app.commandCenter.startMerge(draft)
        #expect(app.commandCenter.mergingKeys.contains(draft.mrKey), "The row spinner shows right away")

        // Something else tries to act on the same MR before the merge task has run.
        await app.commandCenter.approve(mr)
        await task?.value

        #expect(spy.count("approve") == 0, "The approval is refused while the merge holds the MR")
        #expect(spy.count("merge") == 1)
        #expect(app.commandCenter.mergeFailures.isEmpty)
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.iid == 233 })
    }

    @Test func aMergeAlreadyRunningKeepsTheDialogOpenWithTheReason() async throws {
        let (app, spy) = await loaded()
        let draft = try draft(app, 233)
        let task = app.commandCenter.startMerge(draft)

        #expect(app.commandCenter.startMerge(draft) == nil)
        #expect(app.commandCenter.actionErrors[draft.mrKey]?.contains("already running") == true)
        await task?.value
        #expect(spy.count("merge") == 1)
    }

    @Test func mergeWhenThePipelineSucceedsStillWorksInTheBackground() async throws {
        let (app, spy) = await loaded()
        let draft = try draft(app, 77)
        #expect(draft.pipelineRunning && draft.whenPipelineSucceeds)

        await app.commandCenter.startMerge(draft)?.value

        let terraform = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 77 })
        #expect(spy.state.withLock { $0.merges.last?.mergeWhenPipelineSucceeds } == true)
        #expect(terraform.mergeWhenPipelineSucceeds)
        #expect(app.commandCenter.mergeFailures.isEmpty)
    }

    @Test func aFailedMergeIsReportedAsABanner() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeFailure = .server(status: 405) }
        let draft = try draft(app, 233)

        await app.commandCenter.startMerge(draft)?.value

        let failure = try #require(app.commandCenter.mergeFailures.first)
        #expect(failure.mrKey == draft.mrKey)
        #expect(failure.reference == draft.reference)
        #expect(failure.message.contains("405"))
        #expect(app.commandCenter.actionErrors[draft.mrKey] == failure.message, "The brief shows it too")
        #expect(app.mergeRequests.trackedMergeRequests.contains { $0.iid == 233 }, "Still open")
    }

    @Test func dismissingRemovesTheBanner() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeFailure = .server(status: 405) }
        await app.commandCenter.startMerge(try draft(app, 233))?.value
        let failure = try #require(app.commandCenter.mergeFailures.first)

        app.commandCenter.dismissMergeFailure(failure)

        #expect(app.commandCenter.mergeFailures.isEmpty)
    }

    @Test func retryingClearsTheOldBannerAndSucceeds() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeFailure = .server(status: 405) }
        let first = try draft(app, 233)
        await app.commandCenter.startMerge(first)?.value
        #expect(app.commandCenter.mergeFailures.count == 1)

        spy.edit { $0.mergeFailure = nil }
        await app.commandCenter.startMerge(try draft(app, 233))?.value

        #expect(app.commandCenter.mergeFailures.isEmpty)
        #expect(!app.mergeRequests.trackedMergeRequests.contains { $0.iid == 233 })
    }

    @Test func severalMergesRunAtOnceAndEachFailureIsKept() async throws {
        let (app, spy) = await loaded()
        spy.edit { $0.mergeFailure = .server(status: 406) }
        let a = try draft(app, 233)
        let b = try draft(app, 77)

        let tasks = [app.commandCenter.startMerge(a), app.commandCenter.startMerge(b)]
        #expect(tasks.allSatisfy { $0 != nil }, "Moving to the next MR and merging it doesn't wait for the first")
        for task in tasks { await task?.value }

        #expect(Set(app.commandCenter.mergeFailures.map(\.mrKey)) == [a.mrKey, b.mrKey])
    }

    private func failure(_ app: AppModel, _ spy: SpyGitLabClient, _ iid: Int) async throws -> MergeFailure {
        spy.edit { $0.mergeFailure = .server(status: 405) }
        await app.commandCenter.startMerge(try draft(app, iid))?.value
        return try #require(app.commandCenter.mergeFailures.first)
    }

    @Test func showFromRulesOpensTheBriefingWithTheMR() async throws {
        let (app, spy) = await loaded()
        let failure = try await failure(app, spy, 233)
        app.commandCenter.destination = .rules

        #expect(app.commandCenter.canShow(failure))
        app.commandCenter.show(failure)

        #expect(app.commandCenter.destination == .briefing)
        #expect(app.mergeRequests.selectedKey == failure.mrKey)
        #expect(app.commandCenter.orderedKeys(for: .briefing).contains(failure.mrKey), "Arrow keys have an anchor")
        #expect(app.commandCenter.mergeFailures.isEmpty)
    }

    @Test func showFromALaneThatDoesntListTheMRLeavesThatLane() async throws {
        let (app, spy) = await loaded()
        let failure = try await failure(app, spy, 233)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 233 })
        let lane = app.commandCenter.situation(for: mr).lane
        let other = try #require(Lane.allCases.first { $0 != lane && $0 != .drafts })
        app.commandCenter.destination = .lane(other)

        app.commandCenter.show(failure)

        #expect(app.commandCenter.orderedKeys(for: app.commandCenter.destination).contains(failure.mrKey))
        #expect(app.mergeRequests.selectedKey == failure.mrKey)
    }

    @Test func showStaysOnALaneThatAlreadyListsTheMR() async throws {
        let (app, spy) = await loaded()
        let failure = try await failure(app, spy, 233)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 233 })
        let lane = app.commandCenter.situation(for: mr).lane
        app.commandCenter.destination = .lane(lane)

        app.commandCenter.show(failure)

        #expect(app.commandCenter.destination == .lane(lane))
    }

    @Test func aFailureForAnMRThatLeftTheListCantBeShownButStays() async throws {
        let (app, spy) = await loaded()
        let failure = try await failure(app, spy, 233)
        spy.edit { $0.data.entries.removeAll { $0.detail.iid == 233 } }
        await app.refresh(.automatic)

        #expect(!app.commandCenter.canShow(failure))
        app.commandCenter.show(failure)
        #expect(app.commandCenter.mergeFailures == [failure], "Still listed until you dismiss it")
    }

    @Test func staleCommitKeepsTheDialogOpen() async throws {
        let (app, spy) = await loaded()
        let draft = try draft(app, 233)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 233 })
        mr.headSHA = String(repeating: "f", count: 40)

        #expect(app.commandCenter.startMerge(draft) == nil)
        #expect(app.commandCenter.actionErrors[draft.mrKey]?.contains("New commits") == true)
        #expect(app.commandCenter.mergeFailures.isEmpty, "Shown in the dialog, not as a banner")
        #expect(spy.count("merge") == 0)
    }
}
