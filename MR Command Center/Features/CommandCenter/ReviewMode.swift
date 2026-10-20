import AppKit
import SwiftUI

/// One MR fills the window: the brief as a rail on the left, its changes (or AI review, or
/// details) on the right. Arrows step through the queue; Esc goes back to the command center.
struct ReviewMode: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        VStack(spacing: 0) {
            ReviewHeaderBar(mr: mr)
            Divider()
            HStack(spacing: 0) {
                BriefPanel(mr: mr, style: .rail)
                    .frame(width: Self.railWidth)
                    .id(mr.key)
                Divider()
                Group {
                    switch appModel.detailTab {
                    case .changes: ChangesView(mr: mr)
                    case .aiReview: AIReviewView(mr: mr)
                    case .overview: OverviewView(mr: mr)
                    }
                }
                .id(mr.key)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface)

                if appModel.isInspectorPresented {
                    Divider()
                    InspectorPanel()
                        .frame(minWidth: 220, idealWidth: 300, maxWidth: 300, maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(.default, value: appModel.isInspectorPresented)
        }
        .background(Theme.canvas)
        .sheet(item: Bindable(appModel.summaryPoster).draft) { _ in
            SummaryPreviewSheet(poster: appModel.summaryPoster)
        }
    }

    /// Fixed so the window minimum never depends on content (see LayoutStressTests).
    static let railWidth: CGFloat = 330
}

/// Back, which MR this is (and where it sits in the queue), the section picker, and actions.
private struct ReviewHeaderBar: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        @Bindable var appModel = appModel
        let order = center.orderedKeys(for: center.destination)
        let position = order.firstIndex(of: mr.key)
        let lane = center.situation(for: mr).lane

        HStack(spacing: 12) {
            Button {
                appModel.isReviewing = false
            } label: {
                Label("Briefing", systemImage: "chevron.left")
            }
            .keyboardShortcut(.cancelAction)
            .help("Back to the command center (Esc)")

            ControlGroup {
                Button { center.selectPrevious() } label: { Label("Previous", systemImage: "chevron.up") }
                    .disabled(position == nil || position == 0)
                Button { center.selectNext() } label: { Label("Next", systemImage: "chevron.down") }
                    .disabled(position == nil || position == order.count - 1)
            }
            .fixedSize()
            .help("Previous or next merge request (⌥⌘↑ / ⌥⌘↓)")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Theme.color(for: lane)).frame(width: 7, height: 7)
                    Text(mr.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(mr.reference).font(.system(size: 11, design: .monospaced))
                    Text("·")
                    Text(mr.isAuthor ? "Yours" : mr.authorName)
                    if let position {
                        Text("·")
                        Text("\(position + 1) of \(order.count)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Picker("Section", selection: $appModel.detailTab) {
                ForEach(DetailTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Changes (⌘1), AI Review (⌘2), Details (⌘3)")

            AIReviewButton(mr: mr)

            Button {
                appModel.isInspectorPresented.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
                    .labelStyle(.iconOnly)
            }
            .help("Show or hide the AI run inspector (⌥⌘I)")

            if let url = URL(string: mr.webURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in GitLab", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ink)
                .help("Approve and merge in GitLab (⌘O)")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.surface)
    }
}

/// Starts, reruns, or cancels the AI review.
private struct AIReviewButton: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    private var service: AIReviewService { appModel.aiReview }

    var body: some View {
        if let progress = service.progress[mr.key] {
            Button {
                service.cancel(mr.key)
            } label: {
                Label("\(progress.finishedCount)/\(progress.paths.count)", systemImage: "stop.circle")
            }
            .help("AI review running: \(progress.finishedCount) of \(progress.paths.count) files. Click to cancel.")
        } else if service.needsReview(mr) {
            Button {
                service.start(mr)
            } label: {
                Label("Review with AI", systemImage: "sparkles")
                    .labelStyle(.iconOnly)
            }
            .disabled(!service.modelStatus.isAvailable)
            .help(service.modelStatus.isAvailable ? "Run the on-device AI review (⌘⇧R)" : service.modelStatus.explanation)
        } else {
            Button {
                service.start(mr, rerun: true)
            } label: {
                Label("Rerun AI Review", systemImage: "arrow.clockwise.circle")
                    .labelStyle(.iconOnly)
            }
            .disabled(!service.modelStatus.isAvailable)
            .help("Already reviewed at \(mr.shortSHA) with the current prompt. Click to review again.")
        }
    }
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
