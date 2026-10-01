import SwiftUI

struct AIReviewView: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @State private var selectedRunID: UUID?

    private var service: AIReviewService { appModel.aiReview }

    var body: some View {
        let runs = service.runs(for: mr.key)
        let run = runs.first { $0.id == selectedRunID } ?? runs.first
        let progress = service.progress[mr.key]

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !service.modelStatus.isAvailable {
                    ModelStatusBanner(status: service.modelStatus)
                }
                StaticChecksBrief(report: appModel.staticChecks.report(for: mr)) {
                    appModel.detailTab = .overview
                }
                ReviewHeader(mr: mr, run: run, runs: runs, progress: progress, selectedRunID: $selectedRunID)
                if let progress {
                    ReviewProgressList(progress: progress)
                }
                if let run, progress == nil || run.status != .running {
                    RunDetail(mr: mr, run: run)
                } else if run == nil && progress == nil && service.modelStatus.isAvailable {
                    ContentUnavailableView {
                        Label("Not Reviewed Yet", systemImage: "sparkles")
                    } description: {
                        Text("Reviews each changed file on this Mac, then combines the findings into a verdict.")
                    } actions: {
                        Button("Run AI Review") { service.start(mr) }
                            .keyboardShortcut("r", modifiers: [.command, .shift])
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { service.refreshStatus() }
        .onChange(of: mr.key) { selectedRunID = nil }
    }
}

private struct ModelStatusBanner: View {
    let status: ModelStatus

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label(status.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
                Text(status.explanation)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The static result is shown first so it isn't drowned out by the model's opinion.
private struct StaticChecksBrief: View {
    let report: CheckReport
    let showDetails: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: report.worst.systemImage)
                .foregroundStyle(report.worst.color)
                .accessibilityHidden(true)
            Text(text)
            Spacer()
            Button("Details", action: showDetails)
                .buttonStyle(.borderless)
        }
        .padding(10)
        .background(report.worst.color.opacity(0.1), in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        var parts: [String] = []
        if report.failures > 0 { parts.append("\(report.failures) failing") }
        if report.warnings > 0 { parts.append("\(report.warnings) \(report.warnings == 1 ? "warning" : "warnings")") }
        if report.pending > 0 { parts.append("\(report.pending) pending") }
        return "Static checks: " + (parts.isEmpty ? "all passing" : parts.joined(separator: ", "))
    }
}

private struct ReviewHeader: View {
    let mr: TrackedMR
    let run: AIReviewRun?
    let runs: [AIReviewRun]
    let progress: RunProgress?
    @Binding var selectedRunID: UUID?
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow
    @State private var isAddingCase = false

    private var service: AIReviewService { appModel.aiReview }

    var body: some View {
        content
            .sheet(isPresented: $isAddingCase) {
                AddEvalCaseSheet(mr: mr, latestRun: run, paths: run?.orderedFiles.map(\.path) ?? [])
            }
    }

    private var content: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if progress != nil {
                    Text("Reviewing on device…").font(.headline)
                } else if let run {
                    Text("Reviewed at \(String(run.headSHA.prefix(8)))")
                        .font(.headline.monospaced())
                    Text(subtitle(run))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if progress == nil, let run, run.headSHA != mr.headSHA {
                    Label("New commits since this review (now at \(mr.shortSHA))", systemImage: "arrow.triangle.branch")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if runs.count > 1 && progress == nil {
                Picker("Run", selection: Binding(get: { selectedRunID ?? runs.first?.id }, set: { selectedRunID = $0 })) {
                    ForEach(runs) { run in
                        Text("\(String(run.headSHA.prefix(8))) · \(run.promptVersionName) · \(run.startedAt.formatted(date: .abbreviated, time: .shortened))")
                            .tag(Optional(run.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("Earlier runs")
            }
            if progress == nil, run?.headSHA == mr.headSHA || run == nil {
                Menu {
                    Button(appModel.evaluation.existingCase(for: mr) == nil ? "Add to Eval Set…" : "Edit Eval Case…") { isAddingCase = true }
                    Button("Open Evaluation") { openWindow(id: "evaluation") }
                } label: {
                    Label("Evaluate", systemImage: "chart.bar.doc.horizontal")
                }
                .fixedSize()
                .help("Use this MR to measure prompt changes")
            }
            if progress != nil {
                Button("Cancel", role: .cancel) { service.cancel(mr.key) }
            } else if run != nil {
                if service.needsReview(mr) {
                    Button("Review New Commits") { selectedRunID = nil; service.start(mr) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Rerun") { selectedRunID = nil; service.start(mr, rerun: true) }
                        .help("Review again with the current prompt version and skills")
                }
            }
        }
        .disabled(!service.modelStatus.isAvailable && progress == nil)
    }

    private func subtitle(_ run: AIReviewRun) -> String {
        var parts = ["prompt \(run.promptVersionName)", run.startedAt.formatted(.relative(presentation: .named))]
        if let latency = run.latency { parts.append(latency.formatted(.number.precision(.fractionLength(0))) + " s") }
        if run.totalInputTokens > 0 { parts.append("\(run.totalInputTokens + run.totalOutputTokens) tokens") }
        switch run.status {
        case .cancelled: parts.append("cancelled")
        case .failed: parts.append("failed")
        default: break
        }
        return parts.joined(separator: " · ")
    }
}

private struct ReviewProgressList: View {
    let progress: RunProgress

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(progress.finishedCount), total: Double(max(progress.paths.count, 1))) {
                    Text(progress.isMerging ? "Combining findings into a verdict…" : "\(progress.finishedCount) of \(progress.paths.count) files")
                }
                ForEach(progress.paths, id: \.self) { path in
                    HStack(spacing: 8) {
                        stateIcon(progress.states[path] ?? .queued)
                        Text(path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                        Spacer()
                        Text(stateText(progress.states[path] ?? .queued)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = progress.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func stateIcon(_ state: RunProgress.FileState) -> some View {
        switch state {
        case .queued: Image(systemName: "circle.dotted").foregroundStyle(.secondary)
        case .running: ProgressView().controlSize(.small)
        case .reviewed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .skipped: Image(systemName: "forward.circle").foregroundStyle(.secondary)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private func stateText(_ state: RunProgress.FileState) -> String {
        switch state {
        case .queued: "Queued"
        case .running: "Reviewing"
        case .reviewed(let concerns): concerns == 0 ? "No concerns" : "\(concerns) \(concerns == 1 ? "concern" : "concerns")"
        case .skipped(let reason): "Skipped: \(reason)"
        case .failed(let reason): "Failed: \(reason)"
        }
    }
}

private struct RunDetail: View {
    let mr: TrackedMR
    let run: AIReviewRun
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VerdictCard(run: run) { appModel.inspection = .merge(runID: run.id); appModel.isInspectorPresented = true }
            if run.status == .completed, run.headSHA == mr.headSHA {
                SummaryRow(mr: mr, run: run)
            }
            StoryNote(run: run)
            if !run.skillsUsed.isEmpty {
                Label("Skills: \(run.skillsUsed.joined(separator: ", "))", systemImage: "book.closed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("Files").font(.headline)
            ForEach(run.orderedFiles) { record in
                FileFindingCard(record: record, isCurrentHead: run.headSHA == mr.headSHA) { line in
                    appModel.showInDiff(mr: mr, path: record.path, line: line)
                } inspect: {
                    appModel.inspection = .file(record.id)
                    appModel.isInspectorPresented = true
                }
            }
        }
    }
}

/// Offers posting the review as a resolvable thread on the MR when there are issues.
private struct SummaryRow: View {
    let mr: TrackedMR
    let run: AIReviewRun
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack {
            if let posted = run.summaryPostedAt {
                Label("Summary posted to the merge request \(posted.formatted(.relative(presentation: .named)))",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if appModel.aiReview.summaryIsWorthPosting(run) {
                Label("Share this review as an open thread on the merge request.", systemImage: "text.bubble")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Post Summary to GitLab…") { appModel.summaryPoster.preview(run, for: mr) }
            } else {
                Label("Looks good with no open AI comments; nothing to post.", systemImage: "checkmark.seal")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
    }
}

/// What the review compared the code against.
private struct StoryNote: View {
    let run: AIReviewRun

    var body: some View {
        Group {
            if let key = run.storyKey, run.usedAcceptanceCriteria {
                Label("Compared against the \(key) story and its acceptance criteria.", systemImage: "ticket")
            } else if let key = run.storyKey {
                Label("Compared against the \(key) story description; it has no acceptance criteria.", systemImage: "ticket")
            } else {
                Label("No Jira story was available (\(run.storyNote ?? "Jira isn't connected")), so the review checked correctness only.",
                      systemImage: "info.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }
}

private struct VerdictCard: View {
    let run: AIReviewRun
    let inspect: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let status = run.verdictStatus {
                    HStack {
                        Label(status.title, systemImage: status.systemImage)
                            .font(.title3.bold())
                            .foregroundStyle(status.color)
                        Spacer()
                        FeedbackControl(feedback: Bindable(run).verdictFeedback, note: Bindable(run).verdictNote, subject: "the verdict")
                        Button("Inspect", action: inspect).buttonStyle(.borderless)
                    }
                    if let rationale = run.rationale { Text(rationale).textSelection(.enabled) }
                    if let coverage = run.criteriaCoverage {
                        LabeledContent("Criteria coverage") { Text(coverage).multilineTextAlignment(.trailing) }
                            .font(.callout)
                    }
                    if !run.topConcerns.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Top concerns").font(.callout.bold())
                            ForEach(Array(run.topConcerns.enumerated()), id: \.offset) { _, concern in
                                Label(concern, systemImage: "exclamationmark.bubble")
                                    .font(.callout)
                            }
                        }
                    }
                } else {
                    Label(run.verdictFailure ?? run.errorMessage ?? "No verdict", systemImage: "questionmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text("Verdict").font(.headline)
        }
    }
}

private struct FileFindingCard: View {
    let record: FileReviewRecord
    let isCurrentHead: Bool
    let openLine: (Int) -> Void
    let inspect: () -> Void
    @State private var isExpanded: Bool?

    var body: some View {
        DisclosureGroup(isExpanded: Binding(get: { isExpanded ?? !record.concerns.isEmpty }, set: { isExpanded = $0 })) {
            VStack(alignment: .leading, spacing: 8) {
                if let summary = record.summary {
                    Text(summary).textSelection(.enabled)
                }
                if record.status == .reviewed {
                    HStack(spacing: 16) {
                        if let criteria = record.meetsCriteria { Text("Meets criteria: \(criteria.rawValue)") }
                        if let confidence = record.confidence { Text("Confidence: \(confidence.rawValue)") }
                        if record.partCount > 1 { Text("Reviewed in \(record.partCount) parts") }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if let reason = record.skipReason {
                    Text("Skipped: \(reason)").foregroundStyle(.secondary)
                }
                if let failure = record.failure {
                    Label(failure.message, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                ForEach(record.orderedConcerns) { concern in
                    ConcernRow(concern: concern, canOpen: isCurrentHead) {
                        if let line = concern.lineNumber { openLine(line) }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color).accessibilityHidden(true)
                Text(record.path).font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
                Spacer()
                Text(statusText).font(.caption).foregroundStyle(.secondary)
                if record.status != .skipped {
                    Button("Inspect", action: inspect).buttonStyle(.borderless).controlSize(.small)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var icon: String {
        switch record.status {
        case .reviewed: record.concerns.isEmpty ? "checkmark.circle.fill" : "exclamationmark.bubble.fill"
        case .skipped: "forward.circle"
        case .failed: "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch record.status {
        case .reviewed: record.concerns.contains { $0.severity == .high } ? .red : record.concerns.isEmpty ? .green : .orange
        case .skipped: .secondary
        case .failed: .red
        }
    }

    private var statusText: String {
        switch record.status {
        case .reviewed: record.concerns.isEmpty ? "No concerns" : "\(record.concerns.count) \(record.concerns.count == 1 ? "concern" : "concerns")"
        case .skipped: "Skipped"
        case .failed: "Failed"
        }
    }
}

private struct ConcernRow: View {
    let concern: ConcernRecord
    let canOpen: Bool
    let open: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(concern.severity.rawValue.capitalized)
                .font(.caption.bold())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(concern.severity.color.opacity(0.18), in: .capsule)
                .foregroundStyle(concern.severity.color)
            VStack(alignment: .leading, spacing: 2) {
                if canOpen, concern.lineNumber != nil {
                    Button(concern.lineHint, action: open)
                        .buttonStyle(.link)
                        .font(.caption.monospaced())
                        .help("Show in Changes")
                } else {
                    Text(concern.lineHint).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Text(concern.explanation).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            FeedbackControl(feedback: Bindable(concern).feedback, note: Bindable(concern).note, subject: "this concern")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(concern.severity.rawValue) severity concern at \(concern.lineHint): \(concern.explanation)")
    }
}

extension VerdictStatus {
    var title: String {
        switch self {
        case .looksGood: "Looks good"
        case .needsHumanReview: "Needs human review"
        case .likelyProblem: "Likely problem"
        }
    }

    var systemImage: String {
        switch self {
        case .looksGood: "checkmark.seal.fill"
        case .needsHumanReview: "person.fill.questionmark"
        case .likelyProblem: "exclamationmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .looksGood: .green
        case .needsHumanReview: .orange
        case .likelyProblem: .red
        }
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .low: .secondary
        case .medium: .orange
        case .high: .red
        }
    }
}
