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
    /// The Changes area takes focus whenever the diff loads (including a reload for a new
    /// head SHA, which rebuilds it) so ↑/↓ move between files without a click.
    @FocusState private var isFocused: Bool

    private var collapseThreshold: Int { settingsRows.first?.collapseFileDiffThresholdLines ?? 400 }

    var body: some View {
        withAI
            // Reload threads when the diff loads and whenever the MR changes on GitLab.
            .task(id: CommentsKey(diffSHA: model.diff?.headSHA, updatedAt: mr.lastSeenUpdatedAt)) {
                guard let diff = model.diff else { return }
                await comments.load(mr: mr, diff: diff, service: appModel.discussions)
            }
    }

    private var loading: some View {
        content
            .environment(comments)
            .task(id: "\(mr.key)@\(mr.headSHA)") {
                model = ChangesModel()
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
                            DiffFileList(diff: diff, placement: comments.placement,
                                         aiCounts: showsAIComments ? comments.openAICountsByFile : [:],
                                         selection: $model.selectedFileID)
                                .frame(width: 230)
                            Divider()
                            selectedFileView
                        }
                    }
                }
                .onGeometryChange(for: Bool.self) { $0.size.width < 640 } action: { isCompact = $0 }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let handled = model.handleArrow(
                    by: press.key == .downArrow ? 1 : -1,
                    modifiers: press.modifiers,
                    isComposing: comments.activeTarget != nil
                )
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
                    openInBrowser: { openInBrowser(file) }
                )
            } else {
                ContentUnavailableView("No File Selected", systemImage: "doc")
            }
        }
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
}

private struct DiffFileList: View {
    let diff: MRDiff
    let placement: ThreadPlacement
    let aiCounts: [DiffFile.ID: Int]
    @Binding var selection: DiffFile.ID?

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: $selection) {
                Section {
                    ForEach(diff.files) { file in
                        let threads = placement.threads(for: file.id)
                        DiffFileRow(file: file, threadCount: threads.count, unresolvedCount: threads.unresolvedCount,
                                    aiCount: aiCounts[file.id] ?? 0)
                            .tag(file.id)
                    }
                } header: {
                    HStack {
                        Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                        Spacer()
                        DiffStat(additions: diff.additions, deletions: diff.deletions)
                    }
                }
            }
            // Keep the row in view when the arrow keys move the selection past the visible files.
            .onChange(of: selection, initial: true) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
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
                    if !file.directory.isEmpty {
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
