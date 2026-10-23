import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

struct DiscussionDecodingTests {
    @Test func decodesDiffNotePositionAndBody() throws {
        let discussions = try HTTPClient.decode([GitLabDiscussion].self, from: Fixture.data("gitlab_discussions"), decoder: .gitLab)
        let thread = discussions[0]
        let position = try #require(thread.position)
        #expect(position.newLine == 42)
        #expect(position.oldLine == nil)
        #expect(position.headSha == "8f3c2a1d9e7b6c5a4f3e2d1c0b9a8f7e6d5c4b3a")
        #expect(position.positionType == "text")
        #expect(thread.userNotes.map(\.body) == ["should this retry forever?", "no, capped at 5"])
        #expect(thread.userNotes.first?.author?.username == "dana")
        #expect(thread.userNotes.first?.createdAt != nil)
        #expect(discussions[2].userNotes.isEmpty, "System notes are filtered out")
    }

    @Test func encodesNewDiscussionRequestInGitLabShape() throws {
        let refs = DiffRefs(baseSHA: "b", startSHA: "s", headSHA: "h")
        let request = NewDiffDiscussionRequest(body: "Nit", refs: refs, oldPath: "a.py", newPath: "a.py", oldLine: nil, newLine: 7)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let json = try #require(JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any])
        let position = try #require(json["position"] as? [String: Any])
        #expect(json["body"] as? String == "Nit")
        #expect(position["position_type"] as? String == "text")
        #expect(position["base_sha"] as? String == "b")
        #expect(position["start_sha"] as? String == "s")
        #expect(position["head_sha"] as? String == "h")
        #expect(position["new_line"] as? Int == 7)
        #expect(position["old_line"] == nil, "Unset lines are omitted, not sent as null")
    }
}

struct ThreadPlacementTests {
    private func mockDiff() -> MRDiff {
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == 412 }!
        return MRDiff(headSHA: entry.detail.sha!, diffs: entry.diffs, changesCount: "4", fetchedAt: .now,
                      refs: DiffRefs(baseSHA: "0", startSHA: "0", headSHA: entry.detail.sha!))
    }

    private func threads() -> [GitLabDiscussion] {
        MockGitLabData.sample.entries.first { $0.detail.iid == 412 }!.discussions
    }

    @Test func placesThreadsOnAddedRemovedAndNewFileLines() throws {
        let diff = mockDiff()
        let placement = ThreadPlacement.place(threads(), in: diff)
        let delivery = diff.files[0]
        let deliveryThreads = placement.threads(for: delivery.id)

        let byText = Dictionary(uniqueKeysWithValues: deliveryThreads.byLine.flatMap { lineID, threads in
            threads.map { ($0.id, delivery.hunks.flatMap(\.lines).first { $0.id == lineID }!) }
        })
        #expect(byText["412-429"]?.kind == .addition)
        #expect(byText["412-429"]?.newNumber == 40)
        #expect(byText["412-print"]?.text.contains("print(") == true)
        #expect(byText["412-oldlog"]?.kind == .deletion)
        #expect(byText["412-oldlog"]?.oldNumber == 33)

        #expect(deliveryThreads.outdated.map(\.id) == ["412-outdated"])
        #expect(placement.threads(for: diff.files[1].id).byLine.values.flatMap { $0 }.map(\.id) == ["412-backoff"])
        #expect(placement.orphaned.isEmpty)
        #expect(!placement.files.values.flatMap(\.all).contains { $0.id == "412-general" }, "General threads aren't diff threads")
    }

    @Test func linesOutsideHunksAndMissingFiles() {
        let diff = mockDiff()
        let head = diff.headSHA
        func thread(_ id: String, path: String, new: Int) -> GitLabDiscussion {
            GitLabDiscussion(id: id, notes: [.init(id: 1, resolvable: true, resolved: false, system: false, body: "x",
                                                    position: GitLabNotePosition(headSha: head, oldPath: path, newPath: path, newLine: new))])
        }
        let placement = ThreadPlacement.place([
            thread("off", path: "app/webhooks/delivery.py", new: 500),
            thread("gone", path: "app/removed_from_diff.py", new: 1),
        ], in: diff)
        #expect(placement.threads(for: diff.files[0].id).offDiff.map(\.id) == ["off"])
        #expect(placement.orphaned.map(\.id) == ["gone"])
    }

    @Test func matchesRenamedFilesByOldPath() {
        let renamed = DiffFile(GitLabDiff(oldPath: "old/a.ts", newPath: "new/a.ts", diff: "@@ -1 +1 @@\n-x\n+y\n",
                                          newFile: false, renamedFile: true, deletedFile: false), index: 0)
        #expect(ThreadPlacement.matches(GitLabNotePosition(oldPath: "old/a.ts", newPath: "old/a.ts"), renamed))
        #expect(ThreadPlacement.matches(GitLabNotePosition(oldPath: "x", newPath: "new/a.ts"), renamed))
    }

    @Test func newCommentPositionsFollowGitLabRules() throws {
        let diff = mockDiff()
        let file = diff.files[0]
        let refs = try #require(diff.refs)
        let lines = file.hunks.flatMap(\.lines)
        let added = try #require(lines.first { $0.kind == .addition })
        let removed = try #require(lines.first { $0.kind == .deletion })
        let context = try #require(lines.first { $0.kind == .context })

        let a = ThreadPlacement.newDiscussion(body: "b", line: added, file: file, refs: refs).position
        #expect(a.newLine == added.newNumber && a.oldLine == nil)
        let r = ThreadPlacement.newDiscussion(body: "b", line: removed, file: file, refs: refs).position
        #expect(r.oldLine == removed.oldNumber && r.newLine == nil)
        let c = ThreadPlacement.newDiscussion(body: "b", line: context, file: file, refs: refs).position
        #expect(c.oldLine == context.oldNumber && c.newLine == context.newNumber)
        #expect(a.headSha == refs.headSHA && a.positionType == "text")
    }

    @Test func roundTripsAPostedPositionBackOntoTheSameLine() throws {
        let diff = mockDiff()
        let file = diff.files[0]
        for line in file.hunks.flatMap(\.lines) where line.kind != .noNewline {
            let request = ThreadPlacement.newDiscussion(body: "b", line: line, file: file, refs: diff.refs!)
            #expect(ThreadPlacement.line(for: request.position, in: file)?.id == line.id)
        }
    }
}

