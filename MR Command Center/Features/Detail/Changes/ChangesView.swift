import CryptoKit
import SwiftData
import SwiftUI

struct ChangesView: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @Query private var settingsRows: [AccountSettings]
    @State private var model = ChangesModel()
    @State private var comments = CommentsModel()
    @AppStorage("diffLayout") private var layout: DiffLayout = .unified
    @AppStorage("showAIComments") private var showsAIComments = true
    /// Narrow detail column: the file list becomes a menu above the diff.
    @State private var isCompact = false
    /// The file list's width as the user last left it; clamped to the room available.
    @AppStorage("fileListWidth") private var fileListWidth: Double = FileListWidth.standard
    /// Folders (#31) or a flat list.
    @AppStorage("fileListTree") private var showsFileTree = true
    /// The width while a drag is in progress; stored only when the drag ends.
    @State private var draggedFileListWidth: Double?
    @State private var changesWidth: CGFloat = 0
    /// The Changes area takes focus whenever the diff loads (including a reload for a new
    /// head SHA, which rebuilds it) so ↑/↓ move between files without a click.
    @FocusState private var isFocused: Bool

    private var collapseThreshold: Int { settingsRows.first?.collapseFileDiffThresholdLines ?? 400 }

    var body: some View {
        withAI
            // Reload threads when the diff loads and whenever the MR changes on GitLab.
            .task(id: CommentsKey(diffSHA: model.diff?.headSHA, updatedAt: mr.lastSeenUpdatedAt, unresolved: mr.unresolvedDiscussions)) {
                guard let diff = model.diff else { return }
                await comments.load(mr: mr, diff: diff, service: appModel.discussions)
            }
    }

    private var loading: some View {
        content
            .environment(comments)
            .task(id: "\(mr.key)@\(mr.headSHA)") {
                model = ChangesModel()
                // Set before loading so the first file selected is the tree's first. The file list
                // also keeps it in step afterwards (it doesn't exist until the diff has loaded).
                model.showsTree = showsFileTree && !isCompact
                comments = CommentsModel()
                await model.load(mr, using: appModel.diffs)
                applyNavigation()
            }
            .onChange(of: appModel.diffNavigation) { applyNavigation() }
    }

    /// Shows the latest AI review for this head SHA inline and keeps open counts current.
    private var withAI: some View {
        loading
            .task(id: AIKey(diffSHA: model.diff?.headSHA, revision: appModel.aiReview.revision)) {
                guard let diff = model.diff else { return }
                let run = appModel.aiReview.runs(for: mr.key).first { $0.status == .completed && $0.headSHA == diff.headSHA }
                comments.showAI(run, in: diff)
                wireAIChanges()
            }
            .onChange(of: showsAIComments, initial: true) { comments.showsAI = showsAIComments }
            .sheet(item: $comments.aiPostDraft) { draft in
                AIPostPreviewSheet(comments: comments, location: location(of: draft))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .loading:
            ProgressView("Loading changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") {
                    Task { await model.load(mr, using: appModel.diffs, forceRefresh: true) }
                }
            }
        case .loaded(let diff):
            VStack(spacing: 0) {
                if let error = comments.loadError {
                    Banner(message: "Couldn't load comments: \(error)", systemImage: "text.bubble", style: .warning,
                           actionTitle: "Retry") {
                        Task { await comments.load(mr: mr, diff: diff, service: appModel.discussions, forceRefresh: true) }
                    }
                }
                if !comments.placement.orphaned.isEmpty {
                    Banner(message: "\(comments.placement.orphaned.count) comments are on files that are no longer in this diff.",
                           systemImage: "text.bubble", style: .info, actionTitle: "Open in Browser") { openInBrowser(nil) }
                }
                AIStrip(mr: mr, run: comments.aiRun, openCount: comments.openAICount,
                        totalCount: comments.aiConcerns.count, isShown: $showsAIComments)
                if diff.isOverflow {
                    Banner(
                        message: "GitLab limited this diff: showing \(diff.files.count) of \(diff.changesCount ?? "?") changed files.",
                        systemImage: "exclamationmark.triangle", style: .warning,
                        actionTitle: "Open in Browser"
                    ) { openInBrowser(nil) }
                }
                // A plain HStack: `HSplitView` forced a huge minimum window width,
                // which crashed AppKit layout with the inspector open.
                Group {
                    if isCompact {
                        VStack(spacing: 0) {
                            CompactFilePicker(diff: diff, selection: $model.selectedFileID)
                            Divider()
                            selectedFileView
                        }
                    } else {
                        HStack(spacing: 0) {
                            DiffFileList(diff: diff, model: model, placement: comments.placement,
                                         aiCounts: showsAIComments ? comments.openAICountsByFile : [:],
                                         showsTree: $showsFileTree)
                                .frame(width: FileListWidth.clamped(draggedFileListWidth ?? fileListWidth,
                                                                    available: changesWidth))
                            FileListResizeHandle(width: $fileListWidth, draggedWidth: $draggedFileListWidth,
                                                 available: changesWidth)
                                // Above the diff, so its whole grab area takes the drag.
                                .zIndex(1)
                            selectedFileView
                        }
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    changesWidth = width
                    isCompact = width < 640
                    // The narrow layout's file menu is flat, so ↑/↓ follows GitLab's order there.
                    let shown = showsFileTree && !isCompact
                    if model.showsTree != shown { model.showsTree = shown }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            // I opens the label picker (#27). On the diff itself, so typing in a comment box isn't caught.
            .onKeyPress(characters: CharacterSet(charactersIn: "iI")) { press in
                guard CommandCenter.opensLabelPicker(modifiers: press.modifiers, isComposing: comments.activeTarget != nil) else {
                    return .ignored
                }
                appModel.commandCenter.editLabels(mr)
                return .handled
            }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                let isComposing = comments.activeTarget != nil
                let handled = switch press.key {
                case .leftArrow, .rightArrow:
                    // Animated like a click on the folder.
                    withAnimation(.easeOut(duration: 0.12)) {
                        model.handleSideArrow(opens: press.key == .rightArrow, modifiers: press.modifiers,
                                              isComposing: isComposing)
                    }
                default:
                    model.handleArrow(by: press.key == .downArrow ? 1 : -1, modifiers: press.modifiers,
                                      isComposing: isComposing)
                }
                return handled ? .handled : .ignored
            }
            .onAppear { isFocused = true }
        }
    }

    private var selectedFileView: some View {
        Group {
            if let file = model.selectedFile {
                FileDiffView(
                    file: file,
                    threadCount: comments.placement.threads(for: file.id).count,
                    scrollRequest: model.scrollRequest?.fileID == file.id ? model.scrollRequest : nil,
                    layout: $layout,
                    isCollapsed: model.isCollapsed(file, threshold: collapseThreshold),
                    expand: { model.expandedFileIDs.insert(file.id) },
                    openInBrowser: { openInBrowser(file) },
                    mr: mr,
                    refs: model.diff?.refs
                )
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc")
            }
        }
        // Keep `minWidth: 0`: the measured Changes width sets the file list's width, so a
        // content-dependent minimum here could feed back into an AppKit layout loop.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wireAIChanges() {
        let mr = mr
        let service = appModel.aiReview
        comments.onAIChange = { service.updateOpenConcerns(for: mr) }
    }

    private func location(of draft: AIPostDraft) -> String {
        guard let file = model.diff?.files.first(where: { $0.id == draft.fileID }),
              let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.id == draft.lineID }) else { return "" }
        return "\(file.path):\(line.newNumber ?? line.oldNumber ?? 0)"
    }

    private func applyNavigation() {
        guard let navigation = appModel.diffNavigation, navigation.mrKey == mr.key, model.diff != nil else { return }
        model.reveal(path: navigation.path, line: navigation.line)
        appModel.diffNavigation = nil
    }

    /// Opens the MR's Changes page, scrolled to the file when given (GitLab anchors are SHA-1 of the path).
    private func openInBrowser(_ file: DiffFile?) {
        var link = mr.webURL + "/diffs"
        if let file {
            let digest = Insecure.SHA1.hash(data: Data(file.path.utf8))
            link += "#" + digest.map { String(format: "%02x", $0) }.joined()
        }
        if let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AIKey: Equatable {
    let diffSHA: String?
    let revision: Int
}

/// AI status for the Changes tab: live progress while reviewing, then the open count,
/// a show/hide toggle, and posting the summary thread.
private struct AIStrip: View {
    let mr: TrackedMR
    let run: AIReviewRun?
    let openCount: Int
    let totalCount: Int
    @Binding var isShown: Bool
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let progress = appModel.aiReview.progress[mr.key]
        if progress != nil || run != nil {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple).accessibilityHidden(true)
                if let progress {
                    ProgressView(value: Double(progress.finishedCount), total: Double(max(progress.paths.count, 1)))
                        .frame(width: 120)
                    Text(progress.isMerging ? "AI is combining findings…" : "AI reviewing \(progress.finishedCount) of \(progress.paths.count) files…")
                    Spacer()
                    Button("Cancel") { appModel.aiReview.cancel(mr.key) }.controlSize(.small)
                } else if let run {
                    Text(summary(run))
                    Spacer()
                    if run.summaryPostedAt != nil {
                        Label("Summary posted", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    } else if appModel.aiReview.summaryIsWorthPosting(run) {
                        Button("Post Summary to GitLab…") { appModel.summaryPoster.preview(run, for: mr) }
                            .controlSize(.small)
                    }
                    if totalCount > 0 {
                        Toggle("Show AI comments", isOn: $isShown)
                            .toggleStyle(.switch)
                            .controlSize(.small)
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.purple.opacity(0.08))
        }
    }

    private func summary(_ run: AIReviewRun) -> String {
        let verdict = run.verdictStatus?.title ?? "no verdict"
        let comments = totalCount == 0 ? "no comments" : "\(openCount) open of \(totalCount) \(totalCount == 1 ? "comment" : "comments")"
        return "AI review at \(run.headSHA.prefix(8)) (\(run.promptVersionName)): \(verdict), \(comments)"
    }
}

private struct CommentsKey: Equatable {
    let diffSHA: String?
    let updatedAt: Date
    /// Changes when a thread is resolved elsewhere (the brief rail), so the diff redraws from the shared cache.
    var unresolved = 0
}

private struct DiffFileList: View {
    let diff: MRDiff
    @Bindable var model: ChangesModel
    let placement: ThreadPlacement
    let aiCounts: [DiffFile.ID: Int]
    @Binding var showsTree: Bool

    var body: some View {
        ScrollViewReader { proxy in
            // Ignore the list clearing the selection when its row is hidden in a closed folder:
            // the file stays selected and shown. A folder row can hold the selection too (#33).
            List(selection: Binding(get: { model.cursor?.rowID }, set: { if let id = $0 { model.select(rowID: id) } })) {
                Section {
                    if showsTree {
                        ForEach(model.tree.rows(collapsed: model.collapsedFolders)) { row in
                            switch row.kind {
                            case .folder(let folder, let isExpanded):
                                FolderRow(path: folder.path, name: folder.name, fileCountText: folder.fileCountText,
                                          isExpanded: isExpanded, depth: row.depth) {
                                    withAnimation(.easeOut(duration: 0.12)) { model.toggleFolder(folder.path) }
                                }
                                .tag(row.id)
                            case .file(let file):
                                fileRow(file, showsDirectory: false)
                                    .padding(.leading, CGFloat(row.depth) * FolderRow.indent)
                                    .tag(file.id)
                            }
                        }
                    } else {
                        ForEach(diff.files) { file in
                            fileRow(file, showsDirectory: true)
                                .tag(file.id)
                        }
                    }
                } header: {
                    HStack {
                        Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                        Spacer()
                        DiffStat(additions: diff.additions, deletions: diff.deletions)
                        Button {
                            showsTree.toggle()
                        } label: {
                            Image(systemName: showsTree ? "list.bullet" : "list.bullet.indent")
                        }
                        .buttonStyle(.borderless)
                        .help(showsTree ? "Show as a flat list" : "Show folders")
                        .accessibilityLabel(showsTree ? "Show as a flat list" : "Show folders")
                    }
                }
            }
            // Keep the row in view when the arrow keys move the selection past the visible files.
            .onChange(of: model.cursor, initial: true) { _, cursor in
                guard let cursor else { return }
                proxy.scrollTo(cursor.rowID)
            }
            .onChange(of: showsTree, initial: true) { _, isOn in
                if model.showsTree != isOn { model.showsTree = isOn }
                // The rows were swapped but the selection didn't change: bring it back into view.
                if let cursor = model.cursor { proxy.scrollTo(cursor.rowID) }
            }
        }
    }

    private func fileRow(_ file: DiffFile, showsDirectory: Bool) -> some View {
        let threads = placement.threads(for: file.id)
        return DiffFileRow(file: file, threadCount: threads.count, unresolvedCount: threads.unresolvedCount,
                           aiCount: aiCounts[file.id] ?? 0, showsDirectory: showsDirectory)
    }
}

/// A folder in the file tree: click to open or close it. A closed folder says how many files it holds.
private struct FolderRow: View {
    static let indent: CGFloat = 14

    // Just what's drawn: a whole `Folder` carries every file's diff, which is costly to compare.
    let path: String
    let name: String
    let fileCountText: String
    let isExpanded: Bool
    let depth: Int
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
                    .frame(width: 10)
                Image(systemName: isExpanded ? "folder" : "folder.fill")
                    .foregroundStyle(.secondary)
                Text(name)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 4)
                if !isExpanded {
                    Text(fileCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, CGFloat(depth) * Self.indent)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help(path)
        .accessibilityLabel("Folder \(path), \(isExpanded ? "open" : "closed")")
        .accessibilityHint(isExpanded ? "Closes the folder" : "Opens the folder")
    }
}

