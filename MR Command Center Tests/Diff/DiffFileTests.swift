import Foundation
import Testing
@testable import MR_Command_Center

struct DiffFileTests {
    private func load() throws -> [DiffFile] {
        let diffs = try HTTPClient.decode([GitLabDiff].self, from: Fixture.data("gitlab_diffs"), decoder: .gitLab)
        return diffs.enumerated().map { DiffFile($1, index: $0) }
    }

    @Test func classifiesGitLabDiffs() throws {
        let files = try load()
        #expect(files.count == 5)

        #expect(files[0].change == .modified)
        #expect(files[0].unavailable == nil)
        #expect((files[0].additions, files[0].deletions) == (1, 0))

        #expect(files[1].change == .added)
        #expect(files[1].unavailable == .binary)

        #expect(files[2].unavailable == .collapsed)
        #expect(files[2].isGenerated)

        #expect(files[3].unavailable == .tooLarge)

        #expect(files[4].change == .renamed)
        #expect(files[4].unavailable == .renamedWithoutChanges)
        #expect(files[4].path == "docs/new.md")
    }

    @Test func pathAndDirectoryParts() {
        let deleted = DiffFile(GitLabDiff(oldPath: "a/b/c.py", newPath: "a/b/c.py", diff: "@@ -1 +0,0 @@\n-x\n",
                                          newFile: false, renamedFile: false, deletedFile: true), index: 0)
        #expect(deleted.change == .deleted)
        #expect(deleted.fileName == "c.py")
        #expect(deleted.directory == "a/b/")
        let root = DiffFile(GitLabDiff(oldPath: "README.md", newPath: "README.md", diff: "@@ -1 +1 @@\n-a\n+b\n",
                                       newFile: false, renamedFile: false, deletedFile: false), index: 1)
        #expect(root.directory == "")
    }

    @Test func collapsedWithContentIsShownCollapsed() {
        let file = DiffFile(GitLabDiff(oldPath: "x", newPath: "x", diff: "@@ -1 +1 @@\n-a\n+b\n",
                                       newFile: false, renamedFile: false, deletedFile: false, collapsed: true), index: 0)
        #expect(file.unavailable == nil)
        #expect(file.isCollapsedByGitLab)
    }

    @Test(arguments: [("1000+", 2, true), ("5", 2, true), ("2", 2, false), (nil as String?, 2, false)])
    func detectsOverflow(changesCount: String?, files: Int, expected: Bool) {
        let diffs = (0..<files).map { GitLabDiff(oldPath: "f\($0)", newPath: "f\($0)", diff: "", newFile: false, renamedFile: false, deletedFile: false) }
        #expect(MRDiff(headSHA: "x", diffs: diffs, changesCount: changesCount, fetchedAt: .now).isOverflow == expected)
    }

    @Test func collapseRules() throws {
        let model = ChangesModel()
        let small = try load()[0]
        #expect(!model.isCollapsed(small, threshold: 400))
        #expect(model.isCollapsed(small, threshold: 2))
        model.expandedFileIDs.insert(small.id)
        #expect(!model.isCollapsed(small, threshold: 2))
    }

    @Test func mockDiffsCoverEveryCase() {
        let files = MockGitLabData.sample.entries.flatMap { entry in
            entry.diffs.enumerated().map { DiffFile($1, index: $0) }
        }
        let unavailable = Set(files.compactMap(\.unavailable))
        #expect(unavailable == [.binary, .tooLarge, .collapsed, .renamedWithoutChanges])
        #expect(Set(files.map(\.change)) == [.added, .deleted, .renamed, .modified])
        #expect(files.contains { $0.lineCount > 400 })
        #expect(files.contains { $0.hunks.flatMap(\.lines).contains { $0.kind == .noNewline } })
    }
}

struct DiffServiceTests {
    @Test func fetchesOncePerHeadSHA() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })

        let first = try await model.diffs.diff(for: mr)
        let second = try await model.diffs.diff(for: mr)

        #expect(spy.count("diffs") == 1)
        #expect(first == second)
        #expect(first.files.count == 4)
        #expect(first.headSHA == mr.headSHA)
    }

    @Test func newHeadSHARefetchesAndReplacesOldSnapshot() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let oldSHA = mr.headSHA
        _ = try await model.diffs.diff(for: mr)

        mr.headSHA = String(repeating: "f", count: 40)
        _ = try await model.diffs.diff(for: mr)

        #expect(spy.count("diffs") == 2)
        #expect(model.diffs.cachedSnapshot(mrKey: mr.key, headSHA: oldSHA) == nil)
        #expect(model.diffs.cachedSnapshot(mrKey: mr.key, headSHA: mr.headSHA) != nil)
    }

    @Test func forceRefreshBypassesCache() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first)
        _ = try await model.diffs.diff(for: mr)
        _ = try await model.diffs.diff(for: mr, forceRefresh: true)
        #expect(spy.count("diffs") == 2)
    }

    @Test func overflowingMockMR() async throws {
        let model = AppModel.testing()
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first { $0.iid == 1884 })
        #expect(mr.changesCount == "1000+")
        #expect(try await model.diffs.diff(for: mr).isOverflow)
    }

    @Test func refreshDetailsAlwaysRefetches() async throws {
        let spy = SpyGitLabClient()
        let model = AppModel.testing(gitLab: spy)
        await model.mergeRequests.refresh(.automatic)
        let mr = try #require(model.mergeRequests.trackedMergeRequests.first)
        #expect(spy.count("detail") == 11)

        await model.mergeRequests.refreshDetails(for: mr)
        #expect(spy.count("detail") == 12)
        #expect(spy.count("approvals") == 12)
    }
}