struct CommentPostingTests {
    private func setUp(postingEnabled: Bool = true) async throws -> (AppModel, SpyGitLabClient, TrackedMR, MRDiff) {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        AccountSettings.current(in: model.modelContainer.mainContext).postCommentsEnabled = postingEnabled
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let diff = try await model.diffs.diff(for: mr)
        return (model, spy, mr, diff)
    }

    @Test func diffRefsComeFromTheMRDetail() async throws {
        let (model, _, mr, diff) = try await setUp()
        #expect(mr.diffRefs != nil)
        #expect(diff.refs == mr.diffRefs)
        withExtendedLifetime(model) {}
    }

    @Test func postingIsBlockedWhenDisabled() async throws {
        let (model, spy, mr, diff) = try await setUp(postingEnabled: false)
        let file = diff.files[0]
        let line = file.hunks[0].lines[1]
        await #expect(throws: CommentPostingError.disabled) {
            _ = try await model.discussions.createThread(on: line, in: file, of: diff, body: "Hi", mr: mr)
        }
        #expect(spy.count("createDiscussion") == 0)
    }

    @Test func rejectsEmptyComments() async throws {
        let (model, _, mr, diff) = try await setUp()
        await #expect(throws: CommentPostingError.emptyBody) {
            _ = try await model.discussions.createThread(on: diff.files[0].hunks[0].lines[0], in: diff.files[0], of: diff, body: "  \n", mr: mr)
        }
    }

    @Test func forbiddenMeansMissingAPIScope() async throws {
        let (model, spy, mr, diff) = try await setUp()
        spy.edit { $0.postFailure = .forbidden }
        await #expect(throws: CommentPostingError.needsAPIScope) {
            _ = try await model.discussions.createThread(on: diff.files[0].hunks[0].lines[1], in: diff.files[0], of: diff, body: "Hi", mr: mr)
        }
    }

    @Test func composerPostsThreadThatAppearsOnTheLine() async throws {
        let (model, spy, mr, diff) = try await setUp()
        let comments = CommentsModel()
        await comments.load(mr: mr, diff: diff, service: model.discussions)
        let unresolvedBefore = mr.unresolvedDiscussions
        let file = diff.files[0]
        let line = try #require(file.hunks[0].lines.first { $0.kind == .addition })
        let target = CommentTarget.line(fileID: file.id, lineID: line.id)

        comments.open(target)
        comments.drafts[target] = "  Why do we need `time` here?  "
        await comments.submit(target)

        #expect(comments.postErrors[target] == nil)
        #expect(comments.activeTarget == nil)
        #expect(comments.drafts[target] == nil)
        let posted = try #require(comments.threads(fileID: file.id, lineID: line.id).first)
        #expect(posted.userNotes.first?.body == "Why do we need `time` here?")
        #expect(mr.unresolvedDiscussions == unresolvedBefore + 1)

        let request = try #require(spy.state.withLock { $0.lastDiscussionRequest })
        #expect(request.position.newLine == line.newNumber)
        #expect(request.position.headSha == diff.headSHA)
    }

    @Test func replyAppendsToTheThread() async throws {
        let (model, spy, mr, diff) = try await setUp()
        let comments = CommentsModel()
        await comments.load(mr: mr, diff: diff, service: model.discussions)
        let target = CommentTarget.reply(discussionID: "412-print")
        comments.drafts[target] = "Removed in the next push."
        await comments.submit(target)

        #expect(spy.count("reply") == 1)
        let thread = try #require(comments.placement.files.values.flatMap(\.all).first { $0.id == "412-print" })
        #expect(thread.userNotes.last?.body == "Removed in the next push.")
    }

    @Test func failedPostKeepsTheDraft() async throws {
        let (model, spy, mr, diff) = try await setUp()
        spy.edit { $0.postFailure = .offline }
        let comments = CommentsModel()
        await comments.load(mr: mr, diff: diff, service: model.discussions)
        let target = CommentTarget.reply(discussionID: "412-print")
        comments.drafts[target] = "Important thought"
        await comments.submit(target)

        #expect(comments.drafts[target] == "Important thought")
        #expect(comments.postErrors[target] != nil)
    }
}

