import SwiftData
import SwiftUI

/// The single place to manage connection details (SwiftData) and tokens (Keychain).
struct AccountsSettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AccountSettings]
    @State private var model: AccountsModel?

    var body: some View {
        Group {
            if let settings = settingsRows.first, let model {
                AccountsForm(settings: settings, model: model)
            } else {
                ProgressView()
            }
        }
        .task {
            if model == nil { model = AccountsModel(appModel: appModel) }
            if settingsRows.isEmpty { _ = AccountSettings.current(in: modelContext) }
        }
    }
}

private struct AccountsForm: View {
    @Bindable var settings: AccountSettings
    @Bindable var model: AccountsModel

    var body: some View {
        Form {
            if let error = model.tokenError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            GitLabSection(settings: settings, model: model)
            JiraSection(settings: settings, model: model)
            JiraLinkingSection(settings: settings)
        }
        .formStyle(.grouped)
    }
}

// MARK: - GitLab

private struct GitLabSection: View {
    @Bindable var settings: AccountSettings
    @Bindable var model: AccountsModel

    var body: some View {
        Section {
            TextField("Base URL", text: $settings.gitLabBaseURL, prompt: Text("https://gitlab.example.com"))
                .textContentType(.URL)
                .autocorrectionDisabled()
            TokenRow(
                title: "Personal access token",
                isSaved: model.hasGitLabToken,
                draft: $model.gitLabTokenDraft,
                save: { model.saveGitLabToken(settings: settings) },
                remove: { model.removeGitLabToken(settings: settings) }
            )
            LabeledContent("Required scope") {
                Text(settings.postCommentsEnabled ? "api" : "read_api").monospaced()
            }
            Toggle(isOn: $settings.postCommentsEnabled) {
                Text("Allow posting comments")
                Text("Lets you add inline diff comments and replies from the Changes tab. Needs a token with the api scope.")
            }
            ConnectionTestRow(state: model.gitLabTest) {
                Task { await model.testGitLab(settings: settings) }
            }
        } header: {
            Text("GitLab")
        } footer: {
            Text("Create a token under User Settings → Access Tokens. **read_api** is enough for reading. Posting comments needs **api**, which also allows other writes, so only turn it on if you want to comment from this app. The app never approves, merges, or edits MRs.")
        }
    }
}

// MARK: - Jira

private struct JiraSection: View {
    @Bindable var settings: AccountSettings
    @Bindable var model: AccountsModel

    var body: some View {
        Section {
            Picker("Deployment", selection: $settings.jiraDeployment) {
                ForEach(JiraDeployment.allCases) { deployment in
                    Text(deployment.displayName).tag(deployment)
                }
            }
            TextField("Base URL", text: $settings.jiraBaseURL, prompt: Text("https://yourcompany.atlassian.net"))
                .textContentType(.URL)
                .autocorrectionDisabled()
            if settings.jiraDeployment == .cloud {
                TextField("Email", text: $settings.jiraEmail, prompt: Text("you@example.com"))
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
            }
            TokenRow(
                title: settings.jiraDeployment == .cloud ? "API token" : "Personal access token",
                isSaved: model.hasJiraToken,
                draft: $model.jiraTokenDraft,
                save: { model.saveJiraToken(settings: settings) },
                remove: { model.removeJiraToken(settings: settings) }
            )
            ConnectionTestRow(state: model.jiraTest) {
                Task { await model.testJira(settings: settings) }
            }
        } header: {
            Text("Jira")
        } footer: {
            Text(settings.jiraDeployment == .cloud
                 ? "Create an API token at id.atlassian.com → Security → API tokens. Jira is optional; the app works without it."
                 : "Create a personal access token from your Jira profile. Jira is optional; the app works without it.")
        }
    }
}

private struct JiraLinkingSection: View {
    @Bindable var settings: AccountSettings
    @State private var passingStatusesText = ""

    var body: some View {
        Section {
            TextField("Acceptance criteria field ID", text: $settings.jiraAcceptanceCriteriaFieldID, prompt: Text("customfield_10050"))
                .autocorrectionDisabled()
            TextField("Priority field ID", text: $settings.jiraPriorityFieldID, prompt: Text("priority (standard field)"))
                .autocorrectionDisabled()
            TextField("Passing statuses", text: $passingStatusesText, prompt: Text("In Review, Code Review"))
                .onSubmit(commitPassingStatuses)
                .onChange(of: passingStatusesText) { commitPassingStatuses() }
            BranchPatternField(pattern: $settings.branchKeyPattern)
        } header: {
            Text("Jira linking")
        } footer: {
            Text("If the criteria field ID is empty or the field is blank, criteria are read from an “Acceptance Criteria” heading in the description. Leave the priority field empty for Jira's standard Priority. Issues in a passing status aren't refetched on automatic refreshes.")
        }
        JiraPreviewSection()
        .onAppear {
            passingStatusesText = settings.jiraPassingStatuses.joined(separator: ", ")
        }
    }

