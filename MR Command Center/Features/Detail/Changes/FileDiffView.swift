import SwiftUI

/// Header plus the diff (or the reason there isn't one) for a single file.
struct FileDiffView: View {
    let file: DiffFile
    let threadCount: Int
    var scrollRequest: ScrollRequest?
    @Binding var layout: DiffLayout
    let isCollapsed: Bool
    let expand: () -> Void
    let openInBrowser: () -> Void

    /// Too narrow for two columns: always show unified and hide the layout picker.
    @State private var isNarrow = false

    private var effectiveLayout: DiffLayout { isNarrow ? .unified : layout }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: file)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onGeometryChange(for: Bool.self) { $0.size.width < 560 } action: { isNarrow = $0 }
    }

    /// Path on its own line so narrow columns don't squeeze it; badges, stats, and the
    /// layout picker share the second line.
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if file.change == .renamed {
                    Text("\(file.oldPath) → \(file.newPath)")
                } else {
                    Text(file.path)
                }
            }
            .font(.callout.monospaced())
            .lineLimit(1)
            .truncationMode(.head)
            .textSelection(.enabled)
            .help(file.change == .renamed ? "\(file.oldPath) → \(file.newPath)" : file.path)

            HStack(spacing: 8) {
                badge
                    .fixedSize()
                if file.isGenerated {
                    Label("Generated", systemImage: "gearshape")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                if file.unavailable == nil {
                    DiffStat(additions: file.additions, deletions: file.deletions)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                if file.unavailable == nil && !isCollapsed && !isNarrow {
                    Picker("Layout", selection: $layout) {
                        ForEach(DiffLayout.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var badge: some View {
        switch file.change {
        case .added: Label("New file", systemImage: "plus.square").foregroundStyle(.green)
        case .deleted: Label("Deleted", systemImage: "minus.square").foregroundStyle(.red)
        case .renamed: Label("Renamed", systemImage: "arrow.right.square").foregroundStyle(.blue)
        case .modified: Label("Modified", systemImage: "pencil").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func body(for file: DiffFile) -> some View {
        switch file.unavailable {
        case .binary:
            ContentUnavailableView("Binary File", systemImage: "doc.zipper",
                                   description: Text("Binary files aren't shown as a diff."))
        case .tooLarge:
            unavailableInGitLab(title: "Diff Too Large",
                                reason: "GitLab didn't include this diff because it exceeds the size limit.")
        case .collapsed:
            unavailableInGitLab(title: "Diff Collapsed by GitLab",
                                reason: "GitLab collapsed this diff and didn't send its contents through the API.")
        case .renamedWithoutChanges:
            ContentUnavailableView("Renamed Without Changes", systemImage: "arrow.right.square",
                                   description: Text("\(file.oldPath) was moved to \(file.newPath)."))
        case .empty:
            ContentUnavailableView("No Content Changes", systemImage: "doc",
                                   description: Text("This file has no line changes (empty file or mode change only)."))
        case nil:
            if isCollapsed {
                collapsedPlaceholder
            } else {
                // A new identity per file gives each file a fresh scroll view, so stepping to
                // another file (↑/↓) starts at its top instead of the previous file's offset.
                switch effectiveLayout {
                case .unified: UnifiedDiffView(file: file, scrollRequest: scrollRequest).id(file.id)
                case .sideBySide: SideBySideDiffView(file: file, scrollRequest: scrollRequest).id(file.id)
                }
            }
        }
    }

    private func unavailableInGitLab(title: String, reason: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "eye.slash")
        } description: {
            Text(reason)
        } actions: {
            Button("Open in Browser", action: openInBrowser)
        }
    }

    private var collapsedPlaceholder: some View {
        ContentUnavailableView {
            Label("Large Diff Collapsed", systemImage: "rectangle.compress.vertical")
        } description: {
            let comments = threadCount > 0 ? " It has \(threadCount) comment \(threadCount == 1 ? "thread" : "threads")." : ""
            if file.isGenerated {
                Text("This looks like a generated file (\(file.lineCount) lines).\(comments)")
            } else {
                Text("This diff has \(file.lineCount) lines.\(comments)")
            }
        } actions: {
            Button("Show Diff", action: expand)
        }
    }
}
