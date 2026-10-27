import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

/// Open comment threads in the brief, and resolving them from the app (#28).
@MainActor
struct OpenThreadsTests {
    private func loaded() async throws -> (AppModel, SpyGitLabClient, TrackedMR, [GitLabDiscussion]) {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let discussions = try await app.discussions.discussions(for: mr)
        return (app, spy, mr, discussions)
    }

    @Test func listsUnresolvedThreadsWithTheOnesWaitingOnYouFirst() async throws {
        let (app, _, mr, discussions) = try await loaded()
        let threads = OpenThread.open(in: discussions, me: app.mergeRequests.username, isMyMR: mr.isAuthor)

        #expect(threads.count == 3, "Resolved threads and plain comments are left out")
        let first = try #require(threads.first)
        #expect(first.waitingOnMe, "Priya answered the mock user's thread")
        #expect(first.location == "backoff.py:12")
        #expect(first.startedBy == "A.J. Reviewer")
        #expect(first.lastReplyBy == "Priya Natarajan")
        #expect(first.noteCount == 2)
        #expect(threads.dropFirst().allSatisfy { !$0.waitingOnMe })
    }

    @Test func generalThreadsSayGeneral() {
        let note = GitLabDiscussion.Note(id: 1, resolvable: true, resolved: false, system: false, body: "Overall question",
                                         author: GitLabUserRef(id: 2, username: "dana", name: "Dana Okafor"))
        let threads = OpenThread.open(in: [GitLabDiscussion(id: "g", individualNote: false, notes: [note])], me: "aj", isMyMR: false)
        #expect(threads.first?.location == "General")
        #expect(threads.first?.path == nil)
        #expect(threads.first?.waitingOnMe == false, "Not your thread, not your MR")
    }

    @Test func resolvingUpdatesGitLabCountsAndActivity() async throws {
        let (app, spy, mr, discussions) = try await loaded()
        let metric = try #require(discussions.first { $0.id == "412-metric" })
        #expect(mr.unresolvedDiscussions == 3)
        #expect(mr.threadsAwaitingMe == 1)

        try await app.discussions.setResolved(metric.id, resolved: true, mr: mr)

        #expect(spy.count("resolve") == 1)
        #expect(mr.unresolvedDiscussions == 2)
        #expect(mr.threadsAwaitingMe == 0, "Nothing is waiting on you any more")
        let cached = try #require(app.discussions.cachedDiscussions(for: mr.key))
        #expect(cached.first { $0.id == metric.id }?.isResolved == true)
        let events = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
        #expect(events.contains { $0.message == "You resolved your thread" })
    }

    @Test func reopeningPutsItBack() async throws {
        let (app, _, mr, _) = try await loaded()
        try await app.discussions.setResolved("412-print", resolved: true, mr: mr)
        try await app.discussions.setResolved("412-print", resolved: false, mr: mr)
        #expect(mr.unresolvedDiscussions == 3)
    }

    @Test func resolvingDoesntNeedThePostCommentsSetting() async throws {
        let (app, _, mr, _) = try await loaded()
        AccountSettings.current(in: app.modelContainer.mainContext).postCommentsEnabled = false
        try await app.discussions.setResolved("412-print", resolved: true, mr: mr)
        #expect(mr.unresolvedDiscussions == 2)
    }

