import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// Manage review skills: language/area guidance the AI gets for matching files.
struct SkillsSettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \ReviewSkill.name) private var skills: [ReviewSkill]
    @State private var selection: ReviewSkill.ID?
    @State private var isImporting = false
    @State private var exportDocument: SkillDocument?
    @State private var message: String?
    @State private var testPath = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                skillList
                    .frame(width: 220)
                Divider()
                if let skill = skills.first(where: { $0.id == selection }) {
                    SkillEditor(skill: skill, export: { exportDocument = SkillDocument(skill: skill) }, delete: { delete(skill) })
                        .id(skill.id)
                } else {
                    ContentUnavailableView("No Skill Selected", systemImage: "book.closed",
                                           description: Text("Skills add language or project guidance to the AI review for matching files."))
                }
            }
            Divider()
            matchTester
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.markdownText, .plainText], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .fileExporter(isPresented: Binding(get: { exportDocument != nil }, set: { if !$0 { exportDocument = nil } }),
                      document: exportDocument, contentType: .markdownText,
                      defaultFilename: exportDocument?.filename) { _ in exportDocument = nil }
        .alert("Skills", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK") { message = nil }
        } message: {
            Text(message ?? "")
        }
        .onAppear { if selection == nil { selection = skills.first?.id } }
    }

    private var skillList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(skills) { skill in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(skill.name)
                            if !skill.isEnabled {
                                Text("Off").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Text(skill.appliesTo.joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .opacity(skill.isEnabled ? 1 : 0.6)
                    .tag(skill.id)
                }
            }
            HStack(spacing: 4) {
                Button { addSkill() } label: { Image(systemName: "plus") }
                    .help("New skill")
                    .accessibilityLabel("New skill")
                Menu {
                    Button("Import Skill Files…") { isImporting = true }
                    Button("Restore Starter Skills") { restoreDefaults() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More")
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
    }

    private var matchTester: some View {
        HStack {
            TextField("Test a path", text: $testPath, prompt: Text("src/orders/totals.ts"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            let matched = SkillMatcher.skills(for: testPath, from: skills.filter(\.isEnabled).map(\.snapshot))
            Text(testPath.isEmpty ? "Shows which skills apply to a file." :
                    matched.isEmpty ? "No skills apply." : "Applies: " + matched.map(\.name).joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(10)
    }

    private func addSkill() {
        let skill = ReviewSkill(name: "New skill", appliesTo: ["*.ext"], content: "- Guidance for the reviewer, one point per line.")
        modelContext.insert(skill)
        selection = skill.id
    }

    private func delete(_ skill: ReviewSkill) {
        modelContext.delete(skill)
        selection = skills.first { $0.id != skill.id }?.id
    }

    private func restoreDefaults() {
        var restored = 0
        for seed in DefaultSkills.all where !skills.contains(where: { $0.name == seed.name }) {
            modelContext.insert(ReviewSkill(name: seed.name, appliesTo: seed.appliesTo, content: seed.content, isBuiltIn: true))
            restored += 1
        }
        message = restored == 0 ? "All starter skills are already present." : "Restored \(restored) starter skills."
    }

    /// Imports `.md` skill files. A file with the same name as an existing skill updates it
    /// (bumping its version) instead of creating a duplicate.
    private func importFiles(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result else { return }
        var imported: [String] = []
        var failures: [String] = []
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let parsed = try SkillFile.parse(text, fallbackName: url.deletingPathExtension().lastPathComponent)
                if let existing = skills.first(where: { $0.name.caseInsensitiveCompare(parsed.name) == .orderedSame }) {
                    existing.update(name: parsed.name, appliesTo: parsed.appliesTo, content: parsed.content)
                    imported.append("\(parsed.name) (updated to v\(existing.version))")
                } else {
                    modelContext.insert(ReviewSkill(name: parsed.name, appliesTo: parsed.appliesTo, content: parsed.content))
                    imported.append(parsed.name)
                }
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        message = (["Imported: " + (imported.isEmpty ? "none" : imported.joined(separator: ", "))] + failures).joined(separator: "\n")
    }
}

private struct SkillEditor: View {
    let skill: ReviewSkill
    let export: () -> Void
    let delete: () -> Void
    @Environment(AppModel.self) private var appModel
    @State private var name = ""
    @State private var appliesTo = ""
    @State private var content = ""
    @State private var tokens: Int?
    @State private var isConfirmingDelete = false

    private var patterns: [String] {
        appliesTo.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private var isDirty: Bool {
        name != skill.name || patterns != skill.appliesTo || content != skill.content
    }

    var body: some View {
        VStack(spacing: 0) {
            form
            Divider()
            actions
        }
        .onAppear(perform: load)
        .task(id: content) { await countTokens() }
        .confirmationDialog("Delete the “\(skill.name)” skill?", isPresented: $isConfirmingDelete) {
            Button("Delete Skill", role: .destructive, action: delete)
        } message: {
            Text("Past review runs keep a record of the version they used.")
        }
    }

    private var actions: some View {
        HStack {
            Button("Save as v\(skill.version + 1)") {
                skill.update(name: name.trimmingCharacters(in: .whitespaces), appliesTo: patterns, content: content)
            }
            .keyboardShortcut("s", modifiers: .command)
            .buttonStyle(.borderedProminent)
            .disabled(!isDirty || name.trimmingCharacters(in: .whitespaces).isEmpty || content.isEmpty)
            Button("Revert") { load() }.disabled(!isDirty)
            Spacer()
            Button("Export…", action: export)
            Button("Delete…", role: .destructive) { isConfirmingDelete = true }
        }
        .padding(10)
    }

    private var form: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                TextField("Applies to", text: $appliesTo, prompt: Text("*.py, src/**/*.ts"))
                    .font(.body.monospaced())
                Toggle("Enabled", isOn: Binding(get: { skill.isEnabled }, set: { skill.isEnabled = $0 }))
            } footer: {
                Text("Comma-separated globs. A pattern without “/” matches the file name; use * for every file.")
            }
            Section {
                TextEditor(text: $content)
                    .font(.body.monospaced())
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel("Skill guidance")
                HStack {
                    if let tokens {
                        Label("\(tokens) tokens", systemImage: tokens > PromptBuilder.maxSkillTokens ? "exclamationmark.triangle.fill" : "number")
                            .foregroundStyle(tokens > PromptBuilder.maxSkillTokens ? .orange : .secondary)
                            .help("Skills share a \(PromptBuilder.maxSkillTokens)-token budget per file; longer guidance leaves less room for the diff.")
                    }
                    Spacer()
                    Text("v\(skill.version) · updated \(skill.updatedAt.formatted(.relative(presentation: .named)))")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            } header: {
                Text("Guidance")
            } footer: {
                Text("Keep it short and specific: a few bullet points. Every review run records which skill versions it used.")
            }
        }
        .formStyle(.grouped)
    }

    private func load() {
        name = skill.name
        appliesTo = skill.appliesTo.joined(separator: ", ")
        content = skill.content
    }

    private func countTokens() async {
        try? await Task.sleep(for: .milliseconds(300))
        let counter: any TokenCounter = appModel.aiReview.modelStatus.isAvailable ? ModelTokenCounter() : EstimatingTokenCounter()
        tokens = try? await counter.count(content)
    }
}

/// Exports a skill as a Markdown file with a front-matter header.
nonisolated struct SkillDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.markdownText, .plainText] }

    var text: String
    var filename: String

    init(skill: ReviewSkill) {
        text = SkillFile.render(name: skill.name, appliesTo: skill.appliesTo, content: skill.content)
        filename = skill.name.replacingOccurrences(of: "/", with: "-") + ".md"
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.map { String(decoding: $0, as: UTF8.self) } ?? ""
        filename = configuration.file.filename ?? "skill.md"
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

nonisolated extension UTType {
    static var markdownText: UTType { UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText }
}
