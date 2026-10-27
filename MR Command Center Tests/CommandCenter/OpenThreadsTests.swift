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
        #expect(events.contains { $0.message == "You resolved A.J.'s thread" })
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
}
