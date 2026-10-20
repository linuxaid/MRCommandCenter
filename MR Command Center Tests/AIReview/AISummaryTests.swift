import Foundation
import SwiftData
import Synchronization
import Testing
@testable import MR_Command_Center

struct AISummaryFormatTests {
    @Test func summaryHasAttributionVerdictConcernsMostSevereFirstAndChecks() {
        let body = AICommentFormatter.summary(
            verdict: .needsHumanReview, rationale: "Two issues worth a look.", headSHA: "9c9c9c9c9c9c", promptName: "v1",
            staticSummary: "warnings: No debug output",
            concerns: [
                .init(path: "a.py", lineHint: "42", severity: .low, explanation: "Debug print."),
                .init(path: "a.py", lineHint: "40", severity: .high, explanation: "429s never retried."),
            ]
        )
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines[0] == "_Comment generated via MR Command Center_ 😃 · on-device AI review of `9c9c9c9c` (prompt v1)")
        #expect(body.contains("**Verdict: Needs human review**"))
        #expect(body.contains("Two issues worth a look."))
        let high = body.range(of: "- **high** `a.py:40`")!
        let low = body.range(of: "- **low** `a.py:42`")!
        #expect(high.lowerBound < low.lowerBound)
        #expect(body.contains("Static checks: warnings: No debug output"))
        #expect(body.contains("resolve this thread once addressed"))
    }
}

struct AIOpenConcernAndSummaryTests {
    private func setUp(postingEnabled: Bool = true) async throws -> (AppModel, SpyGitLabClient, TrackedMR, AIReviewRun) {
        let spy = SpyGitLabClient()
        let model = FakeReviewModel()
        model.edit {
            $0.concernsByPath["app/webhooks/delivery.py"] = [
                ConcernResult(lineHint: "42", severity: .medium, explanation: "Leftover debug print."),
                ConcernResult(lineHint: "40", severity: .high, explanation: "429s never retried."),
            ]
        }
        let app = AppModel.testing(gitLab: spy, model: model)
        AccountSettings.current(in: app.modelContainer.mainContext).postCommentsEnabled = postingEnabled
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        app.aiReview.start(mr)
        await app.aiReview.wait(for: mr.key)
        let run = try #require(app.aiReview.latestRun(for: mr.key))
        return (app, spy, mr, run)
    }

    @Test func openCountFollowsDismissAndPost() async throws {
        let (app, _, mr, run) = try await setUp()
        #expect(mr.aiOpenConcerns == 2)
        #expect(MRStatusLine.aiItem(for: mr).title == "AI: likely problem · 2 open")
        #expect(!MRStatusLine.items(for: mr).contains { $0.id == "ai" }, "Reviewed MRs show the verdict as a badge above the title")

        let concerns = run.orderedFiles[0].orderedConcerns
        app.aiReview.setDismissed(concerns[0], true, mr: mr)
        #expect(mr.aiOpenConcerns == 1)

        let diff = try await app.diffs.diff(for: mr)
        let line = try #require(diff.files[0].hunks.flatMap(\.lines).first { $0.newNumber == 40 && $0.kind == .addition })
        _ = try await app.discussions.postAIConcern(concerns[1], body: "x", on: line, in: diff.files[0], of: diff, mr: mr)
        app.aiReview.updateOpenConcerns(for: mr)
        #expect(mr.aiOpenConcerns == 0)
        #expect(MRStatusLine.aiItem(for: mr).title == "AI: likely problem")

        app.aiReview.setDismissed(concerns[0], false, mr: mr)
        #expect(mr.aiOpenConcerns == 1, "Restoring makes it open again")

        mr.headSHA = String(repeating: "f", count: 40)
        #expect(!MRStatusLine.aiItem(for: mr).title.contains("open"), "Outdated reviews don't claim open comments")
    }

    @Test func summaryIsPostedOnceAsAGeneralThreadWithoutDismissedConcerns() async throws {
        let (app, spy, mr, run) = try await setUp()
        app.aiReview.setDismissed(run.orderedFiles[0].orderedConcerns[0], true, mr: mr)
        #expect(app.aiReview.summaryIsWorthPosting(run))

        app.summaryPoster.preview(run, for: mr)
        let draft = try #require(app.summaryPoster.draft)
        #expect(draft.body.hasPrefix("_Comment generated via MR Command Center_ 😃"))
        #expect(!draft.body.contains("Leftover debug print."), "Dismissed concerns are left out")
        #expect(draft.body.contains("`app/webhooks/delivery.py:40`"))

        await app.summaryPoster.post()
        #expect(app.summaryPoster.draft == nil)
        #expect(app.summaryPoster.error == nil)
        #expect(spy.count("createGeneralDiscussion") == 1)
        #expect(spy.state.withLock { $0.lastGeneralBody }?.contains("**Verdict: Likely problem**") == true)
        #expect(run.summaryDiscussionID != nil)
        #expect(run.summaryPostedAt != nil)

        await #expect(throws: CommentPostingError.alreadyPosted) {
            _ = try await app.discussions.postSummary(of: run, body: "again", mr: mr)
        }
        #expect(spy.count("createGeneralDiscussion") == 1)
    }

    @Test func summaryRespectsThePostingSetting() async throws {
        let (app, spy, mr, run) = try await setUp(postingEnabled: false)
        app.summaryPoster.preview(run, for: mr)
        await app.summaryPoster.post()
        #expect(app.summaryPoster.error == CommentPostingError.disabled.localizedDescription)
        #expect(spy.count("createGeneralDiscussion") == 0)
        #expect(run.summaryDiscussionID == nil)
    }

    @Test func cleanReviewsAreNotWorthASummary() async throws {
        let app = AppModel.testing()
        await app.refresh(.automatic)
        let mr = try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == 1880 })
        app.aiReview.start(mr)
        await app.aiReview.wait(for: mr.key)
        let run = try #require(app.aiReview.latestRun(for: mr.key))
        #expect(run.verdictStatus == .looksGood)
        #expect(!app.aiReview.summaryIsWorthPosting(run))
    }
}
