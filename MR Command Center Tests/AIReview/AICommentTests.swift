import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

struct AIConcernPlacementTests {
    private var diff: MRDiff {
        let entry = MockGitLabData.sample.entries.first { $0.detail.iid == 412 }!
        return MRDiff(headSHA: entry.detail.sha!, diffs: entry.diffs, changesCount: "4", fetchedAt: .now,
                      refs: DiffRefs(baseSHA: "0", startSHA: "0", headSHA: entry.detail.sha!))
    }

    @Test func placesConcernsOnTheirNewSideLine() throws {
        let diff = diff
        let onPrint = UUID(), quoted = UUID(), outside = UUID(), otherFile = UUID()
        let placement = AIConcernPlacement.place([
            AIConcernRef(id: onPrint, path: "app/webhooks/delivery.py", line: 42),
            AIConcernRef(id: quoted, path: "app/webhooks/delivery.py", line: nil),
            AIConcernRef(id: outside, path: "app/webhooks/delivery.py", line: 900),
            AIConcernRef(id: otherFile, path: "not/in/diff.py", line: 1),
        ], in: diff)

        let file = diff.files[0]
        let lineID = try #require(placement.byLine[file.id]?.first { $0.value.contains(onPrint) }?.key)
        let line = try #require(file.hunks.flatMap(\.lines).first { $0.id == lineID })
        #expect(line.text.contains("print("))
        #expect(Set(placement.unplaced[file.id] ?? []) == [quoted, outside])
        #expect(placement.count(fileID: file.id) == 3)
        #expect(!placement.byLine.values.flatMap(\.values).joined().contains(otherFile))
    }

    @Test func attributionIsAlwaysPresent() {
        let body = AICommentFormatter.body(severity: .high, explanation: "  429s are never retried. ")
        #expect(body.hasPrefix("_Comment generated via MR Command Center_ 😃"))
        #expect(body.contains("severity: **high**"))
        #expect(body.hasSuffix("429s are never retried."))
        #expect(AICommentFormatter.ensureAttribution(body) == body)
        #expect(AICommentFormatter.ensureAttribution("Edited text").hasPrefix("_Comment generated via MR Command Center_ 😃\n\nEdited text"))
    }
}

struct AICommentPostingTests {
    private func setUp(postingEnabled: Bool = true) async throws -> (AppModel, SpyGitLabClient, TrackedMR, MRDiff, CommentsModel) {
        let spy = SpyGitLabClient()
        let model = FakeReviewModel()
        model.edit {
            $0.concernsByPath["app/webhooks/delivery.py"] = [
                ConcernResult(lineHint: "42", severity: .medium, explanation: "Leftover debug print."),
                ConcernResult(lineHint: "time.sleep(delay)", severity: .low, explanation: "Blocking sleep."),
            ]
        }
        let app = AppModel.testing(gitLab: spy, model: model)
        AccountSettings.current(in: app.modelContainer.mainContext).postCommentsEnabled = postingEnabled
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.mergeRequests.first { $0.iid == 412 })
        app.aiReview.start(mr)
        await app.aiReview.wait(for: mr.key)
        let diff = try await app.diffs.diff(for: mr)
        let comments = CommentsModel()
        await comments.load(mr: mr, diff: diff, service: app.discussions)
        comments.showAI(app.aiReview.latestRun(for: mr.key), in: diff)
        return (app, spy, mr, diff, comments)
    }

    private func printConcern(_ comments: CommentsModel, _ diff: MRDiff) throws -> (ConcernRecord, DiffLine.ID) {
        let file = diff.files[0]
        let (lineID, ids) = try #require(comments.aiPlacement.byLine[file.id]?.first)
        let concern = try #require(comments.aiConcerns[ids[0]])
        return (concern, lineID)
    }

    @Test func showsTheRunForThisHeadOnly() async throws {
        let (app, _, mr, diff, comments) = try await setUp()
        #expect(comments.aiConcerns.count == 2)
        #expect(comments.unplacedAIConcerns(fileID: diff.files[0].id).first?.lineHint == "time.sleep(delay)")

        var newer = diff
        newer = MRDiff(headSHA: String(repeating: "f", count: 40), diffs: [], changesCount: nil, fetchedAt: .now)
        comments.showAI(app.aiReview.latestRun(for: mr.key), in: newer)
        #expect(comments.aiConcerns.isEmpty, "A run for an older commit isn't shown inline")
    }

    @Test func previewPostsAnAttributedCommentOnTheLineOnce() async throws {
        let (app, spy, _, diff, comments) = try await setUp()
        let (concern, lineID) = try printConcern(comments, diff)

        let threadsBefore = comments.threads(fileID: diff.files[0].id, lineID: lineID).count
        comments.previewPost(concern, fileID: diff.files[0].id, lineID: lineID)
        #expect(comments.aiPostDraft?.body.contains("Comment generated via MR Command Center") == true)

        // Even if the user deletes the attribution while editing, it's put back.
        comments.aiPostDraft?.body = "Please drop this print."
        await comments.postAIDraft()

        #expect(comments.aiPostDraft == nil)
        #expect(comments.aiPostError == nil)
        let request = try #require(spy.state.withLock { $0.lastDiscussionRequest })
        #expect(request.body.hasPrefix("_Comment generated via MR Command Center_ 😃"))
        #expect(request.body.hasSuffix("Please drop this print."))
        #expect(request.position.newLine == 42)
        #expect(concern.postedDiscussionID != nil)
        #expect(concern.postedAt != nil)

        // The posted thread now shows as a normal GitLab thread on the same line.
        #expect(comments.threads(fileID: diff.files[0].id, lineID: lineID).count == threadsBefore + 1)

        await #expect(throws: CommentPostingError.alreadyPosted) {
            _ = try await app.discussions.postAIConcern(concern, body: "again", on: diff.files[0].hunks[1].lines[0],
                                                        in: diff.files[0], of: diff, mr: app.mergeRequests.mergeRequests.first { $0.iid == 412 }!)
        }
        #expect(spy.count("createDiscussion") == 1)
    }

    @Test func nothingIsPostedWhenPostingIsOff() async throws {
        let (_, spy, _, diff, comments) = try await setUp(postingEnabled: false)
        let (concern, lineID) = try printConcern(comments, diff)
        comments.previewPost(concern, fileID: diff.files[0].id, lineID: lineID)
        #expect(!comments.isPostingEnabled)
        await comments.postAIDraft()
        #expect(comments.aiPostError == CommentPostingError.disabled.localizedDescription)
        #expect(spy.count("createDiscussion") == 0)
        #expect(concern.postedDiscussionID == nil)
    }
}
