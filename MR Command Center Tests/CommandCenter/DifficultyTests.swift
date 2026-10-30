import Foundation
import SwiftData
import Testing
@testable import MR_Command_Center

/// Issue #36: a 1–10 review difficulty per MR, mostly from rules, nudged by the on-device model.
struct DifficultyRulesTests {
    private func file(_ path: String, added: Int = 0, removed: Int = 0, lines: [String]? = nil,
                      new: Bool = false, renamed: Bool = false, deleted: Bool = false, generated: Bool = false) -> GitLabDiff {
        let body = lines ?? (Array(repeating: "-old", count: removed) + Array(repeating: "+let value = 1", count: added))
        let oldCount = body.count { !$0.hasPrefix("+") }
        let newCount = body.count { !$0.hasPrefix("-") }
        let header = "@@ -1,\(oldCount) +1,\(newCount) @@\n"
        return GitLabDiff(oldPath: path, newPath: path, diff: body.isEmpty ? "" : header + body.joined(separator: "\n") + "\n",
                          newFile: new, renamedFile: renamed, deletedFile: deleted, generatedFile: generated)
    }

    private func facts(_ files: [GitLabDiff], changesCount: String? = nil) -> DiffFacts {
        DiffFacts(MRDiff(headSHA: "abc", diffs: files, changesCount: changesCount, fetchedAt: .now))
    }

    private func score(_ files: [GitLabDiff], open: Int = 0, threads: Int = 0, nudge: DifficultyNudge? = nil) -> Difficulty {
        Difficulty(facts: facts(files), openThreads: open, threads: threads, nudge: nudge)
    }

    @Test func aTinyChangeIsAOne() {
        let difficulty = score([file("Sources/App/Greeting.swift", added: 3, removed: 2)])
        #expect(difficulty.score == 1)
        #expect(difficulty.reasons.first == "5 lines in 1 file")
        #expect(difficulty.reasons.contains("no tests changed"))
    }

    @Test func moreLinesAndFilesScoreHigher() {
        let small = score([file("App/A.swift", added: 40)])
        let medium = score((0..<5).map { file("App/F\($0).swift", added: 60) })
        let large = score((0..<20).map { file("App/F\($0).swift", added: 60) })
        #expect(small.score < medium.score)
        #expect(medium.score < large.score)
        #expect(large.reasons.first == "1,200 lines in 20 files")
    }

    @Test func linePointsTopOutAtAThousandLines() {
        let thousand = Difficulty(facts: DiffFacts(linesChanged: 1_000, fileCount: 1), openThreads: 0, threads: 0)
        let huge = Difficulty(facts: DiffFacts(linesChanged: 50_000, fileCount: 1), openThreads: 0, threads: 0)
        let quiet = Difficulty(facts: DiffFacts(linesChanged: 19, fileCount: 1), openThreads: 0, threads: 0)
        #expect(thousand.score == 5) // 4 points
        #expect(huge.score == thousand.score)
        #expect(quiet.score == 1)
    }

    @Test func everySignalAtItsMaximumIsATen() {
        let facts = DiffFacts(linesChanged: 5_000, fileCount: 40, topLevelFolders: 5, riskKinds: [.migration, .ci, .build],
                              changesSource: true, changesTests: false)
        let difficulty = Difficulty(facts: facts, openThreads: 6, threads: 8)
        #expect(difficulty.score == 10)
        #expect(difficulty.word == "Hard")
    }

    @Test func generatedAndLockFilesAreNotCounted() {
        let facts = facts([
            file("App/Feature.swift", added: 10),
            file("package-lock.json", added: 4_000),
            file("Package.resolved", added: 80),
            file("Gen/Api.swift", added: 900, generated: true),
        ])
        #expect(facts.linesChanged == 10)
        #expect(facts.fileCount == 1)
        #expect(facts.skippedFiles == 3)
        let difficulty = Difficulty(facts: facts, openThreads: 0, threads: 0)
        #expect(difficulty.score == 1)
        #expect(difficulty.reasons.contains("3 generated or lock files not counted"))
    }

