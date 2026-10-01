import SwiftData
import SwiftUI

/// Edit review instructions. Saved versions are immutable (runs reference them), so
/// "Save as New Version" is the only way to change a prompt.
struct PromptsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @Query(sort: \PromptVersion.createdAt) private var versions: [PromptVersion]
    @Query private var settingsRows: [AccountSettings]
    @State private var selection: PromptVersion.ID?

    private var activeID: UUID? { settingsRows.first?.activePromptVersionID }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(versions.reversed()) { version in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(version.name).font(.headline)
                            if version.id == activeID {
                                Text("Active")
                                    .font(.caption2.bold())
                                    .padding(.horizontal, 5)
                                    .background(Color.accentColor.opacity(0.2), in: .capsule)
                            }
                        }
                        Text(version.createdAt, format: .dateTime.month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                        if !version.notes.isEmpty {
                            Text(version.notes).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(version.id)
                }
            }
            .frame(width: 200)
            Divider()
            if let version = versions.first(where: { $0.id == selection }) {
                PromptEditor(base: version, isActive: version.id == activeID, nextName: nextName,
                             makeActive: { setActive(version) }, saved: { selection = $0 })
                    .id(version.id)
            } else {
                ContentUnavailableView("No Version Selected", systemImage: "text.badge.star")
            }
        }
        .onAppear { if selection == nil { selection = activeID ?? versions.last?.id } }
    }

    private var nextName: String {
        let numbers = versions.compactMap { Int($0.name.drop { !$0.isNumber }.prefix { $0.isNumber }) }
        return "v\((numbers.max() ?? versions.count) + 1)"
    }

    private func setActive(_ version: PromptVersion) {
        settingsRows.first?.activePromptVersionID = version.id
        try? modelContext.save()
    }
}

private struct PromptEditor: View {
    let base: PromptVersion
    let isActive: Bool
    let nextName: String
    let makeActive: () -> Void
    let saved: (UUID) -> Void
    @Environment(\.modelContext) private var modelContext
    @Environment(AppModel.self) private var appModel
    @State private var name = ""
    @State private var fileInstructions = ""
    @State private var mergeInstructions = ""
    @State private var notes = ""
    @State private var fileTokens: Int?
    @State private var mergeTokens: Int?
    @State private var makeActiveOnSave = true

    private var isDirty: Bool {
        fileInstructions != base.fileInstructions || mergeInstructions != base.mergeInstructions
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextEditor(text: $fileInstructions)
                        .font(.body.monospaced())
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Per-file instructions")
                    tokenLine(fileTokens)
                } header: {
                    Text("Per-file instructions")
                } footer: {
                    Text("Sent with every file. Matching skills are appended after these.")
                }
                Section {
                    TextEditor(text: $mergeInstructions)
                        .font(.body.monospaced())
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("Verdict instructions")
                    tokenLine(mergeTokens)
                } header: {
                    Text("Verdict instructions")
                } footer: {
                    Text("Used by the merge step that turns per-file findings into the verdict.")
                }
                if isDirty {
                    Section("New version") {
                        TextField("Name", text: $name)
                        TextField("What changed", text: $notes, prompt: Text("e.g. stricter severity definitions"))
                        Toggle("Make it the active version", isOn: $makeActiveOnSave)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Make Active", action: makeActive)
                }
                Spacer()
                Button("Revert") { load() }.disabled(!isDirty)
                Button("Save as New Version") { saveNewVersion() }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .onAppear(perform: load)
        .task(id: fileInstructions) { fileTokens = await count(fileInstructions) }
        .task(id: mergeInstructions) { mergeTokens = await count(mergeInstructions) }
    }

    private func tokenLine(_ tokens: Int?) -> some View {
        HStack {
            if let tokens {
                Text("\(tokens) tokens").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Saved versions can't be edited; changes become a new version.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func load() {
        name = nextName
        fileInstructions = base.fileInstructions
        mergeInstructions = base.mergeInstructions
        notes = ""
    }

    private func saveNewVersion() {
        let version = PromptVersion(name: name.trimmingCharacters(in: .whitespaces), fileInstructions: fileInstructions,
                                    mergeInstructions: mergeInstructions, notes: notes.isEmpty ? "Based on \(base.name)" : notes)
        modelContext.insert(version)
        if makeActiveOnSave {
            AccountSettings.current(in: modelContext).activePromptVersionID = version.id
        }
        try? modelContext.save()
        saved(version.id)
    }

    private func count(_ text: String) async -> Int? {
        try? await Task.sleep(for: .milliseconds(300))
        let counter: any TokenCounter = appModel.aiReview.modelStatus.isAvailable ? ModelTokenCounter() : EstimatingTokenCounter()
        return try? await counter.count(text)
    }
}
