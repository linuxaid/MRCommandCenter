import Foundation
import SwiftUI
import Testing
@testable import MR_Command_Center

/// The changed files as a folder tree (#31).
struct FileTreeTests {
    private func files(_ paths: [String]) -> [DiffFile] {
        paths.enumerated().map { index, path in
            DiffFile(GitLabDiff(oldPath: path, newPath: path, diff: "@@ -1 +1 @@\n-a\n+b",
                                newFile: false, renamedFile: false, deletedFile: false), index: index)
        }
    }

    /// "name" for files, "name/" for folders, indented two spaces per level.
    private func outline(_ tree: FileTree, collapsed: Set<String> = []) -> [String] {
        tree.rows(collapsed: collapsed).map { row in
            let indent = String(repeating: "  ", count: row.depth)
            switch row.kind {
            case .folder(let folder, _): return indent + folder.name + "/"
            case .file(let file): return indent + file.fileName
            }
        }
    }

    @Test func matchesTheIssuesExample() {
        let tree = FileTree(files(["DEF_directory/file 2", "XYZ_directory/ABC_directory/file2",
                                   "XYZ_directory/ABC_directory/file1", "XYZ_directory/top.txt"]))
        #expect(outline(tree) == [
            "DEF_directory/",
            "  file 2",
            "XYZ_directory/",
            "  ABC_directory/",
            "    file1",
            "    file2",
            "  top.txt",
        ])
    }

    @Test func foldersComeBeforeFilesAndRootFilesStayAtTheRoot() {
        let tree = FileTree(files(["README.md", "src/app.ts", "Package.swift"]))
        #expect(outline(tree) == ["src/", "  app.ts", "Package.swift", "README.md"])
    }

    @Test func chainsOfSingleFoldersAreJoined() {
        let tree = FileTree(files(["app/src/main/java/com/acme/App.java", "app/src/main/java/com/acme/Util.java",
                                   "app/build.gradle"]))
        #expect(outline(tree) == ["app/", "  src/main/java/com/acme/", "    App.java", "    Util.java", "  build.gradle"])
    }

    @Test func numbersSortNaturally() {
        let tree = FileTree(files(["v10/a", "v2/a"]))
        #expect(outline(tree) == ["v2/", "  a", "v10/", "  a"])
    }

    @Test func collapsedFoldersHideTheirContents() {
        let tree = FileTree(files(["a/b/one", "a/b/two", "a/c", "z"]))
        #expect(outline(tree, collapsed: ["a/b"]) == ["a/", "  b/", "  c", "z"])
        #expect(outline(tree, collapsed: ["a"]) == ["a/", "z"])
    }

    @Test func fileRowsAreIdentifiedByTheirFileID() {
        let all = files(["a/b/one", "two"])
        let ids = FileTree(all).rows(collapsed: []).compactMap { row -> String? in
            if case .file = row.kind { return row.id }
            return nil
        }
        #expect(Set(ids) == Set(all.map(\.id)), "The list scrolls to the selection by file ID")
    }

    @Test func closedFolderCountsEveryFileInside() {
        let tree = FileTree(files(["a/b/one", "a/b/two", "a/c", "z"]))
        guard case .folder(let folder, _) = tree.rows(collapsed: ["a"]).first?.kind else {
            Issue.record("Expected folder a"); return
        }
        #expect(folder.fileCountText == "3 files")
        let single = FileTree(files(["x/only"]))
        guard case .folder(let one, _) = single.rows(collapsed: []).first?.kind else { return }
        #expect(one.fileCountText == "1 file")
    }

    @Test func fileOrderFollowsTheTree() {
        let all = files(["z.txt", "b/two", "a/one"])
        let tree = FileTree(all)
        #expect(tree.fileOrder == [all[2].id, all[1].id, all[0].id])
    }

    @Test func foldersContainingAFile() {
        let all = files(["a/b/c/deep.swift", "a/x.swift", "a/b/y.swift"])
        let tree = FileTree(all)
        #expect(tree.folderPaths(containing: all[0].id) == ["a", "a/b", "a/b/c"])
        #expect(tree.folderPaths(containing: all[1].id) == ["a"])
    }

    @Test func deletedAndRenamedFilesSitUnderTheirShownPath() {
        let deleted = DiffFile(GitLabDiff(oldPath: "old/gone.swift", newPath: "old/gone.swift", diff: "",
                                          newFile: false, renamedFile: false, deletedFile: true), index: 0)
        let renamed = DiffFile(GitLabDiff(oldPath: "old/name.swift", newPath: "new/name.swift", diff: "",
                                          newFile: false, renamedFile: true, deletedFile: false), index: 1)
        #expect(outline(FileTree([deleted, renamed])) == ["new/", "  name.swift", "old/", "  gone.swift"])
    }
}

