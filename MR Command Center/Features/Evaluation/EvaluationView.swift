import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// The Evaluation window: eval set, batch results, and the cross-version comparison.
struct EvaluationView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PromptVersion.createdAt) private var versions: [PromptVersion]
    @State private var tab = Tab.compare
    @State private var promptID: UUID?
    @State private var isExporting = false
    @State private var includeContent = false
    @State private var exportDocument: JSONExportDocument?

    enum Tab: String, CaseIterable, Identifiable {
        case cases = "Eval Set"
        case batches = "Batches"
        case compare = "Compare"
        var id: Self { self }
    }

    private var service: EvalService { appModel.evaluation }

    var body: some View {
        VStack(spacing: 0) {
            if !appModel.aiReview.modelStatus.isAvailable {
                Banner(message: appModel.aiReview.modelStatus.title + ". " + appModel.aiReview.modelStatus.explanation,
                       systemImage: "exclamationmark.triangle", style: .warning)
            }
            switch tab {
            case .cases: EvalSetTab()
            case .batches: BatchesTab()
            case .compare: CompareTab()
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if let progress = service.progress {
                    ProgressView(value: Double(progress.finished), total: Double(max(progress.total, 1)))
                        .frame(width: 100)
                    Text("\(progress.finished)/\(progress.total)").monospacedDigit()
                    Button("Cancel") { service.cancelBatch() }
                } else {
                    Picker("Prompt", selection: Binding(get: { promptID ?? activePromptID }, set: { promptID = $0 })) {
                        ForEach(versions) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .fixedSize()
                    .help("Prompt version to evaluate")
                    Button {
                        guard let prompt = versions.first(where: { $0.id == (promptID ?? activePromptID) }) else { return }
                        service.runBatch(prompt: prompt, cases: service.cases)
                        tab = .batches
                    } label: {
                        Label("Run Eval Set", systemImage: "play.fill")
                    }
                    .disabled(service.cases.isEmpty || !appModel.aiReview.modelStatus.isAvailable)
                    .help("Review every case's saved snapshot with the selected prompt version")
                }
                Button {
                    isExporting = true
                } label: {
                    Label("Export JSON…", systemImage: "square.and.arrow.up")
                }
                .popover(isPresented: $isExporting) { exportPopover }
            }
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .json,
                      defaultFilename: "mr-command-center-\(Date.now.formatted(.iso8601.year().month().day())).json") { _ in
            exportDocument = nil
        }
    }

    private var activePromptID: UUID? {
        AccountSettings.current(in: modelContext).activePromptVersionID ?? versions.first?.id
    }

    private var exportPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export runs and feedback").font(.headline)
            Text("Every AI review run, per-file findings, concerns with your feedback, prompt versions, skills, eval cases, and batch metrics.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Include prompts, transcripts, and diffs (contains code)", isOn: $includeContent)
            HStack {
                Spacer()
                Button("Export…") {
                    let bundle = ExportService.makeBundle(context: modelContext, evaluation: service, includeContent: includeContent)
                    if let data = try? ExportService.encode(bundle) {
                        isExporting = false
                        exportDocument = JSONExportDocument(data: data)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

// MARK: - Eval set

private struct EvalSetTab: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection: EvalCase.ID?

    var body: some View {
        let cases = appModel.evaluation.cases
        if cases.isEmpty {
            ContentUnavailableView {
                Label("No Eval Cases Yet", systemImage: "tray")
            } description: {
                Text("In the main window, open an MR's AI Review tab and choose Evaluate → Add to Eval Set. Pick MRs where you know the right answer, including ones that are fine.")
            }
        } else {
            HStack(spacing: 0) {
                Table(cases, selection: $selection) {
                    TableColumn("Case", value: \.name)
                    TableColumn("Expected") { Text($0.expectedVerdict.title) }
                        .width(140)
                    TableColumn("Concerns") { Text("\($0.expectedConcerns.count)").monospacedDigit() }
                        .width(70)
                    TableColumn("Added") { Text($0.createdAt, format: .dateTime.month().day()) }
                        .width(70)
                }
                Divider()
                Group {
                    if let evalCase = cases.first(where: { $0.id == selection }) {
                        CaseDetail(evalCase: evalCase) { selection = nil }
                    } else {
                        ContentUnavailableView("Select a Case", systemImage: "list.bullet.rectangle")
                    }
                }
                .frame(width: 340)
            }
        }
    }
}

private struct CaseDetail: View {
    @Bindable var evalCase: EvalCase
    let deleted: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var isConfirmingDelete = false

    var body: some View {
        Form {
            Section {
                LabeledContent("MR", value: evalCase.mrReference)
                LabeledContent("Commit") { Text(String(evalCase.headSHA.prefix(8))).monospaced() }
                LabeledContent("Files", value: "\(evalCase.diffs.count)")
                Picker("Expected verdict", selection: $evalCase.expectedVerdict) {
                    ForEach(VerdictStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } header: {
                Text(evalCase.mrTitle)
            }
            Section("Expected concerns") {
                if evalCase.expectedConcerns.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                }
                ForEach(evalCase.expectedConcerns) { concern in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(concern.path)\(concern.line.map { ":\($0)" } ?? "")").font(.caption.monospaced())
                        Text(concern.description)
                    }
                }
            }
            Section("Notes") {
                TextField("Notes", text: $evalCase.notes, axis: .vertical).lineLimit(2...5)
            }
            Section {
                if let url = URL(string: evalCase.webURL) { Link("Open in GitLab", destination: url) }
                Button("Delete Case…", role: .destructive) { isConfirmingDelete = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Delete this eval case?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) {
                appModel.evaluation.delete(evalCase)
                deleted()
            }
        } message: {
            Text("Past batch runs stay, but this case won't be part of future batches.")
        }
    }
}

// MARK: - Batches

private struct BatchesTab: View {
    @Environment(AppModel.self) private var appModel
    @State private var selection: EvalBatch.ID?

    var body: some View {
        let batches = appModel.evaluation.batches
        if batches.isEmpty {
            ContentUnavailableView("No Batches Yet", systemImage: "play.square.stack",
                                   description: Text("Choose a prompt version and click Run Eval Set."))
        } else {
            HStack(spacing: 0) {
                List(batches, selection: $selection) { batch in
                    BatchRow(batch: batch, metrics: appModel.evaluation.metrics(for: batch))
                        .tag(batch.id)
                }
                .frame(width: 280)
                Divider()
                if let batch = batches.first(where: { $0.id == (selection ?? batches.first?.id) }) {
                    BatchDetail(batch: batch)
                } else {
                    ContentUnavailableView("Select a Batch", systemImage: "list.bullet")
                }
            }
        }
    }
}

private struct BatchRow: View {
    let batch: EvalBatch
    let metrics: BatchMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(batch.promptVersionName).font(.headline)
                Spacer()
                Text(batch.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("Agreement \(metrics.verdictAgreement.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")")
                Text("Recall \(metrics.expectedRecall.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–")")
                if batch.status == .running { Text("Running…").foregroundStyle(.blue) }
                if batch.status == .cancelled { Text("Cancelled").foregroundStyle(.orange) }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct BatchDetail: View {
    let batch: EvalBatch
    @Environment(AppModel.self) private var appModel
    @State private var isConfirmingDelete = false

    var body: some View {
        let service = appModel.evaluation
        let runs = Dictionary(service.runs(in: batch).compactMap { run in run.evalCaseID.map { ($0, run) } },
                              uniquingKeysWith: { _, latest in latest })
        let cases = service.cases.filter { batch.caseIDs.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Prompt \(batch.promptVersionName)").font(.title3.bold())
                        Text("\(batch.modelIdentifier) · \(batch.greedy ? "deterministic" : "sampled") · \(cases.count) cases")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Delete Batch…", role: .destructive) { isConfirmingDelete = true }
                        .disabled(batch.status == .running)
                }
                Text("Rate each concern 👍 or 👎. Ratings feed the Helpful/Wrong columns in Compare.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(cases) { evalCase in
                    CaseResult(evalCase: evalCase, run: runs[evalCase.id])
                }
            }
            .padding(16)
        }
        .confirmationDialog("Delete this batch and its runs?", isPresented: $isConfirmingDelete) {
            Button("Delete", role: .destructive) { service.delete(batch) }
        }
    }
}

private struct CaseResult: View {
    let evalCase: EvalCase
    let run: AIReviewRun?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(evalCase.name).font(.headline)
                    Spacer()
                    verdictComparison
                }
                if let run {
                    let facts = run.evalFacts
                    let found = evalCase.expectedConcerns.filter { expected in facts?.concerns.contains { EvalMetrics.matches(expected, $0) } ?? false }
                    if !evalCase.expectedConcerns.isEmpty {
                        ForEach(evalCase.expectedConcerns) { expected in
                            let hit = found.contains(expected)
                            Label("\(expected.path)\(expected.line.map { ":\($0)" } ?? ""): \(expected.description)",
                                  systemImage: hit ? "checkmark.circle.fill" : "circle.dashed")
                                .foregroundStyle(hit ? .green : .secondary)
                                .font(.callout)
                                .accessibilityLabel("Expected concern \(hit ? "found" : "missed"): \(expected.description)")
                        }
                    }
                    ForEach(run.orderedFiles) { file in
                        ForEach(file.orderedConcerns) { concern in
                            HStack(alignment: .firstTextBaseline) {
                                Text(concern.severity.rawValue.capitalized)
                                    .font(.caption.bold())
                                    .foregroundStyle(concern.severity.color)
                                    .frame(width: 54, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(file.path):\(concern.lineHint)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text(concern.explanation)
                                }
                                Spacer()
                                FeedbackControl(feedback: Bindable(concern).feedback, note: Bindable(concern).note, subject: "this concern")
                            }
                        }
                        if let failure = file.failure {
                            Label("\(file.path): \(failure.message)", systemImage: "xmark.octagon").foregroundStyle(.red).font(.caption)
                        }
                    }
                } else {
                    Text("Not run in this batch").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var verdictComparison: some View {
        let actual = run?.verdictStatus
        let matched = actual == evalCase.expectedVerdict
        HStack(spacing: 6) {
            Text("Expected \(evalCase.expectedVerdict.title)").foregroundStyle(.secondary)
            Image(systemName: "arrow.right").foregroundStyle(.secondary).accessibilityHidden(true)
            Label(actual?.title ?? "no verdict", systemImage: matched ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(matched ? .green : .red)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Expected \(evalCase.expectedVerdict.title), got \(actual?.title ?? "no verdict"), \(matched ? "match" : "mismatch")")
    }
}

// MARK: - Compare

private struct CompareTab: View {
    @Environment(AppModel.self) private var appModel
    @AppStorage("compareLatestOnly") private var latestOnly = true

    struct Row: Identifiable {
        let id: UUID
        let prompt: String
        let date: Date
        let metrics: BatchMetrics
    }

    var body: some View {
        let service = appModel.evaluation
        var batches = service.batches.filter { $0.status != .running }
        if latestOnly {
            var seen = Set<UUID>()
            batches = batches.filter { seen.insert($0.promptVersionID).inserted }
        }
        let rows = batches.map { Row(id: $0.id, prompt: $0.promptVersionName, date: $0.startedAt, metrics: service.metrics(for: $0)) }

        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Toggle("Latest batch per prompt version", isOn: $latestOnly)
                Spacer()
                Text("Agreement: verdict matched expected. Recall: expected concerns found (same file, ±\(EvalMetrics.lineTolerance) lines). Helpful/Wrong: your ratings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            if rows.isEmpty {
                ContentUnavailableView("Nothing to Compare Yet", systemImage: "chart.bar",
                                       description: Text("Run the eval set with two or more prompt versions."))
            } else {
                Table(rows) {
                    TableColumn("Prompt") { Text($0.prompt).bold() }
                    TableColumn("Run") { Text($0.date, format: .dateTime.month().day().hour().minute()) }
                    TableColumn("Cases") { Text("\($0.metrics.cases)").monospacedDigit() }.width(50)
                    TableColumn("Agreement") { Text(percent($0.metrics.verdictAgreement) + " (\($0.metrics.verdictMatches)/\($0.metrics.runsWithVerdict))").monospacedDigit() }
                    TableColumn("Recall") { Text(percent($0.metrics.expectedRecall) + " (\($0.metrics.expectedFound)/\($0.metrics.expectedConcerns))").monospacedDigit() }
                    TableColumn("Helpful / Wrong") { Text("\($0.metrics.helpful) / \($0.metrics.wrong)  ·  \($0.metrics.unrated) unrated").monospacedDigit() }
                    TableColumn("Avg time") { Text($0.metrics.averageLatency.map { $0.formatted(.number.precision(.fractionLength(1))) + " s" } ?? "–").monospacedDigit() }
                    TableColumn("Avg tokens") { Text($0.metrics.averageTokens.map { Int($0).formatted() } ?? "–").monospacedDigit() }
                    TableColumn("Errors") { Text("\($0.metrics.errors)").monospacedDigit().foregroundStyle($0.metrics.errors > 0 ? .red : .primary) }.width(50)
                }
            }
        }
    }

    private func percent(_ value: Double?) -> String {
        value.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–"
    }
}