    @Test func riskyFilesAddAPointEachUpToTwo() {
        #expect(RiskKind.of("db/migrate/20261030_add_users.rb") == .migration)
        #expect(RiskKind.of("schema/001_init.sql") == .migration)
        #expect(RiskKind.of(".gitlab-ci.yml") == .ci)
        #expect(RiskKind.of(".github/workflows/build.yml") == .ci)
        #expect(RiskKind.of("Package.swift") == .build)
        #expect(RiskKind.of("App.xcodeproj/project.pbxproj") == .build)
        #expect(RiskKind.of("Sources/Auth/TokenStore.swift") == .security)
        #expect(RiskKind.of("Sources/Login/LoginView.swift") == .security)
        #expect(RiskKind.of("deploy/terraform/main.tf") == .infra)
        #expect(RiskKind.of("Dockerfile") == .infra)
        #expect(RiskKind.of("Sources/Authors/AuthorList.swift") == nil)
        #expect(RiskKind.of("Sources/App/ContentView.swift") == nil)

        let base = Difficulty(facts: DiffFacts(linesChanged: 100, fileCount: 3), openThreads: 0, threads: 0)
        let one = Difficulty(facts: DiffFacts(linesChanged: 100, fileCount: 3, riskKinds: [.migration]), openThreads: 0, threads: 0)
        let three = Difficulty(facts: DiffFacts(linesChanged: 100, fileCount: 3, riskKinds: [.migration, .ci, .security]),
                               openThreads: 0, threads: 0)
        #expect(one.score == base.score + 1)
        #expect(three.score == base.score + 2)
        #expect(one.reasons.contains("touches a DB migration"))
    }

    @Test func changingTestsAlongsideCodeTakesAPointOff() {
        let withoutTests = score([file("App/Cart.swift", added: 150), file("App/Price.swift", added: 150)])
        let withTests = score([file("App/Cart.swift", added: 150), file("App/CartTests.swift", added: 150)])
        #expect(withTests.score == withoutTests.score - 1)
        #expect(withTests.reasons.contains("tests changed too"))
        #expect(withoutTests.reasons.contains("no tests changed"))
    }

    @Test func foldersAcrossTheCodebaseAddUpToOnePoint() {
        let facts = facts([file("api/a.swift", added: 1), file("web/b.swift", added: 1), file("README.md", added: 1)])
        #expect(facts.topLevelFolders == 3)
        let one = Difficulty(facts: DiffFacts(linesChanged: 100, fileCount: 3, topLevelFolders: 1), openThreads: 0, threads: 0)
        let many = Difficulty(facts: DiffFacts(linesChanged: 100, fileCount: 3, topLevelFolders: 6), openThreads: 0, threads: 0)
        #expect(many.score == one.score + 1)
        #expect(many.reasons.contains("spans 6 top-level folders"))
    }

    @Test func docsCommentsRenamesAndDeletionsAreCappedAtTwo() {
        let deletions = score((0..<30).map { file("Old/F\($0).swift", removed: 200, deleted: true) })
        #expect(deletions.score == 2)
        #expect(deletions.reasons.contains("only docs, comments, renames, or deletions"))

        let docs = score([file("docs/guide.md", added: 900), file("CHANGELOG.md", added: 300)])
        #expect(docs.score <= 2)

        let comments = score([file("App/Cart.swift", lines: Array(repeating: "+/// Explains the cart.", count: 400)
                                                          + ["+", "-// old note", "+# heading comment"])])
        #expect(comments.score <= 2)

        // `#if` is code, not a comment.
        let code = facts([file("App/Cart.swift", lines: ["+#if DEBUG", "+print(1)", "+#endif"])])
        #expect(!code.isSkimOnly)

        // Even the model can't push skim work past the cap.
        let nudged = score([file("docs/guide.md", added: 900)], nudge: DifficultyNudge(feel: .harder, reason: ""))
        #expect(nudged.score == 2)
    }