/// The arrow keys in the tree (#33), as a pure function of the tree and its closed folders.
struct FileTreeStepTests {
    // a/
    //   b/
    //     one
    //     two
    //   c
    // z
    private let tree = FileTree(["a/b/one", "a/b/two", "a/c", "z"].enumerated().map { index, path in
        DiffFile(GitLabDiff(oldPath: path, newPath: path, diff: "@@ -1 +1 @@\n-a\n+b",
                            newFile: false, renamedFile: false, deletedFile: false), index: index)
    })

    private func file(_ path: String) -> FileTree.Cursor {
        .file(tree.fileOrder.first { $0.hasSuffix(":" + path) }!)
    }

    @Test func downAndUpStopOnFolders() {
        #expect(tree.step(.down, from: .folder("a"), collapsed: []) == .moveTo(.folder("a/b")))
        #expect(tree.step(.down, from: .folder("a/b"), collapsed: []) == .moveTo(file("a/b/one")))
        #expect(tree.step(.up, from: file("a/c"), collapsed: []) == .moveTo(file("a/b/two")))
        #expect(tree.step(.down, from: .folder("a/b"), collapsed: ["a/b"]) == .moveTo(file("a/c")),
                "A closed folder's files are skipped")
    }

    @Test func stopsAtEitherEnd() {
        #expect(tree.step(.up, from: .folder("a"), collapsed: []) == .none)
        #expect(tree.step(.down, from: file("z"), collapsed: []) == .none)
    }

    @Test func withNothingSelectedDownPicksTheFirstRowAndUpTheLast() {
        #expect(tree.step(.down, from: nil, collapsed: []) == .moveTo(.folder("a")))
        #expect(tree.step(.up, from: nil, collapsed: []) == .moveTo(file("z")))
        #expect(tree.step(.left, from: nil, collapsed: []) == .none)
    }

    @Test func leftClosesAnOpenFolder() {
        #expect(tree.step(.left, from: .folder("a/b"), collapsed: []) == .close("a/b"))
    }

    @Test func leftOnAFileClosesItsFolder() {
        #expect(tree.step(.left, from: file("a/b/two"), collapsed: []) == .close("a/b"))
        #expect(tree.step(.left, from: file("a/c"), collapsed: []) == .close("a"))
    }

    @Test func leftOnAClosedFolderMovesToTheFolderAbove() {
        #expect(tree.step(.left, from: .folder("a/b"), collapsed: ["a/b"]) == .moveTo(.folder("a")))
        #expect(tree.step(.left, from: .folder("a"), collapsed: ["a"]) == .none)
        #expect(tree.step(.left, from: file("z"), collapsed: []) == .none, "Nothing above a top-level file")
    }

    @Test func rightOpensAClosedFolderThenStepsIn() {
        #expect(tree.step(.right, from: .folder("a"), collapsed: ["a"]) == .open("a"))
        #expect(tree.step(.right, from: .folder("a"), collapsed: []) == .moveTo(.folder("a/b")))
        #expect(tree.step(.right, from: .folder("a/b"), collapsed: []) == .moveTo(file("a/b/one")))
        #expect(tree.step(.right, from: file("a/c"), collapsed: []) == .none)
    }

    @Test func aHiddenSelectionStartsFromTheClosedFolderShowingIt() {
        #expect(tree.step(.right, from: file("a/b/one"), collapsed: ["a"]) == .open("a"))
        #expect(tree.step(.down, from: file("a/b/one"), collapsed: ["a"]) == .moveTo(file("z")))
        #expect(tree.step(.up, from: .folder("a/b"), collapsed: ["a"]) == .moveTo(.folder("a")),
                "Up from a hidden folder lands on the closed folder it's in")
    }

    @Test func rowIDsRoundTrip() {
        for cursor in [FileTree.Cursor.folder("a/b"), file("a/c")] {
            #expect(FileTree.Cursor(rowID: cursor.rowID) == cursor)
        }
    }
}

/// ↑/↓ and selection with the tree shown.
@MainActor
struct FileTreeNavigationTests {
    private let appModel = AppModel.testing()

    private func loaded() async throws -> ChangesModel {
        await appModel.mergeRequests.refresh(.automatic)
        let mr = try #require(appModel.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let model = ChangesModel()
        await model.load(mr, using: appModel.diffs)
        return model
    }

    private func name(_ model: ChangesModel) -> String? { model.selectedFile?.path }

    @Test func arrowsWalkEveryRowFoldersIncluded() async throws {
        let model = try await loaded()
        model.showsTree = true
        let rows = model.tree.rows(collapsed: [])
        model.selectedFileID = nil
        for row in rows {
            model.moveFileSelection(by: 1)
            #expect(model.cursor == row.cursor)
        }
        #expect(model.selectedFileID == model.tree.fileOrder.last)
    }

    @Test func aFolderRowKeepsTheFileShown() async throws {
        let model = try await loaded()
        model.showsTree = true
        let rows = model.tree.rows(collapsed: [])
        let fileIndex = try #require(rows.firstIndex { if case .file = $0.kind { $0.depth > 0 } else { false } })
        guard case .file(let file) = rows[fileIndex].kind else { return }
        model.selectedFileID = file.id

        model.moveFileSelection(by: -1)

        #expect(model.focusedFolder != nil, "The row above a folder's first file is the folder")
        #expect(model.selectedFileID == file.id, "Its diff stays shown")
        model.moveFileSelection(by: 1)
        #expect(model.focusedFolder == nil)
        #expect(model.cursor == .file(file.id))
    }