    @Test func forbiddenExplainsTheScope() async throws {
        let (app, spy, mr, _) = try await loaded()
        spy.edit { $0.resolveFailure = .forbidden }
        await #expect(throws: CommentPostingError.resolveNeedsAPIScope) {
            try await app.discussions.setResolved("412-print", resolved: true, mr: mr)
        }
        #expect(mr.unresolvedDiscussions == 3, "Nothing changes locally")
    }

    @Test func commentsModelResolvesAndReportsFailures() async throws {
        let (app, spy, mr, _) = try await loaded()
        let diff = try await app.diffs.diff(for: mr)
        let comments = CommentsModel()
        await comments.load(mr: mr, diff: diff, service: app.discussions)
        let print = try #require(app.discussions.cachedDiscussions(for: mr.key)?.first { $0.id == "412-print" })

        spy.edit { $0.resolveFailure = .offline }
        await comments.setResolved(print, true)
        #expect(comments.resolveErrors[print.id] != nil)

        spy.edit { $0.resolveFailure = nil }
        await comments.setResolved(print, true)
        #expect(comments.resolveErrors[print.id] == nil)
        #expect(mr.unresolvedDiscussions == 2)
    }

    private func addThread(to iid: Int, id: String, spy: SpyGitLabClient, newLine: Int? = 5, oldLine: Int? = nil) {
        let dana = GitLabUserRef(id: 31, username: "dana", name: "Dana Okafor")
        let position = GitLabNotePosition(newPath: "src/a.ts", oldLine: oldLine, newLine: newLine)
        let note = GitLabDiscussion.Note(id: Int.random(in: 1...999_999), resolvable: true, resolved: false, system: false,
                                         body: "New question", author: dana, createdAt: .now, type: "DiffNote", position: position)
        spy.edit { state in
            let index = state.data.entries.firstIndex { $0.detail.iid == iid }!
            state.data.entries[index].discussions.append(GitLabDiscussion(id: id, individualNote: false, notes: [note]))
            state.data.entries[index].bumpUpdatedAt()
        }
    }

    @Test func resolvingCountsThreadsThatArrivedAfterTheCacheFilled() async throws {
        let (app, spy, mr, _) = try await loaded()
        addThread(to: 412, id: "412-new", spy: spy)
        await app.mergeRequests.refresh(.automatic)
        #expect(mr.unresolvedDiscussions == 4)

        try await app.discussions.setResolved("412-print", resolved: true, mr: mr)

        #expect(mr.unresolvedDiscussions == 3, "The new thread still counts")
    }

    @Test func resolvingTheLastThreadLogsWhatItUnblocked() async throws {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        addThread(to: 233, id: "233-last", spy: spy)
        await app.refresh(.automatic)
        let mine = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 233 })
        #expect(mine.unresolvedDiscussions == 1)

        try await app.discussions.setResolved("233-last", resolved: true, mr: mine)

        let kinds = try app.modelContainer.mainContext.fetch(FetchDescriptor<ActivityEvent>())
            .filter { $0.mrKey == mine.key }.map(\.kind)
        #expect(kinds.contains(.threadsResolved))
        #expect(kinds.contains(.readyToMerge), "GitLab's merge status was refetched, so readiness follows")
        #expect(Readiness(mine).isReady)
        #expect(mine.detailedMergeStatus == "mergeable")
        #expect(app.commandCenter.situation(for: mine).lane == .readyToMerge)
    }

    @Test func threadOnARemovedLineOpensAtItsFile() {
        let note = GitLabDiscussion.Note(id: 1, resolvable: true, resolved: false, system: false, body: "Why remove this?",
                                         author: GitLabUserRef(id: 2, username: "dana", name: "Dana Okafor"),
                                         position: GitLabNotePosition(oldPath: "a/old.swift", newPath: "a/old.swift", oldLine: 33))
        let thread = try! #require(OpenThread.open(in: [GitLabDiscussion(id: "r", individualNote: false, notes: [note])],
                                                   me: "aj", isMyMR: false).first)
        #expect(thread.line == nil, "The diff jumps by new-side line; a removed line has none")
        #expect(thread.oldLine == 33)
        #expect(thread.location == "old.swift:33 (removed)")
    }

    @Test func newestActivityFirstAfterTheOnesWaitingOnYou() {
        func thread(_ id: String, hoursAgo: Double) -> GitLabDiscussion {
            GitLabDiscussion(id: id, individualNote: false, notes: [GitLabDiscussion.Note(
                id: 1, resolvable: true, resolved: false, system: false, body: id,
                author: GitLabUserRef(id: 2, username: "dana", name: "Dana"), createdAt: .now.addingTimeInterval(-hoursAgo * 3600))])
        }
        let order = OpenThread.open(in: [thread("old", hoursAgo: 5), thread("new", hoursAgo: 1)], me: "aj", isMyMR: false).map(\.id)
        #expect(order == ["new", "old"])
    }

    @Test func liveClientResolvesWithPUTAndJSON() async throws {
        let transport = StubTransport([.response(status: 200, body: Data(#"{"id":"d1","notes":[]}"#.utf8)),
                                       .response(status: 200, body: Data(#"{"id":"d1","notes":[]}"#.utf8))])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)
        _ = try await client.setDiscussionResolved(projectID: 101, iid: 412, discussionID: "d1", resolved: true)
        _ = try await client.setDiscussionResolved(projectID: 101, iid: 412, discussionID: "d1", resolved: false)

        let sent = transport.requests
        #expect(sent.count == 2)
        #expect(sent[0].httpMethod == "PUT")
        #expect(sent[0].url?.path() == "/api/v4/projects/101/merge_requests/412/discussions/d1")
        let first = try #require(sent[0].httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        let second = try #require(sent[1].httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect(first["resolved"] as? Bool == true)
        #expect(second["resolved"] as? Bool == false)
    }

    @Test func briefModelRemovesResolvedRowsAndKeepsFailedOnes() async throws {
        let (app, spy, mr, _) = try await loaded()
        let model = OpenThreadsModel()
        #expect(!model.hasLoaded)
        await model.load(mr, service: app.discussions, me: app.mergeRequests.username, force: false)
        #expect(model.hasLoaded && model.threads.count == 3)

        let target = try #require(model.threads.first)
        spy.edit { $0.resolveFailure = .offline }
        await model.resolve(target, on: mr, service: app.discussions, me: app.mergeRequests.username)
        #expect(model.threads.contains { $0.id == target.id })
        #expect(model.errors[target.id] != nil)

        spy.edit { $0.resolveFailure = nil }
        await model.resolve(target, on: mr, service: app.discussions, me: app.mergeRequests.username)
        #expect(!model.threads.contains { $0.id == target.id })
        #expect(model.errors[target.id] == nil)
    }

    @Test func briefModelFinishesLoadingWhenNothingIsOpen() async throws {
        let app = AppModel.testing()
        await app.refresh(.automatic)
        let mine = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 233 })
        let model = OpenThreadsModel()
        await model.load(mine, service: app.discussions, me: app.mergeRequests.username, force: true)
        #expect(model.hasLoaded)
        #expect(model.threads.isEmpty, "The card hides instead of spinning forever")
    }

    @Test func whenTheRefetchFailsTheCountsStillFollowTheResolve() async throws {
        let (app, spy, mr, _) = try await loaded()
        #expect(mr.threadsAwaitingMe == 1)
        spy.edit { $0.discussionsFailure = .offline }

        try await app.discussions.setResolved("412-metric", resolved: true, mr: mr)

        #expect(mr.unresolvedDiscussions == 2)
        #expect(mr.threadsAwaitingMe == 0, "The thread waiting on you is gone even without a fresh fetch")
        #expect(app.discussions.cachedDiscussions(for: mr.key)?.first { $0.id == "412-metric" }?.isResolved == true)
    }

    @Test func resolvingInTheDiffShowsInTheBrief() async throws {
        let (app, _, mr, _) = try await loaded()
        let model = OpenThreadsModel()
        await model.load(mr, service: app.discussions, me: app.mergeRequests.username, force: false)
        #expect(model.threads.count == 3)

        // The diff resolves through the same service and cache...
        try await app.discussions.setResolved("412-print", resolved: true, mr: mr)
        // ...and the brief reloads (its task is keyed on the thread counts) from that cache.
        await model.load(mr, service: app.discussions, me: app.mergeRequests.username, force: false)

        #expect(model.threads.count == 2)
        #expect(!model.threads.contains { $0.id == "412-print" })
    }

    @Test func resolvingInTheBriefPicksUpThreadsThatArrived() async throws {
        let (app, spy, mr, _) = try await loaded()
        let model = OpenThreadsModel()
        await model.load(mr, service: app.discussions, me: app.mergeRequests.username, force: false)
        addThread(to: 412, id: "412-new", spy: spy)

        await model.resolve(try #require(model.threads.first { $0.id == "412-print" }), on: mr,
                            service: app.discussions, me: app.mergeRequests.username)

        #expect(model.threads.contains { $0.id == "412-new" })
        #expect(model.threads.count == mr.unresolvedDiscussions)
    }
}
