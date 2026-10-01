import SwiftUI

/// Open MRs where the current user is a reviewer.
struct MRSidebar: View {
    @Bindable var store: MergeRequestStore
    let needsOnboarding: Bool
    let refresh: () async -> Void

    var body: some View {
        List(selection: $store.selectedKey) {
            ForEach(store.mergeRequests, id: \.key) { mr in
                MRRow(mr: mr)
                    .tag(mr.key)
            }
        }
        .overlay {
            if store.mergeRequests.isEmpty {
                emptyState
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RefreshFooter(store: store, refresh: refresh)
                .disabled(needsOnboarding)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if needsOnboarding || store.problem == .notConfigured {
            ContentUnavailableView {
                Label("Connect GitLab", systemImage: "key")
            } description: {
                Text("Add your GitLab base URL and a personal access token with the read_api scope.")
            } actions: {
                SettingsLink {
                    Text("Open Accounts…")
                }
            }
        } else if store.isRefreshing {
            ProgressView("Loading merge requests…")
        } else {
            ContentUnavailableView(
                "No Merge Requests",
                systemImage: "tray",
                description: Text("Open merge requests where you're a reviewer will appear here.")
            )
        }
    }
}

struct MRRow: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = appModel.aiReview.progress[mr.key] {
                AIBadge(text: "AI reviewing \(progress.finishedCount)/\(progress.paths.count)", tint: .purple, isProminent: true,
                        accessibilityLabel: "AI review running, \(progress.finishedCount) of \(progress.paths.count) files")
            } else if mr.aiVerdictRaw != nil {
                let item = MRStatusLine.aiItem(for: mr)
                AIBadge(text: item.title, tint: item.tone.badgeTint, isProminent: item.tone != .neutral,
                        accessibilityLabel: item.accessibilityLabel)
            }
            Text(mr.title)
                .font(.headline)
                .lineLimit(2)
            Text("\(mr.reference) · \(mr.authorName)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            FlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(MRStatusLine.items(for: mr)) { item in
                    StatusChip(item: item)
                }
            }
            if !mr.labels.isEmpty {
                LabelList(labels: mr.labels, styles: mr.labelStyles)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The AI verdict above an MR's title. Colored fill and outline, primary-color text so
/// it stays readable on any background; the sparkles icon carries the tint.
private struct AIBadge: View {
    let text: String
    let tint: Color
    let isProminent: Bool
    let accessibilityLabel: String

    var body: some View {
        Label {
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isProminent ? .primary : .secondary)
        } icon: {
            Image(systemName: "sparkles")
                .foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(isProminent ? 0.22 : 0.12), in: .capsule)
        .overlay { Capsule().strokeBorder(tint.opacity(isProminent ? 0.7 : 0.3)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct RefreshFooter: View {
    let store: MergeRequestStore
    let refresh: () async -> Void

    var body: some View {
        HStack(spacing: 8) {
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing…")
            } else if let lastRefreshedAt = store.lastRefreshedAt {
                TimelineView(.everyMinute) { _ in
                    Text("Updated \(lastRefreshedAt, format: .relative(presentation: .named))")
                }
                .help(lastRefreshedAt.formatted(date: .abbreviated, time: .standard))
            } else {
                Text("Not refreshed yet")
            }
            Spacer()
            Button {
                Task { await refresh() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh (⌘R)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }
}
