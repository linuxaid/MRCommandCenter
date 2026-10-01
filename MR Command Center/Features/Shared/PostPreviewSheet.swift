import SwiftUI

/// Editable preview shown before anything AI-written is posted to GitLab.
struct PostPreviewSheet: View {
    let title: String
    let location: String
    @Binding var text: String
    let isPostingEnabled: Bool
    let isPosting: Bool
    let error: String?
    let post: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title3.bold())
            Text(location).font(.callout.monospaced()).foregroundStyle(.secondary)
            if isPostingEnabled {
                TextEditor(text: $text)
                    .font(.body)
                    .frame(minHeight: 180)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
                    .accessibilityLabel("Comment text")
                Label("Everyone with access to the merge request will see this. The “Comment generated via MR Command Center” line is always kept.",
                      systemImage: "eye")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
                }
            } else {
                Label("Posting comments to GitLab is turned off.", systemImage: "lock")
                Text("Turn on “Allow posting comments” in Settings → Accounts. Your token needs the api scope.")
                    .font(.caption).foregroundStyle(.secondary)
                SettingsLink { Text("Open Settings…") }
            }
            HStack {
                Spacer()
                if isPosting { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Post Comment", action: post)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isPostingEnabled || isPosting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560)
    }
}