struct LiveCommentRequestTests {
    @Test func createsDiscussionWithPOSTAndJSON() async throws {
        let transport = StubTransport([.response(status: 201, body: Data(#"{"id":"abc","notes":[]}"#.utf8))])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)
        let request = NewDiffDiscussionRequest(body: "Hi", refs: DiffRefs(baseSHA: "b", startSHA: "s", headSHA: "h"),
                                               oldPath: "a", newPath: "a", oldLine: 3, newLine: 4)
        _ = try await client.createDiffDiscussion(projectID: 101, iid: 412, request: request)

        let sent = try #require(transport.requests.first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.path() == "/api/v4/projects/101/merge_requests/412/discussions")
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try #require(sent.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        #expect((body["position"] as? [String: Any])?["old_line"] as? Int == 3)
    }

    @Test func repliesToDiscussionNotesEndpoint() async throws {
        let transport = StubTransport([.response(status: 201, body: Data(#"{"id":9,"body":"ok"}"#.utf8))])
        let client = LiveGitLabClient(baseURL: URL(string: "https://gitlab.example.com")!, token: "t", transport: transport)
        let note = try await client.replyToDiscussion(projectID: 1, iid: 2, discussionID: "6a9c1750", body: "ok")
        #expect(note.body == "ok")
        #expect(transport.requests.first?.url?.path() == "/api/v4/projects/1/merge_requests/2/discussions/6a9c1750/notes")
    }
}

/// Resolved threads used to start folded, and outdated ones sat in a folded group on top,
/// so a resolved thread needed two clicks to see (issue #19).
struct ThreadExpansionTests {
    private func resolvedThreads() -> [GitLabDiscussion] {
        MockGitLabData.sample.entries.first { $0.detail.iid == 412 }!.discussions.filter(\.isResolved)
    }

    @Test func resolvedThreadsStartOpenAndFoldOnToggle() throws {
        let comments = CommentsModel()
        let threads = resolvedThreads()
        try #require(threads.count >= 2)
        #expect(threads.allSatisfy(comments.isExpanded))

        comments.toggleExpanded(threads[0])
        #expect(!comments.isExpanded(threads[0]))
        #expect(comments.isExpanded(threads[1]), "Folding one thread leaves the others open")

        comments.toggleExpanded(threads[0])
        #expect(comments.isExpanded(threads[0]))
    }

    @Test func outdatedAndOffDiffGroupsStartOpenPerFile() {
        let comments = CommentsModel()
        let outdated = ThreadGroupID(fileID: "0:a.py", kind: .outdated)
        let offDiff = ThreadGroupID(fileID: "0:a.py", kind: .offDiff)
        let otherFile = ThreadGroupID(fileID: "1:b.py", kind: .outdated)
        #expect(comments.isGroupExpanded(outdated))
        #expect(comments.isGroupExpanded(offDiff))

        comments.setGroupExpanded(outdated, false)
        #expect(!comments.isGroupExpanded(outdated))
        #expect(comments.isGroupExpanded(offDiff))
        #expect(comments.isGroupExpanded(otherFile))

        comments.setGroupExpanded(outdated, true)
        #expect(comments.isGroupExpanded(outdated))
    }

    /// The mock's resolved thread left on an earlier commit lands in the outdated group,
    /// which now shows it without any clicks.
    @Test func resolvedOutdatedThreadIsVisibleWithoutClicks() throws {
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == 412 }!
        let diff = MRDiff(headSHA: entry.detail.sha!, diffs: entry.diffs, changesCount: nil, fetchedAt: .now,
                          refs: DiffRefs(baseSHA: "0", startSHA: "0", headSHA: entry.detail.sha!))
        let placement = ThreadPlacement.place(entry.discussions, in: diff)
        let file = try #require(diff.files.first { $0.newPath == "app/webhooks/delivery.py" })
        let outdated = try #require(placement.threads(for: file.id).outdated.first)
        #expect(outdated.isResolved)

        let comments = CommentsModel()
        #expect(comments.isGroupExpanded(ThreadGroupID(fileID: file.id, kind: .outdated)))
        #expect(comments.isExpanded(outdated))
    }
}
