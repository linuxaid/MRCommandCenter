import AppKit
import SwiftData
import SwiftUI

/// Main window: where to look (sidebar), what's there (triage, activity, or rules), and the
/// brief for the selected MR or the rule being edited. Review mode swaps all of that for one MR,
/// brief and changes side by side.
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openSettings) private var openSettings
    @Query private var settingsRows: [AccountSettings]

    private var store: MergeRequestStore { appModel.mergeRequests }
    private var center: CommandCenter { appModel.commandCenter }

    private var pollInterval: TimeInterval {
        TimeInterval(max(1, settingsRows.first?.pollIntervalMinutes ?? 5) * 60)
    }

    var body: some View {
        Group {
            if appModel.isReviewing, let mr = store.selected {
                ReviewMode(mr: mr)
                    .transition(.opacity)
            } else {
                commandCenter
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appModel.isReviewing)
        .sheet(item: Bindable(center).mergeDraft) { draft in
            MergeSheet(draft: draft)
        }
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                RefreshButton()
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let warning = appModel.storageWarning {
                    Banner(message: warning, systemImage: "exclamationmark.triangle", style: .warning)
                }
                problemBanner
                ForEach(center.mergeFailures) { failure in
                    Banner(message: "Couldn't merge \(failure.reference) “\(failure.title)”: \(failure.message)",
                           systemImage: "xmark.octagon", style: .error, actionTitle: "Show",
                           action: { show(failure) }, dismiss: { center.dismissMergeFailure(failure) })
                }
            }
        }
        .task {
            // First launch with no tokens goes straight to Accounts.
            if appModel.needsOnboarding {
                openSettings()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !appModel.needsOnboarding else { return }
            Task { await appModel.refreshIfStale(olderThan: pollInterval) }
        }
        .onChange(of: store.selectedKey) { _, key in
            // The reviewed MR merged or closed: go back to the overview.
            if key == nil { appModel.isReviewing = false }
        }
    }

    private var commandCenter: some View {
        @Bindable var center = center

        return NavigationSplitView {
            CommandSidebar(destination: $center.destination)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            Group {
                switch center.destination {
                case .briefing, .lane:
                    TriageView(destination: center.destination)
                case .activity:
                    ActivityView()
                case .rules:
                    RulesListView()
                }
            }
            .navigationSplitViewColumnWidth(min: 360, ideal: 520)
        } detail: {
            detail
                // A fixed minimum that doesn't depend on content. Content-derived minimums made
                // AppKit loop on constraint passes and crash (see LayoutStressTests).
                .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.canvas)
        }
    }

    @ViewBuilder
    private var detail: some View {
        if center.destination == .rules {
            if let id = center.selectedRuleID, let rule = center.rules.first(where: { $0.id == id }) {
                RuleEditor(rule: rule)
                    .id(rule.id)
            } else {
                ContentUnavailableView("No Rule Selected", systemImage: "wand.and.stars",
                                       description: Text("Pick a rule to edit it, or create one."))
            }
        } else if let mr = store.selected {
            BriefPanel(mr: mr)
                .id(mr.key)
        } else if let mr = store.selectedPast {
            PastMRPanel(mr: mr)
                .id(mr.key)
        } else {
            ContentUnavailableView("Pick a Merge Request", systemImage: "text.page",
                                   description: Text("Its brief shows what's happening, what it needs, and who has to act."))
        }
    }

    /// Opens the MR whose merge failed; its brief has the same error.
    private func show(_ failure: MergeFailure) {
        center.dismissMergeFailure(failure)
        store.selectedKey = failure.mrKey
        if case .rules = center.destination { center.destination = .briefing }
    }

    @ViewBuilder
    private var problemBanner: some View {
        switch store.problem {
        case .offline:
            let since = store.lastRefreshedAt.map { " from \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
            Banner(message: "Offline. Showing cached data\(since).", systemImage: "wifi.slash", style: .warning,
                   actionTitle: "Retry") { Task { await appModel.refresh(.manual) } }
        case .credentials(let message):
            Banner(message: "GitLab rejected the token. \(message)", systemImage: "key.slash", style: .error,
                   actionTitle: "Open Accounts…") { openSettings() }
        case .failed(let message):
            Banner(message: "Refresh failed. \(message)", systemImage: "exclamationmark.triangle", style: .error,
                   actionTitle: "Retry") { Task { await appModel.refresh(.manual) } }
        case .notConfigured, nil:
            EmptyView()
        }
    }

}

extension RootView {
    /// Fixed so the window minimum never depends on content.
    static let detailMinWidth: CGFloat = 320
}

/// Refresh, with the last refresh time underneath.
private struct RefreshButton: View {
    @Environment(AppModel.self) private var appModel

    private var store: MergeRequestStore { appModel.mergeRequests }

    var body: some View {
        Button {
            Task { await appModel.refresh(.manual) }
        } label: {
            if store.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .disabled(store.isRefreshing || appModel.needsOnboarding)
        .help(helpText)
    }

    private var helpText: String {
        guard let last = store.lastRefreshedAt else { return "Refresh (⌘R)" }
        return "Refresh (⌘R). Last refreshed \(last.formatted(date: .omitted, time: .shortened))."
    }
}

#Preview {
    let model = AppModel.preview()
    RootView()
        .environment(model)
        .modelContainer(model.modelContainer)
        .frame(width: 1300, height: 800)
}