    @Test func openThreadsAddUpToOnePoint() {
        let facts = DiffFacts(linesChanged: 100, fileCount: 3)
        let quiet = Difficulty(facts: facts, openThreads: 0, threads: 0)
        let busy = Difficulty(facts: facts, openThreads: 4, threads: 12)
        #expect(busy.score == quiet.score + 1)
        #expect(busy.reasons.contains("4 open threads"))
    }

    @Test func theModelMovesTheScoreByOneAtMost() {
        let facts = DiffFacts(linesChanged: 300, fileCount: 6)
        let rules = Difficulty(facts: facts, openThreads: 0, threads: 0)
        let harder = Difficulty(facts: facts, openThreads: 0, threads: 0,
                                nudge: DifficultyNudge(feel: .harder, reason: "It changes locking."))
        let simpler = Difficulty(facts: facts, openThreads: 0, threads: 0, nudge: DifficultyNudge(feel: .simpler, reason: ""))
        let same = Difficulty(facts: facts, openThreads: 0, threads: 0, nudge: DifficultyNudge(feel: .aboutRight, reason: ""))
        #expect(harder.score == rules.score + 1)
        #expect(harder.ruleScore == rules.score)
        #expect(simpler.score == rules.score - 1)
        #expect(same.score == rules.score)
        #expect(harder.reasons.last == "Apple model: harder than it looks. It changes locking.")

        // Never outside 1...10.
        let tiny = Difficulty(facts: DiffFacts(linesChanged: 1, fileCount: 1), openThreads: 0, threads: 0,
                              nudge: DifficultyNudge(feel: .simpler, reason: ""))
        #expect(tiny.score == 1)
    }

    @Test func hoverTextNamesTheWordAndTheReasons() {
        let difficulty = Difficulty(facts: DiffFacts(linesChanged: 612, fileCount: 9, riskKinds: [.migration], changesSource: true),
                                    openThreads: 0, threads: 0)
        #expect(difficulty.explanation.hasPrefix("Difficulty \(difficulty.score) of 10 (\(difficulty.word)): 612 lines in 9 files · "))
        #expect(difficulty.explanation.contains("touches a DB migration · no tests changed"))
        #expect(Difficulty.hue(for: 1) > Difficulty.hue(for: 5))
        #expect(Difficulty.hue(for: 5) > Difficulty.hue(for: 10))
        #expect(Difficulty.hue(for: 10) == 0)
    }

    @Test func overflowingDiffsUseGitLabsFileCount() {
        let facts = facts([file("App/A.swift", added: 10), file("App/B.swift", added: 10)], changesCount: "1000+")
        #expect(facts.fileCount == 1_000)
        #expect(!facts.isSkimOnly)
    }

    @Test func thePromptSummarizesFilesWithSafeQuotes() {
        let diff = MRDiff(headSHA: "abc", diffs: [
            file("App/Cart.swift", lines: ["+let label = \"Total\"", "+", "-old()"]),
            file("yarn.lock", added: 500),
        ], changesCount: nil, fetchedAt: .now)
        let prompt = DifficultyPrompt.prompt(title: "Cart totals", diff: diff, ruleScore: 3)
        #expect(prompt.contains("Title: Cart totals"))
        #expect(prompt.contains("- App/Cart.swift (modified, +2 -1)"))
        #expect(prompt.contains("+ let label = 'Total'"))
        #expect(!prompt.contains("\""))
        #expect(!prompt.contains("yarn.lock"))
    }
}

@MainActor
struct DifficultyServiceTests {
    private func mr(_ app: AppModel, _ iid: Int) throws -> TrackedMR {
        try #require(app.mergeRequests.trackedMergeRequests.first { $0.iid == iid })
    }

    @Test func everyOpenMRIsScoredAfterARefreshWithoutExtraDiffRequests() async throws {
        let spy = SpyGitLabClient()
        let app = AppModel.testing(gitLab: spy)
        await app.refresh(.automatic)
        let mrs = app.mergeRequests.trackedMergeRequests
        #expect(!mrs.isEmpty)
        for mr in mrs {
            let difficulty = try #require(mr.difficulty, "!\(mr.iid)")
            #expect(Difficulty.range.contains(difficulty.score))
        }
        #expect(mrs.contains { $0.isAuthor && $0.difficulty != nil })
        // The static checks already fetched each diff; the score reuses it.
        #expect(spy.count("diffs") == mrs.count)

        await app.refresh(.automatic)
        #expect(spy.count("diffs") == mrs.count)
    }

