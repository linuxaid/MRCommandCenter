import AppKit
import SwiftUI

/// The menu bar icon: the merge symbol, plus how many MRs are waiting on you (nothing when zero).
struct MenuBarLabel: View {
    let center: CommandCenter

    var body: some View {
        let count = center.lanes()[.yourMove]?.count ?? 0
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.merge")
            if count > 0 {
                Text("\(count)").monospacedDigit()
            }
        }
        .accessibilityLabel(count == 0 ? "MR Command Center, nothing waiting on you" : "MR Command Center, \(count) waiting on you")
    }
}

/// The menu bar panel: what's waiting on you, a one-line summary of the rest, and refresh status.
/// Clicking an MR opens it in the main window; acting on it happens there.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    private var center: CommandCenter { appModel.commandCenter }
    private var store: MergeRequestStore { appModel.mergeRequests }

    var body: some View {
        let lanes = center.lanes()
        let yours = lanes[.yourMove] ?? []

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("YOUR MOVE").font(Theme.eyebrow).foregroundStyle(Theme.yourMove)
                Text(headline(yours.count))
                    .font(Theme.headline(17))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if yours.isEmpty {
                Label("You're all caught up.", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Theme.ready)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(yours, id: \.key) { mr in
                            PanelRow(mr: mr, headline: center.situation(for: mr).headline) { open(mr) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if let summary = summary(lanes) {
                Button {
                    open(nil)
                } label: {
                    HStack {
                        Text(summary)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.callout)
                    .foregroundStyle(Theme.inkSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Open the briefing")
                Divider()
            }

            footer
        }
        .frame(width: 360)
        .background(Theme.canvas)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…")
            } else if let last = store.lastRefreshedAt {
                Circle().fill(store.problem == nil ? Theme.ready : Theme.caution).frame(width: 6, height: 6)
                Text("Updated \(last, format: .relative(presentation: .named))")
            } else {
                Text("Not refreshed yet")
            }
            if appModel.activityKeeper.isActive {
                Text("·")
                Circle().fill(Theme.autoMerge).frame(width: 6, height: 6)
                Text("Keeping Mac awake")
                    .help("Settings → General → Keep this Mac awake while the app is open")
            }
            Spacer()
            Button {
                Task { await appModel.refresh(.manual) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing || appModel.needsOnboarding)
            .help("Refresh")
            Button("Open") { open(nil) }
                .controlSize(.small)
        }
        .font(.caption)
        .foregroundStyle(Theme.inkSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func headline(_ count: Int) -> String {
        switch count {
        case 0: "Nothing needs you right now."
        case 1: "One merge request needs you."
        default: "\(count) merge requests need you."
        }
    }

    private func summary(_ lanes: [Lane: [TrackedMR]]) -> String? {
        func count(_ lane: Lane) -> Int { lanes[lane]?.count ?? 0 }
        var parts: [String] = []
        if count(.readyToMerge) > 0 { parts.append("\(count(.readyToMerge)) ready to merge") }
        if count(.autoMerge) > 0 { parts.append("\(count(.autoMerge)) merging on their own") }
        if count(.inFlight) > 0 { parts.append("\(count(.inFlight)) in flight") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ").capitalizedFirst
    }

    /// Brings up the main window on the briefing, with the MR's brief when given.
    private func open(_ mr: TrackedMR?) {
        NSApp.keyWindow?.close()
        appModel.isReviewing = false
        center.destination = .briefing
        if let mr { store.selectedKey = mr.key }
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct PanelRow: View {
    let mr: TrackedMR
    let headline: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Avatar(name: mr.authorName, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(headline)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.yourMove)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if mr.hasUnseenActivity {
                            Circle().fill(Theme.yourMove).frame(width: 6, height: 6)
                        }
                    }
                    Text(mr.title)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(mr.reference)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Theme.surface : Theme.surface.opacity(0.6), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(isHovered ? Theme.yourMove.opacity(0.5) : Theme.hairline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Open in MR Command Center")
        .accessibilityLabel("\(headline): \(mr.title), \(mr.reference)")
    }
}
