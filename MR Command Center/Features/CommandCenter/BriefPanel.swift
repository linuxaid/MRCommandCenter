import AppKit
import SwiftData
import SwiftUI

/// Everything you need to know about one MR without opening it: what's happening, who has
/// to act, what changed, what stands between it and a merge, and whether a rule will merge it.
/// `.full` is the command center's detail column; `.rail` sits beside the diff in review mode.
struct BriefPanel: View {
    enum Style {
        case full, rail
    }

    let mr: TrackedMR
    var style: Style = .full
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        let situation = center.situation(for: mr)
        let tint = Theme.color(for: situation.lane)

        ScrollView {
            VStack(alignment: .leading, spacing: style == .full ? 22 : 18) {
                if style == .full {
                    header(situation)
                    actions
                    MRActionError(mr: mr)
                }
                whatsHappening(situation, tint: tint)
                if style == .full {
                    ChangesGlance(mr: mr)
                }
                ReadinessChecklist(mr: mr, readiness: situation.readiness, me: appModel.mergeRequests.username)
                AutoMergeCard(mr: mr, situation: situation)
                ContextCard(mr: mr)
                RecentActivity(mrKey: mr.key)
            }
            .padding(style == .full ? 22 : 16)
            .frame(maxWidth: 640, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
        .task(id: mr.key) {
            // Looking at the brief counts as seeing what changed.
            try? await Task.sleep(for: .seconds(1))
            appModel.mergeRequests.markSeen(mr)
        }
    }

    private func header(_ situation: MRSituation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                LanePill(lane: situation.lane)
                Spacer()
                Text("Updated \(mr.lastSeenUpdatedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }
            Text(mr.title)
                .font(Theme.headline(22))
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            MRByline(mr: mr)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            MRActionButtons(mr: mr)
            Button {
                appModel.review(mr)
            } label: {
                Label("Review Here", systemImage: "rectangle.split.2x1")
            }
            .help("Brief and changes side by side in this window (Return or ⌘↩)")
            if center.situation(for: mr).lane == .setAside {
                Button {
                    center.bringBack(mr)
                } label: {
                    Label("Bring Back", systemImage: Lane.setAside.systemImage)
                }
                .help("Put it back in Your move now")
            }
            Spacer()
            if let url = URL(string: mr.webURL) {
                Button {
                    NSWorkspace.shared.open(url)
                } label: {
                    Label("Open in GitLab", systemImage: "arrow.up.forward.app")
                        .labelStyle(.iconOnly)
                }
                .help("Open in GitLab (⌘O)")
            }
            Button {
                Task { await appModel.refreshDetails(for: mr) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .disabled(appModel.mergeRequests.refreshingKeys.contains(mr.key))
            .help("Refetch this merge request now")
        }
        .controlSize(.large)
    }

    private func whatsHappening(_ situation: MRSituation, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT'S HAPPENING").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
            Text(situation.headline)
                .font(Theme.headline(style == .full ? 19 : 17))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text("Next move")
                    .foregroundStyle(Theme.inkSecondary)
                if case .you = situation.ballWith {
                    Text("You")
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(Theme.yourMove, in: .capsule)
                } else {
                    Text(situation.ballWith.title)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.ink)
                }
            }
            .font(.callout)
            if !situation.notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(situation.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .font(.callout)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle().fill(tint).frame(width: 3)
        }
        .card()
    }
}

/// Author, reference, branches, and labels.
struct MRByline: View {
    let mr: TrackedMR

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(name: mr.authorName, size: 20)
                Text(mr.isAuthor ? "You" : mr.authorName)
                    .foregroundStyle(Theme.ink)
                Text(mr.reference)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
            }
            .font(.callout)
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
                Text(mr.sourceBranch).lineLimit(1).truncationMode(.middle)
                Image(systemName: "arrow.right").accessibilityLabel("into")
                Text(mr.targetBranch).lineLimit(1).layoutPriority(1)
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.inkSecondary)
            if !mr.labels.isEmpty {
                LabelList(labels: mr.labels, styles: mr.labelStyles)
            }
        }
    }
}

