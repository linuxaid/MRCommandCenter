import SwiftUI

/// GitLab-style unified diff. Lines wrap, so there's no horizontal scrolling.
/// Comment threads appear under their line; hover a line to comment on it.
struct UnifiedDiffView: View {
    let file: DiffFile
    var scrollRequest: ScrollRequest?
    @State private var highlighted: DiffLine.ID?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    FileLevelThreads(fileID: file.id)
                    ForEach(file.hunks) { hunk in
                        HunkHeaderRow(hunk: hunk)
                        ForEach(hunk.lines) { line in
                            VStack(alignment: .leading, spacing: 0) {
                                UnifiedLineRow(fileID: file.id, line: line, isHighlighted: highlighted == line.id)
                                LineThreads(fileID: file.id, line: line)
                            }
                            .id(line.id)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: scrollRequest?.id) { scroll(proxy, animated: true) }
        }
        .font(.system(.callout, design: .monospaced))
        .typesettingLanguage(.code)
    }

    /// Opening a file at a line lands there directly; a new target in an open file animates.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let request = scrollRequest,
              let target = file.hunks.lazy.flatMap(\.lines).first(where: { $0.kind != .deletion && $0.newNumber == request.line })
        else { return }
        Task {
            withAnimation(animated ? .default : nil) { proxy.scrollTo(target.id, anchor: .center) }
            await flash(target.id)
        }
    }

    private func flash(_ id: DiffLine.ID) async {
        highlighted = id
        try? await Task.sleep(for: .seconds(2))
        if highlighted == id { withAnimation { highlighted = nil } }
    }
}

struct SideBySideDiffView: View {
    let file: DiffFile
    var scrollRequest: ScrollRequest?
    @State private var highlighted: SplitRow.ID?

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                FileLevelThreads(fileID: file.id)
                ForEach(file.hunks) { hunk in
                    HunkHeaderRow(hunk: hunk)
                    ForEach(SideBySide.rows(for: hunk)) { row in
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(alignment: .top, spacing: 0) {
                                SplitCell(fileID: file.id, line: row.left, side: .old)
                                Divider()
                                SplitCell(fileID: file.id, line: row.right, side: .new)
                            }
                            if let left = row.left {
                                LineThreads(fileID: file.id, line: left)
                            }
                            if let right = row.right, right.id != row.left?.id {
                                LineThreads(fileID: file.id, line: right)
                            }
                        }
                        .overlay { if highlighted == row.id { Color.accentColor.opacity(0.22).allowsHitTesting(false) } }
                        .id(row.id)
                    }
                }
            }
            .textSelection(.enabled)
        }
        .onAppear { scroll(proxy, animated: false) }
        .onChange(of: scrollRequest?.id) { scroll(proxy, animated: true) }
        }
        .font(.system(.callout, design: .monospaced))
        .typesettingLanguage(.code)
    }

    /// Opening a file at a line lands there directly; a new target in an open file animates.
    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let request = scrollRequest else { return }
        let rows = file.hunks.flatMap(SideBySide.rows(for:))
        guard let target = rows.first(where: { $0.right?.newNumber == request.line }) else { return }
        Task {
            withAnimation(animated ? .default : nil) { proxy.scrollTo(target.id, anchor: .center) }
            highlighted = target.id
            try? await Task.sleep(for: .seconds(2))
            if highlighted == target.id { withAnimation { highlighted = nil } }
        }
    }
}

private struct HunkHeaderRow: View {
    let hunk: DiffHunk

    var body: some View {
        Text(hunk.header)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.blue.opacity(0.08))
            .accessibilityLabel("Hunk starting at old line \(hunk.oldStart), new line \(hunk.newStart). \(hunk.section)")
    }
}