/// The divider between the file list and the diff. Drag it to resize the list;
/// double-click it to go back to the standard width.
private struct FileListResizeHandle: View {
    @Binding var width: Double
    @Binding var draggedWidth: Double?
    let available: CGFloat

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.frameResize(position: .trailing))
                    .gesture(drag)
                    .onTapGesture(count: 2) { width = FileListWidth.standard }
            }
            .accessibilityElement()
            .accessibilityLabel("File list width")
            .accessibilityValue("\(Int(current)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = FileListWidth.clamped(current + FileListWidth.step, available: available)
                case .decrement: width = FileListWidth.clamped(current - FileListWidth.step, available: available)
                @unknown default: break
                }
            }
    }

    private var current: CGFloat { FileListWidth.clamped(draggedWidth ?? width, available: available) }

    // Global coordinates: the handle moves with the drag, so local ones would jitter.
    private var drag: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                let start = FileListWidth.clamped(width, available: available)
                draggedWidth = FileListWidth.clamped(start + value.translation.width, available: available)
            }
            .onEnded { _ in
                if let draggedWidth { width = draggedWidth }
                draggedWidth = nil
            }
    }
}

/// File menu used when the detail column is narrow.
private struct CompactFilePicker: View {
    let diff: MRDiff
    @Binding var selection: DiffFile.ID?

