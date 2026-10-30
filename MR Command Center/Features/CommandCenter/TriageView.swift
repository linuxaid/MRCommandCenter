import AppKit
import SwiftUI

/// The briefing (every lane) or a single lane, as a column of MR cards.
struct TriageView: View {
    let destination: Destination
    @Environment(AppModel.self) private var appModel
    @FocusState private var isFocused: Bool

    private var center: CommandCenter { appModel.commandCenter }
    private var store: MergeRequestStore { appModel.mergeRequests }

    var body: some View {
        let lanes = center.lanes()
        let shown = center.lanesShown(for: destination)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if destination == .briefing {
                        BriefingHeader(lanes: lanes)
                    } else if case .lane(let lane) = destination {
                        LaneTitle(lane: lane, count: lanes[lane]?.count ?? 0)
                    }
                    if shown.contains(where: { !(lanes[$0] ?? []).isEmpty }) {
                        LaneOrderMenu()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, -16)
                    }
                    ForEach(shown) { lane in
                        let items = lanes[lane] ?? []
                        if destination != .briefing || !items.isEmpty {
                            LaneSection(lane: lane, items: items, showsHeader: destination == .briefing)
                        }
                    }
                    if destination == .briefing, let drafts = lanes[.drafts], !drafts.isEmpty {
                        Button {
                            center.destination = .lane(.drafts)
                        } label: {
                            Label("\(drafts.count) \(drafts.count == 1 ? "draft" : "drafts") not shown", systemImage: "pencil.line")
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.inkSecondary)
                    }
                    if destination == .briefing, let parked = lanes[.setAside], !parked.isEmpty {
                        Button {
                            center.destination = .lane(.setAside)
                        } label: {
                            Label("\(parked.count) set aside", systemImage: Lane.setAside.systemImage)
                        }
                        .buttonStyle(.link)
                        .foregroundStyle(Theme.inkSecondary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.selectedKey) { _, key in
                guard let key else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key) }
            }
        }
        .background(Theme.canvas)
        .overlay {
            if store.trackedMergeRequests.isEmpty && !appModel.needsOnboarding {
                if store.isRefreshing {
                    ProgressView("Loading merge requests…")
                } else {
                    ContentUnavailableView("Nothing Open", systemImage: "tray",
                                           description: Text("Merge requests you review or opened will appear here."))
                }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.downArrow) { center.selectNext(); return .handled }
        .onKeyPress(.upArrow) { center.selectPrevious(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "iI")) { press in
            guard CommandCenter.opensLabelPicker(modifiers: press.modifiers, isComposing: false),
                  let mr = store.selected else { return .ignored }
            center.editLabels(mr)
            return .handled
        }
        .onKeyPress(.return) {
            guard let mr = store.selected else { return .ignored }
            appModel.review(mr)
            return .handled
        }
        .onAppear { isFocused = true }
    }
}

/// Easiest first (the default) or the order from before difficulty scores (#36).
private struct LaneOrderMenu: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let center = appModel.commandCenter
        Picker("Sort", selection: Binding(get: { center.laneOrder }, set: { center.laneOrder = $0 })) {
            ForEach(LaneOrder.allCases) { order in
                Text(order.title).tag(order)
            }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .controlSize(.small)
        .help("How merge requests are ordered inside each section")
    }
}

/// "Tuesday, October 20 — 3 merge requests need you."
private struct BriefingHeader: View {
    let lanes: [Lane: [TrackedMR]]

    var body: some View {
        let yours = lanes[.yourMove]?.count ?? 0
        VStack(alignment: .leading, spacing: 8) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                .font(Theme.eyebrow)
                .foregroundStyle(Theme.inkTertiary)
            Text(headline(yours))
                .font(Theme.headline(30))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subline)
                .font(.system(size: 14))
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle().fill(Theme.ink).frame(height: 2).padding(.top, 6)
        }
        .accessibilityElement(children: .combine)
    }

    private func headline(_ count: Int) -> String {
        switch count {
        case 0: "Nothing needs you right now."
        case 1: "One merge request needs you."
        default: "\(count) merge requests need you."
        }
    }

    private var subline: String {
        func count(_ lane: Lane) -> Int { lanes[lane]?.count ?? 0 }
        var parts: [String] = []
        if count(.readyToMerge) > 0 { parts.append("\(count(.readyToMerge)) ready to merge") }
        if count(.autoMerge) > 0 { parts.append("\(count(.autoMerge)) merging on their own") }
        if count(.inFlight) > 0 { parts.append("\(count(.inFlight)) moving along without you") }
        return parts.isEmpty ? "Your queue is clear." : parts.joined(separator: " · ").capitalizedFirst + "."
    }
}

private struct LaneTitle: View {
    let lane: Lane
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LanePill(lane: lane)
            Text("\(count) \(count == 1 ? "merge request" : "merge requests")")
                .font(Theme.headline(26))
                .foregroundStyle(Theme.ink)
            Text(lane.subtitle)
                .foregroundStyle(Theme.inkSecondary)
            if lane == .readyToMerge || lane == .autoMerge {
                MergeReadyReviewsToggle()
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
    }
}

