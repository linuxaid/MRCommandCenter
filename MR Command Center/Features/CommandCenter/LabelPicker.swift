import SwiftUI

/// Pick an MR's labels from the project's existing ones (#27). Opened with I; each click adds
/// or removes a label right away. Esc or Done closes it.
struct LabelPicker: View {
    @State var editor: LabelEditor
    @Environment(\.dismiss) private var dismiss
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LABELS").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                Text(editor.title)
                    .font(Theme.headline(18))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
            }
            TextField("Search labels", text: $editor.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    // Return adds the best match, so a label can be added without the mouse.
                    Task { await editor.submit() }
                }
            content
            if let error = editor.error {
                Label(error, systemImage: "exclamationmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("Click a label to add or remove it. Return adds the top match.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkTertiary)
                Spacer()
                // Esc, not Return: Return belongs to the search field.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .frame(minHeight: 420)
        .background(Theme.canvas)
        .task { await editor.load() }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        switch editor.phase {
        case .loading:
            ProgressView("Loading labels…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Theme.caution)
                Button("Try Again") { Task { await editor.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            let applied = editor.applied
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(editor.visible, id: \.name) { label in
                        LabelPickerRow(label: label, isApplied: applied.contains(label.name),
                                       isBusy: editor.busy.contains(label.name)) {
                            Task { await editor.toggle(label.name) }
                        }
                    }
                }
            }
            .overlay {
                if editor.visible.isEmpty {
                    Text(editor.available.isEmpty ? "This project has no labels." : "No labels match.")
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            .frame(maxHeight: .infinity)
            .padding(4)
            .card()
        }
    }
}

private struct LabelPickerRow: View {
    let label: GitLabLabel
    let isApplied: Bool
    let isBusy: Bool
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 10) {
                Image(systemName: isApplied ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isApplied ? Theme.ready : Theme.inkTertiary)
                    .frame(width: 16)
                LabelChip(name: label.name, style: label.color.map { LabelStyle(color: $0, textColor: label.textColor) })
                if let description = label.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer()
                if isBusy { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isHovered ? Theme.sunken : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .onHover { isHovered = $0 }
        .accessibilityLabel("\(label.name), \(isApplied ? "on this merge request" : "not on this merge request")")
        .accessibilityHint(isApplied ? "Removes the label" : "Adds the label")
    }
}