    @Test func leftClosesTheFilesFolderAndRightOpensIt() async throws {
        let model = try await loaded()
        model.showsTree = true
        let file = try #require(model.tree.fileOrder.first { !model.tree.folderPaths(containing: $0).isEmpty })
        let folder = try #require(model.tree.folderPaths(containing: file).last)
        model.selectedFileID = file

        #expect(model.handleSideArrow(opens: false, modifiers: [.function, .numericPad], isComposing: false))
        #expect(model.collapsedFolders.contains(folder))
        #expect(model.cursor == .folder(folder))
        #expect(model.selectedFileID == file, "Closing the folder keeps the file's diff")

        #expect(model.handleSideArrow(opens: true, modifiers: [], isComposing: false))
        #expect(!model.collapsedFolders.contains(folder))
        #expect(model.cursor == .folder(folder))
        model.handleSideArrow(opens: true, modifiers: [], isComposing: false)
        #expect(model.cursor != .folder(folder), "→ on an open folder steps into it")
    }

    @Test func sideArrowsAreLeftAloneInTheFlatListAndWhileComposing() async throws {
        let model = try await loaded()
        model.showsTree = false
        #expect(!model.handleSideArrow(opens: false, modifiers: [], isComposing: false))
        model.showsTree = true
        #expect(!model.handleSideArrow(opens: false, modifiers: [], isComposing: true))
        #expect(!model.handleSideArrow(opens: false, modifiers: [.command], isComposing: false))
        #expect(model.collapsedFolders.isEmpty)
    }

    @Test func clickingAFolderRowTakesTheKeyboard() async throws {
        let model = try await loaded()
        model.showsTree = true
        let file = try #require(model.selectedFileID)
        let folder = try #require(model.tree.allFolderPaths.sorted().first)

        model.select(rowID: FileTree.Cursor.folder(folder).rowID)
        #expect(model.cursor == .folder(folder))
        #expect(model.selectedFileID == file)

        model.select(rowID: file)
        #expect(model.cursor == .file(file))
    }

    @Test func switchingToTheFlatListDropsTheFolderCursor() async throws {
        let model = try await loaded()
        model.showsTree = true
        model.focusedFolder = model.tree.allFolderPaths.first
        model.showsTree = false
        #expect(model.focusedFolder == nil)
    }

    @Test func flatListKeepsGitLabsOrder() async throws {
        let model = try await loaded()
        model.showsTree = false
        let files = try #require(model.diff).files
        model.selectedFileID = files.first?.id
        model.moveFileSelection(by: 1)
        #expect(model.selectedFileID == files[1].id)
    }

    @Test func steppingIntoAClosedFolderOpensIt() async throws {
        let model = try await loaded()
        model.showsTree = true
        let target = try #require(model.tree.fileOrder.last { !model.tree.folderPaths(containing: $0).isEmpty })
        let folders = model.tree.folderPaths(containing: target)
        try #require(!folders.isEmpty)
        model.collapsedFolders = Set(folders)

        model.selectedFileID = target

        #expect(model.collapsedFolders.isDisjoint(with: folders), "The selected file is never hidden")
    }

    @Test func jumpingToAFileOpensItsFolders() async throws {
        let model = try await loaded()
        model.showsTree = true
        let file = try #require(model.diff?.files.first { $0.path.contains("/") })
        model.collapsedFolders = Set(model.tree.folderPaths(containing: file.id))

        model.reveal(path: file.path, line: 1)

        #expect(model.collapsedFolders.isEmpty)
    }

    @Test func firstFileSelectedIsTheTreesFirst() async throws {
        await appModel.mergeRequests.refresh(.automatic)
        let mr = try #require(appModel.mergeRequests.trackedMergeRequests.first { $0.iid == 412 })
        let model = ChangesModel()
        model.showsTree = true
        await model.load(mr, using: appModel.diffs)
        #expect(model.selectedFileID == model.tree.fileOrder.first)
    }

    @Test func closingTheSelectedFilesFolderKeepsTheSelection() async throws {
        let model = try await loaded()
        model.showsTree = true
        let file = try #require(model.tree.fileOrder.first { !model.tree.folderPaths(containing: $0).isEmpty })
        model.selectedFileID = file
        let folder = try #require(model.tree.folderPaths(containing: file).first)

        model.toggleFolder(folder)

        #expect(model.collapsedFolders.contains(folder), "The folder closes")
        #expect(model.selectedFileID == file, "The file stays selected and its diff stays shown")
        model.showsTree = true
        #expect(model.collapsedFolders.contains(folder), "Re-applying the same setting (e.g. on resize) doesn't reopen it")
        model.toggleFolder(folder)
        #expect(model.collapsedFolders.isEmpty)
    }
}
