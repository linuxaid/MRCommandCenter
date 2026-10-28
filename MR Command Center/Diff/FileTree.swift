import Foundation

/// The changed files as a folder tree (#31): folders first, then files, each alphabetical.
/// Folders that only hold one other folder are joined into one row (`src/main/java`), as
/// GitHub and VS Code do, so deep paths don't waste levels. Pure, so it's tested directly.
nonisolated struct FileTree: Sendable, Equatable {
    indirect enum Node: Sendable, Equatable, Identifiable {
        case folder(Folder)
        case file(DiffFile)

        var id: String {
            switch self {
            case .folder(let folder): "folder:" + folder.path
            case .file(let file): "file:" + file.id
            }
        }
    }

    struct Folder: Sendable, Equatable {
        /// Full path from the root, e.g. `app/webhooks`. Identifies the folder for collapsing.
        let path: String
        /// What the row shows: the last part, or several joined (`src/main/java`).
        let name: String
        let children: [Node]

        /// Every file under this folder, at any depth.
        var files: [DiffFile] {
            children.flatMap { node -> [DiffFile] in
                switch node {
                case .folder(let folder): folder.files
                case .file(let file): [file]
                }
            }
        }
    }

    /// One visible line of the tree.
    struct Row: Sendable, Equatable, Identifiable {
        enum Kind: Sendable, Equatable {
            case folder(Folder, isExpanded: Bool)
            case file(DiffFile)
        }

        let kind: Kind
        let depth: Int

        var id: String {
            switch kind {
            case .folder(let folder, _): "folder:" + folder.path
            case .file(let file): "file:" + file.id
            }
        }
    }

    let roots: [Node]

    init(_ files: [DiffFile]) {
        roots = Self.build(files.map { (components: $0.path.split(separator: "/").map(String.init), file: $0) }, prefix: "")
    }

    /// The rows to show, skipping the contents of collapsed folders.
    func rows(collapsed: Set<String>) -> [Row] {
        var rows: [Row] = []
        func visit(_ nodes: [Node], depth: Int) {
            for node in nodes {
                switch node {
                case .folder(let folder):
                    let isExpanded = !collapsed.contains(folder.path)
                    rows.append(Row(kind: .folder(folder, isExpanded: isExpanded), depth: depth))
                    if isExpanded { visit(folder.children, depth: depth + 1) }
                case .file(let file):
                    rows.append(Row(kind: .file(file), depth: depth))
                }
            }
        }
        visit(roots, depth: 0)
        return rows
    }

    /// Every file in tree order, collapsed or not. ↑/↓ step through this.
    var fileOrder: [DiffFile.ID] {
        roots.flatMap { node -> [DiffFile.ID] in
            switch node {
            case .folder(let folder): folder.files.map(\.id)
            case .file(let file): [file.id]
            }
        }
    }

    /// The folders that hold a file, outermost first, so they can be opened to show it.
    func folderPaths(containing fileID: DiffFile.ID) -> [String] {
        func search(_ nodes: [Node], trail: [String]) -> [String]? {
            for node in nodes {
                switch node {
                case .file(let file) where file.id == fileID:
                    return trail
                case .folder(let folder):
                    if let found = search(folder.children, trail: trail + [folder.path]) { return found }
                default:
                    continue
                }
            }
            return nil
        }
        return search(roots, trail: []) ?? []
    }

    private static func build(_ entries: [(components: [String], file: DiffFile)], prefix: String) -> [Node] {
        var files: [DiffFile] = []
        var groups: [String: [(components: [String], file: DiffFile)]] = [:]
        for entry in entries {
            if entry.components.count <= 1 {
                files.append(entry.file)
            } else {
                groups[entry.components[0], default: []].append((Array(entry.components.dropFirst()), entry.file))
            }
        }

        let folders = groups.keys.sorted(by: Self.nameOrder).map { name -> Node in
            var path = prefix.isEmpty ? name : prefix + "/" + name
            var display = name
            var members = groups[name]!
            // Join chains of folders that hold nothing but one more folder.
            while members.allSatisfy({ $0.components.count > 1 }),
                  let next = members.first?.components.first,
                  members.allSatisfy({ $0.components.first == next }) {
                path += "/" + next
                display += "/" + next
                members = members.map { (Array($0.components.dropFirst()), $0.file) }
            }
            return .folder(Folder(path: path, name: display, children: build(members, prefix: path)))
        }
        let sortedFiles = files.sorted { nameOrder($0.fileName, $1.fileName) }.map(Node.file)
        return folders + sortedFiles
    }

    private static func nameOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }
}
