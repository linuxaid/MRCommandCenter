import SwiftData
import SwiftUI

/// Where to look: the briefing, each lane with its count, activity, and merge rules.
struct CommandSidebar: View {
    @Binding var destination: Destination
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }
    private var store: MergeRequestStore { appModel.mergeRequests }

    var body: some View {
        let lanes = center.lanes()
        List(selection: Binding<Destination?>(get: { destination }, set: { if let new = $0 { destination = new } })) {
            Section {
                row(.briefing, title: "Briefing", systemImage: "newspaper", tint: Theme.ink,
                    count: lanes[.yourMove]?.count ?? 0, countTint: Theme.yourMove)
            }
            Section("Lanes") {
                ForEach(Lane.allCases) { lane in
                    row(.lane(lane), title: lane.title, systemImage: lane.systemImage, tint: Theme.color(for: lane),
                        count: lanes[lane]?.count ?? 0, countTint: lane == .yourMove ? Theme.yourMove : nil)
                }
            }
            Section("Automation") {
                row(.activity, title: "Activity", systemImage: "clock.arrow.circlepath", tint: Theme.inkSecondary,
                    count: store.trackedMergeRequests.count(where: \.hasUnseenActivity), countTint: nil)
                rulesRow
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if appModel.needsOnboarding || store.problem == .notConfigured {
                ContentUnavailableView {
                    Label("Connect GitLab", systemImage: "key")
                } description: {
                    Text("Add your GitLab URL and a personal access token.")
                } actions: {
                    SettingsLink { Text("Open Accounts…") }
                }
                .background(.background)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RefreshStatus(store: store)
        }
    }

    private func row(_ value: Destination, title: String, systemImage: String, tint: Color, count: Int, countTint: Color?) -> some View {
        HStack {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.callout.monospacedDigit().weight(countTint == nil ? .regular : .bold))
                    .foregroundStyle(countTint == nil ? Theme.inkSecondary : .white)
                    .padding(.horizontal, countTint == nil ? 0 : 7)
                    .padding(.vertical, 1)
                    .background(countTint ?? .clear, in: .capsule)
            }
        }
        .tag(value)
        .accessibilityLabel("\(title), \(count)")
    }

    private var rulesRow: some View {
        HStack {
            Label {
                Text("Merge Rules")
            } icon: {
                Image(systemName: "wand.and.stars").foregroundStyle(Theme.autoMerge)
            }
            Spacer()
            if let badge = center.autoMergeBadge {
                Text(badge)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(badge == "Dry run" ? Theme.inkTertiary : Theme.autoMerge)
            }
        }
        .tag(Destination.rules)
    }
}

private struct RefreshStatus: View {
    let store: MergeRequestStore

    var body: some View {
        HStack(spacing: 6) {
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…")
            } else if let last = store.lastRefreshedAt {
                Circle().fill(store.problem == nil ? Theme.ready : Theme.caution).frame(width: 6, height: 6)
                TimelineView(.everyMinute) { _ in
                    Text("Updated \(last, format: .relative(presentation: .named))")
                }
                .help(last.formatted(date: .abbreviated, time: .standard))
            } else {
                Text("Not refreshed yet")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