    @Test func theModelNudgesEachMROncePerCommit() async throws {
        let model = FakeReviewModel()
        model.edit { $0.difficultyNudge = DifficultyNudge(feel: .harder, reason: "Tricky.") }
        let app = AppModel.testing(model: model)
        await app.refresh(.automatic)
        await app.difficulty.waitForNudges()
        let count = app.mergeRequests.trackedMergeRequests.count
        #expect(model.difficultyCalls.count == count)

        let mr = try mr(app, 412)
        let difficulty = try #require(mr.difficulty)
        #expect(difficulty.nudge?.feel == .harder)
        #expect(difficulty.score == min(10, difficulty.ruleScore + 1) || difficulty.reasons.contains("only docs, comments, renames, or deletions"))
        #expect(model.difficultyCalls.first?.instructions.contains("single quotes") == true)

        await app.refresh(.automatic)
        await app.difficulty.waitForNudges()
        #expect(model.difficultyCalls.count == count)
    }

    @Test func withoutTheModelTheRulesScoreStandsAlone() async throws {
        let unavailable = AppModel.testing(modelStatus: .appleIntelligenceNotEnabled)
        await unavailable.refresh(.automatic)
        await unavailable.difficulty.waitForNudges()
        let mr = try mr(unavailable, 412)
        #expect(mr.difficulty?.nudge == nil)
        #expect(mr.difficulty?.score == mr.difficulty?.ruleScore)

        let model = FakeReviewModel()
        model.edit { $0.difficultyNudge = nil }
        let failing = AppModel.testing(model: model)
        await failing.refresh(.automatic)
        await failing.difficulty.waitForNudges()
        let failed = try self.mr(failing, 412)
        #expect(failed.difficulty?.nudge == nil)
        #expect(failed.difficultyNudgeSHA == failed.headSHA) // not asked again at this commit
    }

    @Test func aNewCommitIsScoredAgain() async throws {
        let app = AppModel.testing()
        await app.refresh(.automatic)
        let mr = try mr(app, 412)
        #expect(mr.difficulty != nil)
        mr.headSHA = "new-head"
        #expect(mr.difficulty == nil)
        #expect(app.difficulty.needsFacts(mr))
        await app.difficulty.evaluate(mr)
        #expect(mr.difficultySHA == "new-head")
        #expect(mr.difficulty != nil)
    }

    @Test func lanesSortEasiestFirstAndCanSwitchBack() async throws {
        let app = AppModel.testing()
        await app.refresh(.automatic)
        let center = app.commandCenter
        #expect(center.laneOrder == .easiestFirst)

        for (_, mrs) in center.lanes() {
            let scores = mrs.map { $0.difficulty?.score ?? Int.max }
            #expect(scores == scores.sorted())
        }

        center.laneOrder = .newestFirst
        #expect(AccountSettings.current(in: app.modelContainer.mainContext).laneOrderRaw == LaneOrder.newestFirst.rawValue)
        for (_, mrs) in center.lanes() {
            let dates = mrs.map(\.lastSeenUpdatedAt)
            #expect(dates == dates.sorted(by: >))
        }
    }

    @Test func unscoredMRsGoLastInTheirOriginalOrder() async throws {
        let app = AppModel.testing()
        await app.refresh(.automatic)
        let mrs = Array(app.mergeRequests.trackedMergeRequests.prefix(4))
        mrs[0].difficultySHA = nil
        mrs[2].difficultySHA = nil
        let sorted = LaneOrder.easiestFirst.sorted(mrs)
        #expect(sorted.suffix(2).map(\.key) == [mrs[0].key, mrs[2].key])
        #expect(LaneOrder.newestFirst.sorted(mrs).map(\.key) == mrs.map(\.key))
    }
}
