import SwiftUI

/// Adds the MR at its head SHA to the eval set with the reviewer's expected verdict and
/// concerns. Expected concerns start from the concerns marked 👍 in the latest review.
struct AddEvalCaseSheet: View {
    let mr: TrackedMR
    let latestRun: AIReviewRun?
    let paths: [String]
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var verdict: VerdictStatus = .needsHumanReview
    @State private var concerns: [ExpectedConcern] = []
    @State private var notes = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var isUpdate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isUpdate ? "Update Eval Case" : "Add to Eval Set").font(.title3.bold())
            Text("\(mr.reference) at \(mr.shortSHA). The diff, static flags, and Jira data are saved locally, so the case still works after the MR merges.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Picker("Expected verdict", selection: $verdict) {
                ForEach(VerdictStatus.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Expected concerns").font(.headline)
                    Spacer()
                    Button("Add Concern") {
                        concerns.append(ExpectedConcern(path: paths.first ?? "", line: nil, description: ""))
                    }
                    .disabled(paths.isEmpty)
                }
                if concerns.isEmpty {
                    Text("None: a good review of this MR should raise no concerns.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach($concerns) { $concern in
                            HStack(alignment: .firstTextBaseline) {
                                Picker("File", selection: $concern.path) {
                                    ForEach(paths, id: \.self) { Text($0).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 220)
                                TextField("Line", value: $concern.line, format: .number)
                                    .frame(width: 56)
                                    .help("Leave empty to match anywhere in the file")
                                TextField("What should be flagged", text: $concern.description)
                                Button {
                                    concerns.removeAll { $0.id == concern.id }
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove concern")
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }

            TextField("Notes", text: $notes, prompt: Text("Why this MR is a good test case"), axis: .vertical)
                .lineLimit(2...4)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.caption)
            }
            HStack {
                Text("A concern counts as found when the model flags the same file within \(EvalMetrics.lineTolerance) lines.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if isSaving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isUpdate ? "Update" : "Add to Eval Set") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        if let existing = appModel.evaluation.existingCase(for: mr) {
            isUpdate = true
            verdict = existing.expectedVerdict
            concerns = existing.expectedConcerns
            notes = existing.notes
            return
        }
        guard let run = latestRun, run.headSHA == mr.headSHA else { return }
        verdict = run.verdictStatus ?? .needsHumanReview
        concerns = run.orderedFiles.flatMap { file in
            file.orderedConcerns.filter { $0.feedback == .helpful }.map {
                ExpectedConcern(path: file.path, line: $0.lineNumber, description: $0.explanation)
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let cleaned = concerns.filter { !$0.path.isEmpty }
            try await appModel.evaluation.saveCase(for: mr, expectedVerdict: verdict, expectedConcerns: cleaned, notes: notes)
            dismiss()
        } catch {
            self.error = "Couldn't save the case: \(error.localizedDescription)"
        }
    }
}
