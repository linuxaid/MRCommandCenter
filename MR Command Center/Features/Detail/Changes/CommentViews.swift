import SwiftUI

/// Threads and an open comment box for one diff line. Empty when there's neither.
struct LineThreads: View {
    let fileID: DiffFile.ID
    let line: DiffLine
    @Environment(CommentsModel.self) private var comments

    var body: some View {
        let threads = comments.threads(fileID: fileID, lineID: line.id)
        let ai = comments.showsAI ? comments.aiConcerns(fileID: fileID, lineID: line.id) : []
        let target = CommentTarget.line(fileID: fileID, lineID: line.id)
        if !threads.isEmpty || !ai.isEmpty || comments.activeTarget == target {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(ai) { AIConcernCard(concern: $0, fileID: fileID, lineID: line.id) }
                ForEach(threads) { ThreadView(discussion: $0) }
                if comments.activeTarget == target {
                    CommentComposer(target: target, prompt: "Comment on line \(line.newNumber ?? line.oldNumber ?? 0)", submitTitle: "Comment")
                }
            }
            .padding(.vertical, 6)
            .padding(.leading, 64)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Threads that can't sit on a visible line: on lines outside the shown hunks, or outdated.
struct FileLevelThreads: View {
    let fileID: DiffFile.ID
    @Environment(CommentsModel.self) private var comments

    var body: some View {
        let threads = comments.placement.threads(for: fileID)
        let ai = comments.showsAI ? comments.unplacedAIConcerns(fileID: fileID) : []
        if !threads.offDiff.isEmpty || !threads.outdated.isEmpty || !ai.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if !ai.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("AI notes not tied to a shown line (\(ai.count))", systemImage: "sparkles")
                            .font(.callout.weight(.medium))
                        ForEach(ai) { AIConcernCard(concern: $0, fileID: fileID, lineID: nil) }
                    }
                }
                if !threads.offDiff.isEmpty {
                    ThreadGroup(title: "Comments on lines not shown in this diff", systemImage: "text.bubble",
                                threads: threads.offDiff, id: ThreadGroupID(fileID: fileID, kind: .offDiff))
                }
                if !threads.outdated.isEmpty {
                    ThreadGroup(title: "Outdated comments (left on an earlier version)", systemImage: "clock.arrow.circlepath",
                                threads: threads.outdated, id: ThreadGroupID(fileID: fileID, kind: .outdated))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .typesettingLanguage(Locale.current.language)
        }
    }
}

private struct ThreadGroup: View {
    let title: String
    let systemImage: String
    let threads: [GitLabDiscussion]
    let id: ThreadGroupID
    /// Open or folded comes only from `CommentsModel`, which is tested; no `@State` here.
    @Environment(CommentsModel.self) private var comments

