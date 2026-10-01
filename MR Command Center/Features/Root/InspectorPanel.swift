import SwiftData
import SwiftUI

/// Trailing debug panel for AI runs: exact instructions, prompt, transcript (including tool
/// calls), tokens, latency, and raw structured output. Drawn in the detail column rather
/// than with `.inspector`, which crashed AppKit layout when opened in a narrow window.
struct InspectorPanel: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        Group {
            switch appModel.inspection {
            case .file(let id):
                if let record = fetchRecord(id) {
                    FileInspection(record: record)
                } else {
                    empty
                }
            case .merge(let runID):
                if let run = fetchRun(runID) {
                    MergeInspection(run: run)
                } else {
                    empty
                }
            case nil:
                empty
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background.secondary)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private var empty: some View {
        ContentUnavailableView(
            "Nothing to Inspect",
            systemImage: "ladybug",
            description: Text("Choose Inspect on a file or verdict in the AI Review tab.")
        )
    }

    private func fetchRecord(_ id: UUID) -> FileReviewRecord? {
        var descriptor = FetchDescriptor<FileReviewRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }

    private func fetchRun(_ id: UUID) -> AIReviewRun? {
        var descriptor = FetchDescriptor<AIReviewRun>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? modelContext.fetch(descriptor).first
    }
}

private struct FileInspection: View {
    let record: FileReviewRecord

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(record.path).font(.headline.monospaced()).textSelection(.enabled)
                Metrics(rows: [
                    ("Status", record.status.rawValue),
                    ("Input tokens", record.inputTokens > 0 ? "\(record.inputTokens)" : "n/a"),
                    ("Output tokens", record.outputTokens > 0 ? "\(record.outputTokens)" : "n/a"),
                    ("Latency", record.latency.formatted(.number.precision(.fractionLength(2))) + " s"),
                    ("Parts", "\(record.partCount)"),
                    ("Skills", record.skillsUsed.isEmpty ? "none" : record.skillsUsed.joined(separator: ", ")),
                ])
                if !record.staticFlags.isEmpty {
                    Section("Static flags sent", text: record.staticFlags.joined(separator: "\n"))
                }
                if let failure = record.failure {
                    Label(failure.message, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                ForEach(Array(record.calls.enumerated()), id: \.offset) { index, call in
                    CallInspection(title: record.calls.count > 1 ? "Part \(index + 1)" : "Model call", call: call)
                }
            }
            .padding(12)
        }
    }
}

private struct MergeInspection: View {
    let run: AIReviewRun

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Verdict (merge step)").font(.headline)
                Metrics(rows: [
                    ("Model", run.modelIdentifier),
                    ("Prompt", run.promptVersionName),
                    ("Run tokens", "\(run.totalInputTokens) in / \(run.totalOutputTokens) out"),
                    ("Run time", run.latency.map { $0.formatted(.number.precision(.fractionLength(1))) + " s" } ?? "n/a"),
                    ("Tools", run.toolsEnabled ? "on" : "off"),
                ])
                if let call = run.mergeCall {
                    CallInspection(title: "Merge call", call: call)
                } else if let failure = run.verdictFailure {
                    Label(failure, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
            }
            .padding(12)
        }
    }
}

private struct CallInspection: View {
    let title: String
    let call: ModelCallRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.bold())
            Text("\(call.inputTokens.map { "\($0) in" } ?? "? in") · \(call.outputTokens.map { "\($0) out" } ?? "? out") · \(call.latency.formatted(.number.precision(.fractionLength(2)))) s")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !call.toolCalls.isEmpty {
                Section("Tool calls", text: call.toolCalls.map { "\($0.succeeded ? "✓" : "✗") \($0.tool)(\($0.arguments)) → \($0.resultSummary)" }.joined(separator: "\n"),
                        startsExpanded: true)
            }
            if !call.instructions.isEmpty { Section("Instructions", text: call.instructions) }
            if !call.prompt.isEmpty { Section("Prompt", text: call.prompt) }
            if !call.rawOutput.isEmpty { Section("Structured output", text: call.rawOutput, startsExpanded: true) }
            Section("Transcript", text: call.transcript)
        }
    }
}

private struct Metrics: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary)
                    Text(row.1).textSelection(.enabled)
                }
            }
        }
        .font(.caption)
    }
}

private struct Section: View {
    let title: String
    let text: String
    @State private var isExpanded: Bool

    init(_ title: String, text: String, startsExpanded: Bool = false) {
        self.title = title
        self.text = text
        _isExpanded = State(initialValue: startsExpanded)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
                .typesettingLanguage(.code)
        } label: {
            HStack {
                Text(title).font(.caption.bold())
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                .buttonStyle(.borderless)
                .controlSize(.mini)
            }
        }
    }
}