    var body: some View {
        HStack {
            Picker("File", selection: $selection) {
                ForEach(diff.files) { file in
                    Text(file.path).tag(Optional(file.id))
                }
            }
            .labelsHidden()
            Text("\(diff.files.count) files")
                .foregroundStyle(.secondary)
                .fixedSize()
            DiffStat(additions: diff.additions, deletions: diff.deletions)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct DiffFileRow: View {
    let file: DiffFile
    let threadCount: Int
    let unresolvedCount: Int
    let aiCount: Int
    /// The flat list shows each file's folder; the tree already does.
    var showsDirectory = true

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
                .accessibilityLabel(changeDescription)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Directory and comment badges share the second line so the name keeps its room.
                HStack(spacing: 6) {
                    if showsDirectory, !file.directory.isEmpty {
                        Text(file.directory)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    if aiCount > 0 {
                        Label("\(aiCount)", systemImage: "sparkles")
                            .foregroundStyle(.purple)
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                            .accessibilityLabel("\(aiCount) open AI comments")
                    }
                    if threadCount > 0 {
                        Label("\(threadCount)", systemImage: unresolvedCount > 0 ? "text.bubble.fill" : "text.bubble")
                            .foregroundStyle(unresolvedCount > 0 ? .orange : .secondary)
                            .labelStyle(.titleAndIcon)
                            .fixedSize()
                            .accessibilityLabel("\(threadCount) comment threads, \(unresolvedCount) unresolved")
                    }
                }
                .font(.caption.monospacedDigit())
            }
            Spacer(minLength: 4)
            if file.unavailable == .binary {
                Text("Binary").font(.caption).foregroundStyle(.secondary)
            } else if file.unavailable == .tooLarge || file.unavailable == .collapsed {
                Text("Not shown").font(.caption).foregroundStyle(.secondary)
            } else {
                DiffStat(additions: file.additions, deletions: file.deletions)
            }
        }
        .help(file.change == .renamed ? "\(file.oldPath) → \(file.newPath)" : file.path)
    }

    private var icon: String {
        switch file.change {
        case .added: "plus.square"
        case .deleted: "minus.square"
        case .renamed: "arrow.right.square"
        case .modified: "pencil.and.list.clipboard"
        }
    }

    private var iconColor: Color {
        switch file.change {
        case .added: .green
        case .deleted: .red
        case .renamed: .blue
        case .modified: .secondary
        }
    }

    private var changeDescription: String {
        switch file.change {
        case .added: "Added"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .modified: "Modified"
        }
    }
}

/// `+12 −3`, with signs so it doesn't rely on color.
struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(additions) additions, \(deletions) deletions")
    }
}