    var body: some View {
        let isExpanded = Binding { comments.isGroupExpanded(id) } set: { comments.setGroupExpanded(id, $0) }
        DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(threads) { thread in
                    VStack(alignment: .leading, spacing: 4) {
                        if let position = thread.position {
                            Text(lineDescription(position))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        ThreadView(discussion: thread)
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            Label("\(title) (\(threads.count))", systemImage: systemImage)
                .font(.callout.weight(.medium))
        }
    }

    private func lineDescription(_ position: GitLabNotePosition) -> String {
        let path = position.newPath ?? position.oldPath ?? ""
        if let line = position.newLine { return "\(path):\(line)" }
        if let line = position.oldLine { return "\(path):\(line) (removed line)" }
        return path
    }
}

/// One comment thread. Every thread starts open; resolved ones can be folded from their header.
struct ThreadView: View {
    let discussion: GitLabDiscussion
    @Environment(CommentsModel.self) private var comments

    /// Fold state lives only in `CommentsModel` (tested there); don't add a local default here.
    private var isExpanded: Bool {
        !discussion.isResolved || comments.isExpanded(discussion)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if discussion.isResolved {
                resolvedHeader
            }
            if isExpanded {
                ForEach(discussion.userNotes) { note in
                    NoteView(note: note)
                }
                HStack(spacing: 12) {
                    replyArea
                    if discussion.isResolvable && comments.activeTarget != .reply(discussionID: discussion.id) {
                        resolveButton
                    }
                }
                if let error = comments.resolveErrors[discussion.id] {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: 720, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(discussion.isUnresolved ? Color.orange.opacity(0.6) : Color.secondary.opacity(0.3))
        }
        .font(.callout)
        .typesettingLanguage(Locale.current.language)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(discussion.isResolved ? "Resolved comment thread" : "Comment thread")
    }

    private var resolvedHeader: some View {
        Button {
            comments.toggleExpanded(discussion)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .accessibilityHidden(true)
                Label("Resolved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                let first = discussion.userNotes.first
                Text("\(first?.author?.name ?? "Someone"): \(first?.body ?? "")")
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                if discussion.userNotes.count > 1 {
                    Text("· \(discussion.userNotes.count) comments")
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint(isExpanded ? "Collapse thread" : "Expand thread")
    }

    private var resolveButton: some View {
        let resolve = !discussion.isResolved
        return Button {
            Task { await comments.setResolved(discussion, resolve) }
        } label: {
            Label(resolve ? "Resolve" : "Reopen", systemImage: resolve ? "checkmark.circle" : "arrow.uturn.backward.circle")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(comments.resolvingIDs.contains(discussion.id))
        .help(resolve ? "Mark this thread resolved on GitLab" : "Reopen this thread on GitLab")
    }

    @ViewBuilder
    private var replyArea: some View {
        let target = CommentTarget.reply(discussionID: discussion.id)
        if comments.activeTarget == target {
            CommentComposer(target: target, prompt: "Reply", submitTitle: "Reply")
        } else {
            Button {
                comments.open(target)
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

private struct NoteView: View {
    let note: GitLabDiscussion.Note

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(note.author?.name ?? "Unknown").bold()
                if let username = note.author?.username {
                    Text("@\(username)").foregroundStyle(.secondary)
                }
                if let date = note.createdAt {
                    Text(date, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .font(.caption)
            Text(Self.render(note.body ?? ""))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    /// Inline Markdown (bold, code, links) with line breaks preserved.
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// Text box for a new thread or a reply. ⌘↩ posts, Esc cancels.
struct CommentComposer: View {
    let target: CommentTarget
    let prompt: String
    let submitTitle: String
    @Environment(CommentsModel.self) private var comments
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if comments.isPostingEnabled {
                editor
            } else {
                postingDisabledNotice
            }
        }
        .padding(10)
        .frame(maxWidth: 720, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.6))
        }
        .font(.callout)
        .typesettingLanguage(Locale.current.language)
        .onAppear {
            comments.refreshPostingEnabled()
            isFocused = true
        }
    }

    private var draft: Binding<String> {
        Binding(
            get: { comments.drafts[target] ?? "" },
            set: { comments.drafts[target] = $0 }
        )
    }

    private var isPosting: Bool { comments.postingTarget == target }
    private var isEmpty: Bool { (comments.drafts[target] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @ViewBuilder
    private var editor: some View {
        TextEditor(text: draft)
            .font(.body)
            .focused($isFocused)
            .frame(minHeight: 64, maxHeight: 200)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(prompt)
            .disabled(isPosting)
        if let error = comments.postErrors[target] {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
        HStack {
            Text("Markdown supported · ⌘↩ to post")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if isPosting {
                ProgressView().controlSize(.small)
            }
            Button("Cancel", role: .cancel) { comments.cancel(target) }
                .keyboardShortcut(.cancelAction)
                .disabled(isPosting)
            Button(submitTitle) {
                Task { await comments.submit(target) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(isEmpty || isPosting)
        }
        .controlSize(.small)
    }

    private var postingDisabledNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Posting comments to GitLab is turned off.", systemImage: "lock")
            Text("Turn on “Allow posting comments” in Settings → Accounts. Your token needs the api scope.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                SettingsLink { Text("Open Settings…") }
                Button("Cancel") { comments.cancel(target) }
            }
            .controlSize(.small)
        }
    }
}

/// Hover-revealed "+" in the line gutter that opens a comment box for that line.
struct CommentGutterButton: View {
    let fileID: DiffFile.ID
    let line: DiffLine
    let isVisible: Bool
    @Environment(CommentsModel.self) private var comments

    var body: some View {
        Button {
            comments.open(.line(fileID: fileID, lineID: line.id))
        } label: {
            Image(systemName: "plus.bubble.fill")
                .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.borderless)
        .help("Comment on this line")
        .opacity(isVisible && comments.canComment ? 1 : 0)
        .disabled(!comments.canComment)
        .accessibilityLabel("Comment on line \(line.newNumber ?? line.oldNumber ?? 0)")
        .frame(width: 18)
    }
}

/// An AI concern shown in the diff. Styled apart from human comments, and only posted to
/// GitLab after an editable preview.
struct AIConcernCard: View {
    let concern: ConcernRecord
    let fileID: DiffFile.ID
    /// Nil when the concern couldn't be placed on a diff line (it can't be posted then).
    let lineID: DiffLine.ID?
    @Environment(CommentsModel.self) private var comments
    @State private var showsDismissed = false

    var body: some View {
        if concern.dismissedAt != nil && !showsDismissed {
            HStack(spacing: 6) {
                Label("Dismissed AI comment", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
                Text(concern.explanation).lineLimit(1).foregroundStyle(.tertiary)
                Spacer()
                Button("Show") { showsDismissed = true }.buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.horizontal, 10)
            .frame(maxWidth: 720, alignment: .leading)
        } else {
            card
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("AI", systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(.purple)
                Text(concern.severity.rawValue.capitalized)
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(concern.severity.color.opacity(0.18), in: .capsule)
                    .foregroundStyle(concern.severity.color)
                if lineID == nil {
                    Text(concern.lineHint).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let postedAt = concern.postedAt {
                    Label("Posted \(postedAt.formatted(.relative(presentation: .named)))", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Button(concern.dismissedAt == nil ? "Dismiss" : "Restore") {
                        comments.setDismissed(concern, concern.dismissedAt == nil)
                        showsDismissed = false
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help(concern.dismissedAt == nil ? "Hide this AI comment; it no longer counts as open" : "Count this AI comment as open again")
                    if let lineID, concern.dismissedAt == nil {
                        Button("Post to GitLab…") { comments.previewPost(concern, fileID: fileID, lineID: lineID) }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                            .disabled(!comments.canComment)
                    }
                }
            }
            Text(concern.explanation)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("On-device AI review · not posted unless you choose to")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(concern.postedAt == nil ? 1 : 0)
        }
        .padding(10)
        .frame(maxWidth: 720, alignment: .leading)
        .background(Color.purple.opacity(0.07), in: .rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(Color.purple.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .font(.callout)
        .typesettingLanguage(Locale.current.language)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AI concern, \(concern.severity.rawValue) severity")
    }
}

/// Preview and confirm before an AI concern becomes a GitLab comment.
struct AIPostPreviewSheet: View {
    @Bindable var comments: CommentsModel
    let location: String

    var body: some View {
        PostPreviewSheet(
            title: "Post AI Comment to GitLab",
            location: location,
            text: Binding(get: { comments.aiPostDraft?.body ?? "" }, set: { comments.aiPostDraft?.body = $0 }),
            isPostingEnabled: comments.isPostingEnabled,
            isPosting: comments.isPostingAI,
            error: comments.aiPostError,
            post: { Task { await comments.postAIDraft() } },
            cancel: { comments.aiPostDraft = nil }
        )
    }
}