/// The shape of the change at a glance: files, sizes, and where the checks flagged something.
/// Clicking a file opens review mode at that file.
private struct ChangesGlance: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @State private var diff: MRDiff?
    @State private var error: String?
    @State private var showsAll = false

    private let visibleCount = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("WHAT CHANGED").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                Spacer()
                if let diff {
                    Text("\(diff.files.count) \(diff.files.count == 1 ? "file" : "files")")
                        .foregroundStyle(Theme.inkTertiary)
                    Text("+\(diff.additions)").foregroundStyle(Theme.ready)
                    Text("−\(diff.deletions)").foregroundStyle(Theme.danger)
                }
            }
            .font(.caption.monospacedDigit())
            Group {
                if let diff {
                    fileList(diff)
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(Theme.caution)
                        .padding(14)
                } else {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
        .task(id: "\(mr.key)@\(mr.headSHA)") {
            do {
                diff = try await appModel.diffs.diff(for: mr)
                error = nil
            } catch {
                self.error = "Couldn't load the changes: \(error.localizedDescription)"
            }
        }
    }

    private func fileList(_ diff: MRDiff) -> some View {
        let report = appModel.staticChecks.report(for: mr)
        let files = diff.files.sorted { ($0.isGenerated ? 1 : 0, -($0.additions + $0.deletions)) < ($1.isGenerated ? 1 : 0, -($1.additions + $1.deletions)) }
        let shown = showsAll ? files : Array(files.prefix(visibleCount))
        let largest = max(1, files.map { $0.additions + $0.deletions }.max() ?? 1)

        return VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { file in
                let findings = report.findings(forPath: file.path)
                Button {
                    appModel.review(mr)
                    appModel.showInDiff(mr: mr, path: file.path, line: findings.first?.line ?? firstChangedLine(file))
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: symbol(file.change))
                            .foregroundStyle(color(file.change))
                            .frame(width: 14)
                        (Text(file.directory).foregroundStyle(Theme.inkTertiary) + Text(file.fileName).foregroundStyle(Theme.ink))
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.head)
                        Spacer(minLength: 6)
                        if !findings.isEmpty {
                            Label("\(findings.count)", systemImage: "exclamationmark.shield.fill")
                                .font(.caption)
                                .foregroundStyle(Theme.caution)
                                .help("Static checks flagged \(findings.count) \(findings.count == 1 ? "line" : "lines")")
                        }
                        SizeBar(additions: file.additions, deletions: file.deletions, largest: largest)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Review \(file.path)")
                .accessibilityLabel("\(file.path), \(file.additions) added, \(file.deletions) removed")
            }
            if files.count > visibleCount {
                Button(showsAll ? "Show fewer" : "Show all \(files.count) files") {
                    withAnimation { showsAll.toggle() }
                }
                .buttonStyle(.link)
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .padding(.vertical, 4)
    }

    private func firstChangedLine(_ file: DiffFile) -> Int {
        file.hunks.lazy.flatMap(\.lines).first { $0.kind == .addition }?.newNumber ?? 1
    }

    private func symbol(_ change: DiffFile.Change) -> String {
        switch change {
        case .added: "plus.square.fill"
        case .deleted: "minus.square.fill"
        case .renamed: "arrow.right.square.fill"
        case .modified: "square.fill"
        }
    }

    private func color(_ change: DiffFile.Change) -> Color {
        switch change {
        case .added: Theme.ready
        case .deleted: Theme.danger
        case .renamed: Theme.inFlight
        case .modified: Theme.inkTertiary.opacity(0.6)
        }
    }
}

/// Added and removed lines as a small two-color bar, scaled to the largest file.
private struct SizeBar: View {
    let additions: Int
    let deletions: Int
    let largest: Int

    var body: some View {
        let width: CGFloat = 64
        let total = CGFloat(additions + deletions)
        let filled = max(4, width * min(1, total / CGFloat(largest)))
        HStack(spacing: 6) {
            Text("+\(additions) −\(deletions)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize()
            HStack(spacing: 0) {
                Rectangle().fill(Theme.ready).frame(width: total == 0 ? 0 : filled * CGFloat(additions) / total)
                Rectangle().fill(Theme.danger).frame(width: total == 0 ? 0 : filled * CGFloat(deletions) / total)
                Spacer(minLength: 0)
            }
            .frame(width: width, height: 6)
            .background(Theme.sunken, in: .capsule)
            .clipShape(.capsule)
        }
    }
}

/// The four steps to a merge, with detail.
private struct ReadinessChecklist: View {
    let mr: TrackedMR
    let readiness: Readiness
    let me: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WHAT IT NEEDS TO MERGE").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                Spacer()
                Text("\(readiness.doneCount) of \(readiness.steps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
            VStack(spacing: 0) {
                ForEach(Array(readiness.steps.enumerated()), id: \.element.id) { index, step in
                    if index > 0 { Divider().padding(.leading, 40) }
                    row(step)
                }
            }
            .card()
        }
    }