/// The switch for merging ready MRs you're reviewing (issue #7). On a lane page and the Merge Rules page.
struct MergeReadyReviewsToggle: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        let center = appModel.commandCenter
        Toggle("Merge ready MRs I'm reviewing automatically",
               isOn: Binding(get: { center.mergesReadyReviews }, set: { center.setMergesReadyReviews($0) }))
            .toggleStyle(.switch)
            .tint(Theme.autoMerge)
            .help("On the next refresh, merges each MR you're reviewing that's in Ready to merge, at the commit that was checked, with your last squash and delete-branch choices. It merges for real even while rules are a dry run. MRs you opened, and ones your merge rules cover, are left alone.")
    }
}

private struct LaneSection: View {
    let lane: Lane
    let items: [TrackedMR]
    let showsHeader: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(lane.title.uppercased())
                        .font(Theme.eyebrow)
                        .foregroundStyle(Theme.color(for: lane))
                    Text("\(items.count)")
                        .font(Theme.eyebrow)
                        .foregroundStyle(Theme.inkTertiary)
                    Text(lane.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .accessibilityAddTraits(.isHeader)
            }
            if items.isEmpty {
                Text(emptyText)
                    .foregroundStyle(Theme.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(Theme.sunken.opacity(0.6), in: .rect(cornerRadius: 10))
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(items, id: \.key) { mr in
                        TriageRow(mr: mr)
                            .id(mr.key)
                    }
                }
            }
        }
    }

    private var emptyText: String {
        switch lane {
        case .yourMove: "Nothing is waiting on you."
        case .readyToMerge: "Nothing is ready to merge."
        case .autoMerge: "No merge rule covers an open MR. Create one under Merge Rules."
        case .inFlight: "Nothing in flight."
        case .drafts: "No drafts."
        case .setAside: "Nothing set aside. Right-click an MR in Your move to park it until something new happens."
        }
    }
}

/// One MR: what's happening (the headline), what it is, and how close it is to merging.
struct TriageRow: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var store: MergeRequestStore { appModel.mergeRequests }

    var body: some View {
        let situation = appModel.commandCenter.situation(for: mr)
        let tint = Theme.color(for: situation.lane)
        let isSelected = store.selectedKey == mr.key
        let style = CardSelectionStyle.style(isSelected: isSelected)
        let selectionColor = Theme.selectionColor(for: situation.lane)

        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                DifficultyBadge(difficulty: mr.difficulty)
                Avatar(name: mr.authorName, size: 28)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(situation.headline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if appModel.commandCenter.mergingKeys.contains(mr.key) {
                        ProgressView().controlSize(.mini)
                    }
                    if mr.hasUnseenActivity {
                        Circle().fill(Theme.yourMove).frame(width: 7, height: 7)
                            .help("Something changed since you last looked")
                    }
                    Text(mr.lastSeenUpdatedAt.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated)))
                        .font(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize()
                }
                Text(mr.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(mr.reference)
                        .font(.system(size: 11, design: .monospaced))
                    Text("·")
                    Text(mr.isAuthor ? "Yours" : mr.authorName)
                    if let rule = situation.rule {
                        Label(rule.ruleName, systemImage: "wand.and.stars")
                            .foregroundStyle(Theme.autoMerge)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
                ReadinessRail(readiness: situation.readiness)
                    .frame(maxWidth: 360)
                    .padding(.top, 3)
            }
        }
        .padding(.vertical, 12)
        .padding(.leading, style.contentLeadingInset)
        // Room for the chevron in every state, so selecting a row doesn't shift its text.
        .padding(.trailing, style.contentTrailingInset)
        .overlay(alignment: .trailing) {
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(selectionColor)
                .padding(.trailing, 12)
                .opacity(style.showsMarker ? 1 : 0)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10)
                .fill(isSelected ? selectionColor : tint)
                .frame(width: style.accentBarWidth)
        }
        .card(isSelected: isSelected, accent: selectionColor)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isSelected)
        .contentShape(.rect)
        .onTapGesture { store.selectedKey = mr.key }
        .simultaneousGesture(TapGesture(count: 2).onEnded { appModel.review(mr) })
        .help("Double-click to review it here")
        .contextMenu { RowMenu(mr: mr) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { store.selectedKey = mr.key }
    }
}

private struct RowMenu: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Button("Review Here") { appModel.review(mr) }
        if !mr.isAuthor, let me = appModel.mergeRequests.username, !mr.approvedByUsernames.contains(me) {
            Button("Approve") { Task { await appModel.commandCenter.approve(mr) } }
        }
        Button("Labels…") { appModel.commandCenter.editLabels(mr) }
        Button("Merge…") { appModel.commandCenter.requestMerge(mr) }
            .disabled(mr.isDraft || !mr.hasLoadedDetails)
        Divider()
        switch appModel.commandCenter.situation(for: mr).lane {
        case .yourMove:
            Button("Set Aside") { appModel.commandCenter.setAside(mr) }
        case .setAside:
            Button("Bring Back to Your Move") { appModel.commandCenter.bringBack(mr) }
        default:
            EmptyView()
        }
        Divider()
        if let url = URL(string: mr.webURL) {
            Button("Open in GitLab") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Create Merge Rule Like This…") {
            appModel.commandCenter.addRule(like: mr)
            appModel.commandCenter.destination = .rules
        }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(mr.webURL, forType: .string)
        }
    }
}
