import AppKit
import SwiftData
import SwiftUI

/// Main window: sidebar (MR list) + detail, with a toggleable inspector for AI run debugging.
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openSettings) private var openSettings
    @Query private var settingsRows: [AccountSettings]

    private var store: MergeRequestStore { appModel.mergeRequests }

    private var pollInterval: TimeInterval {
        TimeInterval(max(1, settingsRows.first?.pollIntervalMinutes ?? 5) * 60)
    }

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            MRSidebar(store: store, needsOnboarding: appModel.needsOnboarding) { await appModel.refresh(.manual) }
                .navigationSplitViewColumnWidth(min: 280, ideal: 340)
        } detail: {
            HStack(spacing: 0) {
                Group {
                    if let mr = store.selected {
                        MRDetailView(mr: mr)
                    } else {
                        ContentUnavailableView(
                            "No Merge Request Selected",
                            systemImage: "arrow.triangle.pull",
                            description: Text("Select a merge request from the sidebar.")
                        )
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

                if appModel.isInspectorPresented {
                    Divider()
                    InspectorPanel()
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 300, maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.default, value: appModel.isInspectorPresented)
            // A fixed minimum that doesn't depend on content. Content-derived minimums, and
            // SwiftUI's `.inspector` (which reserves ~600 pt and can't grow the window), made
            // AppKit loop on constraint passes and crash with all panels open.
            .frame(minWidth: Self.detailMinWidth, maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(item: Bindable(appModel.summaryPoster).draft) { _ in
            SummaryPreviewSheet(poster: appModel.summaryPoster)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if let warning = appModel.storageWarning {
                    Banner(message: warning, systemImage: "exclamationmark.triangle", style: .warning)
                }
                problemBanner
            }
        }
        .task {
            // First launch with no tokens goes straight to Accounts.
            if appModel.needsOnboarding {
                openSettings()
            }
        }
        .task(id: PollConfiguration(interval: pollInterval, enabled: !appModel.needsOnboarding)) {
            await poll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard !appModel.needsOnboarding else { return }
            Task { await appModel.refreshIfStale(olderThan: pollInterval) }
        }
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

    /// Refreshes on appear, then every poll interval while the app is active.
    private func poll() async {
        guard !appModel.needsOnboarding else { return }
        await appModel.refresh(.automatic)
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: .seconds(pollInterval))
            } catch {
                return
            }
            if NSApplication.shared.isActive {
                await appModel.refresh(.automatic)
            }
        }
    }
}

extension RootView {
    /// Fixed so the window minimum never depends on content (sidebar 280 + this).
    static let detailMinWidth: CGFloat = 320
}

private struct PollConfiguration: Equatable {
    let interval: TimeInterval
    let enabled: Bool
}

#Preview {
    let model = AppModel.preview()
    RootView()
        .environment(model)
        .modelContainer(model.modelContainer)
        .frame(width: 1100, height: 700)
}

/// Preview of the AI summary thread before it's posted to the MR.
private struct SummaryPreviewSheet: View {
    @Bindable var poster: SummaryPoster

    var body: some View {
        PostPreviewSheet(
            title: "Post AI Summary to the Merge Request",
            location: poster.draft?.location ?? "",
            text: Binding(get: { poster.draft?.body ?? "" }, set: { poster.draft?.body = $0 }),
            isPostingEnabled: poster.isPostingEnabled,
            isPosting: poster.isPosting,
            error: poster.error,
            post: { Task { await poster.post() } },
            cancel: { poster.draft = nil }
        )
    }
}
