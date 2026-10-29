import Foundation

/// The changed files as a folder tree (#31): folders first, then files, each alphabetical.
/// Folders that only hold one other folder are joined into one row (`src/main/java`), as
/// GitHub and VS Code do, so deep paths don't waste levels. Pure, so it's tested directly.
nonisolated struct FileTree: Sendable, Equatable {
    enum Node: Sendable, Equatable {
        case folder(Folder)
        case file(DiffFile)
    }

    struct Folder: Sendable, Equatable {
        /// Full path from the root, e.g. `app/webhooks`. Identifies the folder for collapsing.
        let path: String
        /// What the row shows: the last part, or several joined (`src/main/java`).
        let name: String
        let children: [Node]

        /// "3 files", shown on a closed folder.
        var fileCountText: String {
            let count = files.count
            return count == 1 ? "1 file" : "\(count) files"
        }

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

        var cursor: Cursor {
            switch kind {
            case .folder(let folder, _): .folder(folder.path)
            case .file(let file): .file(file.id)
            }
        }

        var id: String { cursor.rowID }
    }

    /// Where the keyboard is in the list (#33): on a folder row, or on a file row.
    enum Cursor: Sendable, Equatable {
        case folder(String)
        case file(DiffFile.ID)

        /// A file row's identity is its file's ID, so the list can scroll to the selected file.
        /// File IDs look like `3:path`, so they never clash with `folder:` IDs.
        var rowID: String {
            switch self {
            case .folder(let path): Self.folderPrefix + path
            case .file(let id): id
            }
        }

        init(rowID: String) {
            if rowID.hasPrefix(Self.folderPrefix) {
                self = .folder(String(rowID.dropFirst(Self.folderPrefix.count)))
            } else {
                self = .file(rowID)
            }
        }

        private static let folderPrefix = "folder:"
    }

    enum Key: Sendable {
        case up, down, left, right
    }

    /// What an arrow key does in the tree, as in Finder's list view.
    enum Step: Sendable, Equatable {
        case moveTo(Cursor)
        /// Open the folder; the cursor goes to it.
        case open(String)
        /// Close the folder; the cursor goes to it.
        case close(String)
        case none
    }

    /// ↑/↓ step through the visible rows, folders included. ← closes a folder (from a file,
    /// its folder) or, on a closed one, moves to the folder above. → opens a folder, or on an
    /// open one moves to its first row.
    func step(_ key: Key, from cursor: Cursor?, collapsed: Set<String>) -> Step {
        let rows = rows(collapsed: collapsed)
        guard let first = rows.first, let last = rows.last else { return .none }
        guard let cursor, let index = visibleIndex(of: cursor, in: rows, collapsed: collapsed) else {
            switch key {
            case .down: return .moveTo(first.cursor)
            case .up: return .moveTo(last.cursor)
            case .left, .right: return .none
            }
        }
        let row = rows[index]
        switch key {
        case .up, .down:
            let target = rows[min(max(index + (key == .down ? 1 : -1), 0), rows.count - 1)]
            return target.cursor == cursor ? .none : .moveTo(target.cursor)
        case .left:
            if case .folder(let folder, true) = row.kind { return .close(folder.path) }
            guard let parent = rows[..<index].last(where: { $0.depth == row.depth - 1 }),
                  case .folder(let folder, _) = parent.kind else {
                // At the top level: the most ← can do is put the cursor on this row.
                return row.cursor == cursor ? .none : .moveTo(row.cursor)
            }
            if case .file = row.kind { return .close(folder.path) }
            return .moveTo(parent.cursor)
        case .right:
            guard case .folder(let folder, let isExpanded) = row.kind else { return .none }
            guard isExpanded else { return .open(folder.path) }
            guard index + 1 < rows.count, rows[index + 1].depth == row.depth + 1 else { return .none }
            return .moveTo(rows[index + 1].cursor)
        }
    }

    /// The cursor's row, or when it's hidden in a closed folder, that folder's row.
    private func visibleIndex(of cursor: Cursor, in rows: [Row], collapsed: Set<String>) -> Int? {
        if let index = rows.firstIndex(where: { $0.cursor == cursor }) { return index }
        let trail: [String] = switch cursor {
        case .file(let id): folderPaths(containing: id)
        case .folder(let path): folderPaths(enclosingFolder: path)
        }
        // Outermost first, so the first closed one is the one on screen.
        guard let hiding = trail.first(where: collapsed.contains) else { return nil }
        return rows.firstIndex { $0.cursor == .folder(hiding) }
    }

    /// Every folder's path.
    var allFolderPaths: Set<String> {
        var paths: Set<String> = []
        func visit(_ nodes: [Node]) {
            for case .folder(let folder) in nodes {
                paths.insert(folder.path)
                visit(folder.children)
            }
        }
        visit(roots)
        return paths
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
        trail { if case .file(let file) = $0 { file.id == fileID } else { false } }
    }

    /// The folders that hold a folder, outermost first.
    func folderPaths(enclosingFolder path: String) -> [String] {
        trail { if case .folder(let folder) = $0 { folder.path == path } else { false } }
    }

    private func trail(to isTarget: (Node) -> Bool) -> [String] {
        func search(_ nodes: [Node], trail: [String]) -> [String]? {
            for node in nodes {
                if isTarget(node) { return trail }
                if case .folder(let folder) = node,
                   let found = search(folder.children, trail: trail + [folder.path]) {
                    return found
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
