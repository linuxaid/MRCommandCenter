import Foundation
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

    @Test func arrowsFollowTheTreeOrder() async throws {
        let model = try await loaded()
        model.showsTree = true
        let expected = model.tree.fileOrder
        model.selectedFileID = expected.first
        for id in expected.dropFirst() {
            model.moveFileSelection(by: 1)
            #expect(model.selectedFileID == id)
        }
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

    @Test func togglingAFolder() async throws {
        let model = try await loaded()
        model.toggleFolder("app")
        #expect(model.collapsedFolders == ["app"])
        model.toggleFolder("app")
        #expect(model.collapsedFolders.isEmpty)
    }
}
