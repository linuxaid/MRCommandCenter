import SwiftData
import SwiftUI

struct GeneralSettingsView: View {
    @Query private var settingsRows: [AccountSettings]

    var body: some View {
        if let settings = settingsRows.first {
            GeneralForm(settings: settings)
        }
    }
}

private struct GeneralForm: View {
    @Bindable var settings: AccountSettings
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var keeper = appModel.activityKeeper

        Form {
            Section {
                Toggle("Keep this Mac awake while the app is open", isOn: $keeper.isEnabled)
            } footer: {
                Text("Keeps the display on and stops the screen from locking when idle. It doesn't count as keyboard or mouse use, so apps that track idle time can still show you as away. Pauses while the lid is closed or the screen is locked.")
            }
            Section {
                Stepper(value: $settings.pollIntervalMinutes, in: 1...60) {
                    LabeledContent("Refresh every", value: "\(settings.pollIntervalMinutes) min")
                }
            } footer: {
                Text("Refreshes automatically while the app is running, even with its window closed, so the menu bar count stays current. ⌘R refreshes at any time.")
            }
            Section {
                Stepper(value: $settings.collapseFileDiffThresholdLines, in: 50...5000, step: 50) {
                    LabeledContent("Collapse file diffs over", value: "\(settings.collapseFileDiffThresholdLines) lines")
                }
            } header: {
                Text("Changes")
            }
        }
        .formStyle(.grouped)
    }
}

struct ChecksSettingsView: View {
    @Query private var settingsRows: [AccountSettings]

    var body: some View {
        if let settings = settingsRows.first {
            ChecksForm(settings: settings)
        }
    }
}

private struct ChecksForm: View {
    @Bindable var settings: AccountSettings

    var body: some View {
        Form {
            Section {
                Stepper(value: $settings.diffSizeLimitLines, in: 100...20_000, step: 100) {
                    LabeledContent("Diff size limit", value: "\(settings.diffSizeLimitLines) lines")
                }
            } footer: {
                Text("Added plus removed lines, not counting generated files.")
            }
            Section {
                PatternListEditor(title: "Debug output", patterns: $settings.debugPatterns,
                                  defaults: AccountSettings.defaultDebugPatterns)
                PatternListEditor(title: "TODO markers", patterns: $settings.todoMarkers,
                                  defaults: AccountSettings.defaultTodoMarkers)
            } header: {
                Text("Flags in added lines")
            } footer: {
                Text("One per line. Matched as plain text that isn't part of a longer word, so “print(” doesn't match “fingerprint(”. Likely secrets (AWS, GitHub, GitLab, Slack, Stripe and Google keys, private keys, hard-coded passwords) are always checked.")
            }
            Section {
                PatternListEditor(title: "Extra test paths", patterns: $settings.extraTestPathPatterns, defaults: [])
            } header: {
                Text("Test files")
            } footer: {
                Text("Files in test/, tests/, spec/, __tests__/ and names like test_x.py, x_test.go, x.test.ts or XTests.swift already count as tests. Add path fragments for anything else, e.g. “Fixtures/”.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Edits a list of strings as one-per-line text.
private struct PatternListEditor: View {
    let title: String
    @Binding var patterns: [String]
    let defaults: [String]
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                if !defaults.isEmpty {
                    Button("Reset") {
                        patterns = defaults
                        text = defaults.joined(separator: "\n")
                    }
                    .disabled(patterns == defaults)
                    .controlSize(.small)
                }
            }
            TextEditor(text: $text)
                .font(.body.monospaced())
                .frame(minHeight: 70, maxHeight: 120)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(Color.secondary.opacity(0.08), in: .rect(cornerRadius: 6))
                .accessibilityLabel(title)
                .onChange(of: text) { commit() }
        }
        .onAppear { text = patterns.joined(separator: "\n") }
    }

    private func commit() {
        let parsed = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if parsed != patterns { patterns = parsed }
    }
}
