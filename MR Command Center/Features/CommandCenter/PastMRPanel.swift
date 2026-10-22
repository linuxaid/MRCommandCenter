import SwiftUI

/// A merged or closed MR opened from Activity, read only: what it was, what happened to it,
/// and a way back to GitLab (to comment there, for example). Nothing here acts on the MR.
struct PastMRPanel: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Button {
                    appModel.mergeRequests.openSelectedInBrowser()
                } label: {
                    Label("Open in GitLab", systemImage: "arrow.up.forward.app")
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(URL(string: mr.webURL) == nil)
                .help("Open in GitLab (⌘O)")
                if !description.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DESCRIPTION").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                RecentActivity(mrKey: mr.key)
            }
            .padding(22)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }

    private var description: String {
        mr.descriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Merged or closed", systemImage: "archivebox")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Theme.sunken, in: .capsule)
                Spacer()
                Text("Last updated \(mr.lastSeenUpdatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
            Text(mr.title)
                .font(Theme.headline(22))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            MRByline(mr: mr)
            Text("Read only. This is how it looked at the last refresh before it left your list.")
                .font(.caption)
                .foregroundStyle(Theme.inkTertiary)
        }
    }
}