    private func row(_ step: ReadinessStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol(for: step.state))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(step.state == .unknown ? Theme.inkTertiary : Theme.color(for: step.state))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(title(step.kind)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(step.summary).foregroundStyle(Theme.inkSecondary)
                }
                .font(.callout)
                if let detail = detail(for: step) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func title(_ kind: ReadinessStep.Kind) -> String {
        switch kind {
        case .pipeline: "Pipeline"
        case .approvals: "Approvals"
        case .threads: "Threads"
        case .mergeable: "Mergeable"
        }
    }

    private func symbol(for state: ReadinessStep.State) -> String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .waiting: "clock.fill"
        case .blocked: "xmark.octagon.fill"
        case .unknown: "circle.dashed"
        }
    }

    private func detail(for step: ReadinessStep) -> String? {
        switch step.kind {
        case .pipeline:
            return mr.shortSHA.isEmpty ? nil : "Head commit \(mr.shortSHA)"
        case .approvals:
            var parts: [String] = []
            if !mr.approvedBy.isEmpty { parts.append("Approved by \(mr.approvedBy.formatted(.list(type: .and)))") }
            if mr.isReviewer, let me, !mr.approvedByUsernames.contains(me), !mr.isAuthor { parts.append("You haven't approved") }
            return parts.isEmpty ? nil : parts.joined(separator: ". ")
        case .threads:
            var parts: [String] = []
            if mr.threadsAwaitingMe > 0 { parts.append("\(mr.threadsAwaitingMe) waiting on you") }
            if mr.threadsAwaitingOthers > 0 { parts.append("\(mr.threadsAwaitingOthers) waiting on others to answer you") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ").capitalizedFirst
        case .mergeable:
            return mr.isDraft ? "Marked as a draft" : nil
        }
    }
}

