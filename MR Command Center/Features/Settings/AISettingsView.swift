import SwiftData
import SwiftUI

struct AISettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Query private var settingsRows: [AccountSettings]
    @Query(sort: \PromptVersion.createdAt) private var versions: [PromptVersion]

    var body: some View {
        if let settings = settingsRows.first {
            AIForm(settings: settings, versions: versions, status: appModel.aiReview.modelStatus)
                .task { appModel.aiReview.refreshStatus() }
        }
    }
}

private struct AIForm: View {
    @Bindable var settings: AccountSettings
    let versions: [PromptVersion]
    let status: ModelStatus

    var body: some View {
        Form {
            Section {
                Label(status.title, systemImage: status.isAvailable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(status.isAvailable ? .green : .orange)
                Text(status.explanation).font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("On-device model")
            }
            Section {
                Picker("Active prompt version", selection: $settings.activePromptVersionID) {
                    ForEach(versions) { Text($0.name).tag(Optional($0.id)) }
                }
                Stepper(value: $settings.aiConcurrencyLimit, in: 1...4) {
                    LabeledContent("Files reviewed at once", value: "\(settings.aiConcurrencyLimit)")
                }
                Toggle(isOn: $settings.aiGreedySampling) {
                    Text("Deterministic output")
                    Text("Greedy sampling gives the same result for the same input, which keeps evaluation comparable.")
                }
                if !settings.aiGreedySampling {
                    LabeledContent("Temperature") {
                        Slider(value: $settings.aiTemperature, in: 0...1, step: 0.1) { Text("Temperature") }
                            .frame(width: 180)
                        Text(settings.aiTemperature.formatted(.number.precision(.fractionLength(1)))).monospacedDigit()
                    }
                }
                Toggle(isOn: $settings.aiToolsEnabled) {
                    Text("Let the model read files")
                    Text("Experimental. Gives the model a tool to read lines of a file at the head commit when a hunk lacks context. Uses more context and time; every call is logged in the inspector.")
                }
            } header: {
                Text("Review")
            } footer: {
                Text("One file per session keeps each review within the model's context. Edit prompts in the Prompts tab, and compare versions in Window → Evaluation (⇧⌘E).")
            }
        }
        .formStyle(.grouped)
    }
}