    private func commitPassingStatuses() {
        let statuses = passingStatusesText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if statuses != settings.jiraPassingStatuses {
            settings.jiraPassingStatuses = statuses
        }
    }
}

private struct BranchPatternField: View {
    @Binding var pattern: String

    private var isValid: Bool {
        (try? NSRegularExpression(pattern: pattern)) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("Branch key pattern", text: $pattern)
                    .monospaced()
                    .autocorrectionDisabled()
                Button("Reset") { pattern = AccountSettings.defaultBranchKeyPattern }
                    .disabled(pattern == AccountSettings.defaultBranchKeyPattern)
            }
            if !isValid {
                Label("Not a valid regular expression", systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Shared rows

private struct TokenRow: View {
    let title: String
    let isSaved: Bool
    @Binding var draft: String
    let save: () -> Void
    let remove: () -> Void

    @State private var isReplacing = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        if isSaved && !isReplacing {
            LabeledContent(title) {
                HStack {
                    Label("Saved in Keychain", systemImage: "lock.fill")
                        .foregroundStyle(.secondary)
                    Button("Replace…") { isReplacing = true }
                    Button("Remove…", role: .destructive) { isConfirmingRemoval = true }
                }
            }
            .confirmationDialog("Remove the \(title.lowercased()) from the Keychain?", isPresented: $isConfirmingRemoval) {
                Button("Remove Token", role: .destructive, action: remove)
            }
        } else {
            LabeledContent(title) {
                HStack {
                    SecureField(title, text: $draft, prompt: Text("Paste token"))
                        .labelsHidden()
                        .onSubmit(commit)
                    Button("Save", action: commit)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if isReplacing {
                        Button("Cancel") {
                            draft = ""
                            isReplacing = false
                        }
                    }
                }
            }
        }
    }

    private func commit() {
        save()
        isReplacing = false
    }
}

private struct ConnectionTestRow: View {
    let state: ConnectionTestState
    let test: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button("Test Connection", action: test)
                .disabled(state == .testing)
            Spacer(minLength: 12)
            status
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var status: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .warning(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .failure(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    let model = AppModel.preview()
    SettingsView()
        .environment(model)
        .modelContainer(model.modelContainer)
}

/// Checks the Jira setup against a real issue: what the app extracts, and which custom
/// fields look like acceptance criteria or priority.
private struct JiraPreviewSection: View {
    @Environment(AppModel.self) private var appModel
    @State private var key = ""
    @State private var preview: JiraService.Preview?
    @State private var isLoading = false

    var body: some View {
        Section {
            HStack {
                TextField("Issue key", text: $key, prompt: Text("PAY-142"))
                    .autocorrectionDisabled()
                    .onSubmit(load)
                Button("Preview", action: load)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || isLoading)
                if isLoading { ProgressView().controlSize(.small) }
            }
            if let preview {
                if let error = preview.error {
                    Label(error, systemImage: "xmark.octagon").foregroundStyle(.red)
                }
                if let details = preview.details {
                    LabeledContent("Summary", value: details.summary)
                    LabeledContent("Status", value: details.status)
                    LabeledContent("Priority", value: details.hasPriority ? (details.priority ?? "") : "Not set")
                    LabeledContent("Fix versions", value: details.fixVersions.isEmpty ? "None" : details.fixVersions.joined(separator: ", "))
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Acceptance criteria")
                            Spacer()
                            Text(details.acceptanceCriteriaSource.map { $0 == .customField ? "from the criteria field" : "from the description" } ?? "not found")
                                .foregroundStyle(.secondary)
                        }
                        if let criteria = details.acceptanceCriteria {
                            Text(criteria).font(.callout.monospaced()).textSelection(.enabled)
                        }
                    }
                }
                if !preview.suggestedFields.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Custom fields that might be what you want:").font(.caption)
                        ForEach(preview.suggestedFields) { field in
                            Text("\(field.name): \(field.id)").font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
        } header: {
            Text("Check the setup")
        } footer: {
            Text("Fetches one issue with the settings above and shows exactly what the review will use.")
        }
    }

    private func load() {
        isLoading = true
        Task {
            preview = await appModel.jira.preview(key: key)
            isLoading = false
        }
    }
}