/// Whether a rule (or GitLab) will merge this, and what it's waiting for.
private struct AutoMergeCard: View {
    let mr: TrackedMR
    let situation: MRSituation
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AUTOMATIC MERGE").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 8) {
                if let rule = situation.rule {
                    HStack {
                        Label("Rule “\(rule.ruleName)” covers this", systemImage: "wand.and.stars")
                            .foregroundStyle(Theme.autoMerge)
                            .fontWeight(.medium)
                        Spacer()
                        if !rule.isLive {
                            Text("DRY RUN").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    if rule.isReady {
                        Text(rule.isLive ? "Everything the rule asks for is met. It'll merge on the next check."
                                         : "Everything the rule asks for is met. Merging is off, so it'll only be reported.")
                            .foregroundStyle(Theme.inkSecondary)
                    } else {
                        Text("Will merge once:").foregroundStyle(Theme.inkSecondary)
                        ForEach(rule.unmet, id: \.self) { item in
                            Label(item.capitalizedFirst, systemImage: "circle")
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    if let error = mr.autoMergeError {
                        Label(error, systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(Theme.danger)
                    }
                    Button("Edit Rule") {
                        appModel.commandCenter.selectedRuleID = rule.ruleID
                        appModel.commandCenter.destination = .rules
                    }
                    .buttonStyle(.link)
                } else if mr.mergeWhenPipelineSucceeds {
                    Label("GitLab's auto-merge is set: it merges when the pipeline passes.", systemImage: "wand.and.stars")
                        .foregroundStyle(Theme.autoMerge)
                } else {
                    Text("No merge rule covers this merge request.")
                        .foregroundStyle(Theme.inkSecondary)
                    Button("Create a Rule Like This…") {
                        appModel.commandCenter.addRule(like: mr)
                        appModel.commandCenter.destination = .rules
                    }
                    .buttonStyle(.link)
                }
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
        }
    }
}

/// The MR's Jira issue in detail (#25): status, type, priority, fix version, and assignee,
/// with the description to expand. The AI verdict sits underneath on its own line.
private struct ContextCard: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @Query private var settingsRows: [AccountSettings]
    @State private var showsStory = false

    var body: some View {
        let summary = JiraSummary.make(for: mr, details: appModel.jira.details(for: mr.jiraKey))
        VStack(alignment: .leading, spacing: 10) {
            Text("JIRA").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
            VStack(alignment: .leading, spacing: 10) {
                switch summary.state {
                case .found:
                    found(summary)
                case .noKey(let branch):
                    message("No Jira key in branch \(branch)", systemImage: "ticket", tone: Theme.caution)
                case .notConnected:
                    HStack {
                        message("\(summary.key ?? ""): connect Jira to see its details.", systemImage: "ticket", tone: Theme.inkSecondary)
                        SettingsLink { Text("Open Accounts…") }.font(.callout)
                    }
                case .loading:
                    HStack {
                        Text(summary.key ?? "").font(.callout.monospaced())
                        ProgressView().controlSize(.small)
                    }
                case .notFound:
                    message("\(summary.key ?? "") wasn't found in Jira, or your token can't see it.",
                            systemImage: "xmark.octagon", tone: Theme.danger)
                case .failed(let error):
                    message("\(summary.key ?? ""): \(error)", systemImage: "exclamationmark.triangle", tone: Theme.caution)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            aiLine
        }
    }

    @ViewBuilder
    private func found(_ summary: JiraSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if let key = summary.key, let url = browseURL(key) {
                Link(key, destination: url)
                    .font(.callout.monospaced().weight(.semibold))
                    .help("Open \(key) in Jira")
            } else {
                Text(summary.key ?? "").font(.callout.monospaced().weight(.semibold))
            }
            if let title = summary.title {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        // Plain rows with a fixed label width: a `Grid` here caused AppKit layout loops (PLAN.md).
        VStack(alignment: .leading, spacing: 6) {
            ForEach(summary.rows) { row in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(row.label)
                        .foregroundStyle(Theme.inkSecondary)
                        .frame(width: 84, alignment: .leading)
                    Group {
                        switch row.tone {
                        case .positive:
                            Label(row.value, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                        case .warning:
                            Label(row.value, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                        case .normal:
                            Text(row.value).foregroundStyle(Theme.ink)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        if summary.hasStory {
            DisclosureGroup(isExpanded: $showsStory) {
                VStack(alignment: .leading, spacing: 10) {
                    if let description = summary.description {
                        Text(description)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let criteria = summary.acceptanceCriteria {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Acceptance criteria").fontWeight(.semibold)
                            Text(criteria).textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .padding(.top, 6)
            } label: {
                Text(summary.description != nil ? "Description" : "Acceptance criteria")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func message(_ text: String, systemImage: String, tone: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var aiLine: some View {
        let item = MRStatusLine.aiItem(for: mr)
        return HStack(spacing: 6) {
            Image(systemName: item.systemImage).foregroundStyle(item.tone.color)
            Text("AI review: \(item.title)").foregroundStyle(Theme.inkSecondary)
        }
        .font(.caption)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.accessibilityLabel)
    }

    private func browseURL(_ key: String) -> URL? {
        guard let base = try? BaseURL.normalize(settingsRows.first?.jiraBaseURL ?? "", strippingSuffixes: BaseURL.jiraSuffixes) else { return nil }
        return base.appending(path: "browse").appending(path: key)
    }
}

/// The last few things that happened to this MR.
struct RecentActivity: View {
    @Query private var events: [ActivityEvent]

    init(mrKey: String) {
        var descriptor = FetchDescriptor<ActivityEvent>(
            predicate: #Predicate { $0.mrKey == mrKey },
            sortBy: [SortDescriptor(\.date, order: .reverse)]
        )
        descriptor.fetchLimit = 8
        _events = Query(descriptor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENTLY").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
            if events.isEmpty {
                Text("Nothing has changed since the app started watching it.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkTertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(events) { event in
                        ActivityLine(event: event, showsMR: false)
                    }
                }
            }
        }
    }
}

/// One activity event: colored icon, what happened, when.
struct ActivityLine: View {
    let event: ActivityEvent
    let showsMR: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Theme.systemImage(for: event.kind))
                .font(.system(size: 13))
                .foregroundStyle(Theme.color(for: event.kind))
                .frame(width: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.message)
                    .foregroundStyle(Theme.ink)
                if showsMR {
                    Text("\(event.mrTitle) · \(event.mrReference)")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(event.date.formatted(date: .omitted, time: .shortened))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
        }
        .font(.callout)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
