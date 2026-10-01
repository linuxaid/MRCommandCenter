import SwiftUI

/// The selected MR: Overview, Changes, and AI Review.
struct MRDetailView: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        Group {
            switch appModel.detailTab {
            case .overview:
                OverviewView(mr: mr)
            case .changes:
                ChangesView(mr: mr)
            case .aiReview:
                AIReviewView(mr: mr)
            }
        }
        .navigationTitle(mr.reference)
        .navigationSubtitle(mr.title)
        .toolbar {
            ToolbarItemGroup(placement: .principal) {
                Picker("Section", selection: $appModel.detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Label(tab.title, systemImage: tab.systemImage).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .help("Overview (⌘1), Changes (⌘2), AI Review (⌘3)")

                Button {
                    appModel.isInspectorPresented.toggle()
                } label: {
                    Label("Inspector", systemImage: "sidebar.trailing")
                }
                .help("Show or hide the AI run inspector (⌥⌘I)")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                AIReviewToolbarButton(mr: mr)

                Button {
                    Task { await appModel.refreshDetails(for: mr) }
                } label: {
                    Label("Refresh This MR", systemImage: "arrow.clockwise")
                }
                .disabled(appModel.mergeRequests.refreshingKeys.contains(mr.key))
                .help("Refetch this merge request now, ignoring the cache")

                if let url = URL(string: mr.webURL) {
                    Link(destination: url) {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    .help("Open in GitLab (⌘O)")
                }
            }
        }
    }
}

/// Starts, reruns, or cancels the AI review from any tab, without switching to AI Review.
private struct AIReviewToolbarButton: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    private var service: AIReviewService { appModel.aiReview }

    var body: some View {
        if let progress = service.progress[mr.key] {
            Button {
                service.cancel(mr.key)
            } label: {
                Label("Cancel AI Review (\(progress.finishedCount)/\(progress.paths.count))", systemImage: "stop.circle")
            }
            .help("AI review running: \(progress.finishedCount) of \(progress.paths.count) files. Click to cancel.")
        } else if service.needsReview(mr) {
            Button {
                service.start(mr)
            } label: {
                Label("Review with AI", systemImage: "sparkles")
            }
            .disabled(!service.modelStatus.isAvailable)
            .help(service.modelStatus.isAvailable ? "Run the on-device AI review (⌘⇧R)" : service.modelStatus.explanation)
        } else {
            Button {
                service.start(mr, rerun: true)
            } label: {
                Label("Rerun AI Review", systemImage: "arrow.clockwise.circle")
            }
            .disabled(!service.modelStatus.isAvailable)
            .help("Already reviewed at \(mr.shortSHA) with the current prompt. Click to review again.")
        }
    }
}