private struct UnifiedLineRow: View {
    let fileID: DiffFile.ID
    let line: DiffLine
    var isHighlighted = false
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            CommentGutterButton(fileID: fileID, line: line, isVisible: isHovered && line.kind != .noNewline)
            LineNumber(line.oldNumber)
            LineNumber(line.newNumber)
            Text(line.kind.marker)
                .frame(width: 16)
                .foregroundStyle(line.kind.markerColor)
            Text(displayText(line))
                .foregroundStyle(line.kind == .noNewline ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 8)
        .background(line.kind.background)
        .overlay { if isHighlighted { Color.accentColor.opacity(0.22).allowsHitTesting(false) } }
        .onHover { isHovered = $0 }
        .modifier(CommentActions(fileID: fileID, line: line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line.accessibilityDescription)
    }
}

/// Right-click "Comment on Line" plus a VoiceOver action, for when hover isn't practical.
private struct CommentActions: ViewModifier {
    let fileID: DiffFile.ID
    let line: DiffLine
    @Environment(CommentsModel.self) private var comments

    func body(content: Content) -> some View {
        if line.kind == .noNewline || !comments.canComment {
            content
        } else {
            content
                .contextMenu {
                    Button("Comment on Line") { comments.open(.line(fileID: fileID, lineID: line.id)) }
                }
                .accessibilityAction(named: "Comment on line") {
                    comments.open(.line(fileID: fileID, lineID: line.id))
                }
        }
    }
}

private struct SplitCell: View {
    enum Side { case old, new }

    let fileID: DiffFile.ID
    let line: DiffLine?
    let side: Side
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if let line {
                CommentGutterButton(fileID: fileID, line: line, isVisible: isHovered)
            } else {
                Color.clear.frame(width: 18)
            }
            LineNumber(side == .old ? line?.oldNumber : line?.newNumber)
            Text(line.map { $0.kind == .context ? " " : $0.kind.marker } ?? " ")
                .frame(width: 16)
                .foregroundStyle(line?.kind.markerColor ?? .clear)
            Text(line.map(displayText) ?? "")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(line.map { $0.kind.background } ?? Color.secondary.opacity(0.06))
        .onHover { isHovered = $0 }
        .modifier(OptionalCommentActions(fileID: fileID, line: line))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line?.accessibilityDescription ?? "No line")
    }
}

private struct LineNumber: View {
    let number: Int?

    init(_ number: Int?) {
        self.number = number
    }

    var body: some View {
        Text(number.map(String.init) ?? "")
            .monospacedDigit()
            .foregroundStyle(.tertiary)
            .frame(minWidth: 44, alignment: .trailing)
            .padding(.trailing, 6)
            .textSelection(.disabled)
    }
}

extension Locale.Language {
    /// "No linguistic content". Stops wrapped code from being hyphenated, which would
    /// show hyphens that aren't in the source.
    static let code = Locale.Language(identifier: "zxx")
}

private struct OptionalCommentActions: ViewModifier {
    let fileID: DiffFile.ID
    let line: DiffLine?

    func body(content: Content) -> some View {
        if let line {
            content.modifier(CommentActions(fileID: fileID, line: line))
        } else {
            content
        }
    }
}

/// Tabs expanded so indentation lines up.
private func displayText(_ line: DiffLine) -> String {
    line.text.replacingOccurrences(of: "\t", with: "    ")
}

extension DiffLine.Kind {
    var marker: String {
        switch self {
        case .addition: "+"
        case .deletion: "−"
        case .context: " "
        case .noNewline: "\\"
        }
    }

    var markerColor: Color {
        switch self {
        case .addition: .green
        case .deletion: .red
        case .context, .noNewline: .secondary
        }
    }

    var background: Color {
        switch self {
        case .addition: Color.green.opacity(0.14)
        case .deletion: Color.red.opacity(0.14)
        case .context, .noNewline: .clear
        }
    }
}

extension DiffLine {
    var accessibilityDescription: String {
        switch kind {
        case .addition: "Added line \(newNumber ?? 0): \(text)"
        case .deletion: "Removed line \(oldNumber ?? 0): \(text)"
        case .context: "Line \(newNumber ?? 0): \(text)"
        case .noNewline: text
        }
    }
}
