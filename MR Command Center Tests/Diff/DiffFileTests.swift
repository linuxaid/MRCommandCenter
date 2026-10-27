import Foundation
import SwiftUI
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

struct ChangesModelTests {
    /// Held for the whole test so its SwiftData container outlives the loaded diff.
    private let appModel = AppModel.testing()

    /// A Changes model with MR 412's four-file diff loaded (the first file is selected on load).
    private func loaded() async throws -> (ChangesModel, [DiffFile.ID]) {
        await appModel.mergeRequests.refresh(.automatic)
        let mr = try #require(appModel.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let model = ChangesModel()
        await model.load(mr, using: appModel.diffs)
        let ids = try #require(model.diff).files.map(\.id)
        try #require(ids.count == 4)
        return (model, ids)
    }

    @Test func downArrowMovesToTheNextFile() async throws {
        let (model, ids) = try await loaded()
        #expect(model.selectedFileID == ids[0])
        model.moveFileSelection(by: 1)
        #expect(model.selectedFileID == ids[1])
        model.moveFileSelection(by: 1)
        #expect(model.selectedFileID == ids[2])
    }

    @Test func movingToAnotherFileDropsAnOldJumpToLine() async throws {
        let (model, ids) = try await loaded()
        let path = try #require(model.diff?.files[0].path)
        model.reveal(path: path, line: 1)
        #expect(model.scrollRequest?.fileID == ids[0])

        model.moveFileSelection(by: 1)
        model.moveFileSelection(by: -1)

        #expect(model.selectedFileID == ids[0])
        #expect(model.scrollRequest == nil, "Coming back to the file starts at its top, not the old line (#22)")
    }

    @Test func upArrowMovesToThePreviousFile() async throws {
        let (model, ids) = try await loaded()
        model.selectedFileID = ids[2]
        model.moveFileSelection(by: -1)
        #expect(model.selectedFileID == ids[1])
    }

    @Test func stopsAtEitherEnd() async throws {
        let (model, ids) = try await loaded()
        model.moveFileSelection(by: -1)
        #expect(model.selectedFileID == ids[0])
        model.selectedFileID = ids[3]
        model.moveFileSelection(by: 1)
        #expect(model.selectedFileID == ids[3])
    }

    @Test func withNoSelectionDownPicksFirstAndUpPicksLast() async throws {
        let (model, ids) = try await loaded()
        model.selectedFileID = nil
        model.moveFileSelection(by: 1)
        #expect(model.selectedFileID == ids[0])
        model.selectedFileID = nil
        model.moveFileSelection(by: -1)
        #expect(model.selectedFileID == ids[3])
    }

    @Test func doesNothingBeforeTheDiffLoads() {
        let model = ChangesModel()
        model.moveFileSelection(by: 1)
        #expect(model.selectedFileID == nil)
        #expect(!model.handleArrow(by: 1, modifiers: [], isComposing: false))
    }

    /// Plain arrow keys arrive with `.function` and `.numericPad` set; those don't count as held.
    @Test func plainArrowIsHandled() async throws {
        let (model, ids) = try await loaded()
        #expect(model.handleArrow(by: 1, modifiers: [.function, .numericPad], isComposing: false))
        #expect(model.selectedFileID == ids[1])
        #expect(model.handleArrow(by: -1, modifiers: [], isComposing: false))
        #expect(model.selectedFileID == ids[0])
    }

    @Test func arrowIsLeftToTheCommentBoxWhileComposing() async throws {
        let (model, ids) = try await loaded()
        #expect(!model.handleArrow(by: 1, modifiers: [.function, .numericPad], isComposing: true))
        #expect(model.selectedFileID == ids[0])
    }

    @Test(arguments: [EventModifiers.shift, .option, .control, .command, [.command, .option]])
    func arrowWithModifiersIsLeftAlone(modifiers: EventModifiers) async throws {
        let (model, ids) = try await loaded()
        #expect(!model.handleArrow(by: 1, modifiers: modifiers.union([.function, .numericPad]), isComposing: false))
        #expect(model.selectedFileID == ids[0])
    }

    @Test func fileListKeepsAStoredWidthThatFits() {
        #expect(FileListWidth.clamped(FileListWidth.standard, available: 1000) == FileListWidth.standard)
        #expect(FileListWidth.clamped(400, available: 1000) == 400)
    }

    @Test func fileListWidthStaysWithinItsLimits() {
        #expect(FileListWidth.clamped(40, available: 1000) == FileListWidth.minimum)
        #expect(FileListWidth.clamped(5000, available: 4000) == FileListWidth.maximum)
    }

    @Test func fileListLeavesRoomForTheDiff() {
        // 700 wide: the list can take at most 700 - 360.
        #expect(FileListWidth.clamped(500, available: 700) == 700 - FileListWidth.minimumDiffWidth)
        // At the narrowest non-compact width the diff still gets its room.
        let narrowest: CGFloat = 640
        #expect(narrowest - FileListWidth.clamped(.infinity, available: narrowest) >= FileListWidth.minimumDiffWidth)
    }

    @Test func fileListNeverGoesBelowMinimumWhenSpaceIsTight() {
        // Before the first geometry pass the available width is 0.
        #expect(FileListWidth.clamped(FileListWidth.standard, available: 0) == FileListWidth.minimum)
        #expect(FileListWidth.clamped(300, available: 400) == FileListWidth.minimum)
    }

    @Test func fileListFallsBackToStandardForABadStoredWidth() {
        #expect(FileListWidth.clamped(.nan, available: 1000) == FileListWidth.standard)
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
