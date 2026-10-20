import SwiftData
import SwiftUI

/// The rules, the master switch, and what each rule covers right now.
struct RulesListView: View {
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MERGE RULES").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                    Text("Merge without lifting a finger")
                        .font(Theme.headline(26))
                        .foregroundStyle(Theme.ink)
                    Text("A rule picks merge requests by project, branch, label, or author, and merges them once everything it asks for is green. GitLab's own approval and pipeline rules still apply.")
                        .foregroundStyle(Theme.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                MasterSwitch()
                VStack(spacing: 8) {
                    ForEach(center.rules) { rule in
                        RuleCard(rule: rule)
                    }
                }
                Button {
                    center.addRule()
                } label: {
                    Label("New Rule", systemImage: "plus")
                }
                .controlSize(.large)
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.canvas)
    }
}

private struct MasterSwitch: View {
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        let isOn = center.isAutoMergeLive
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: isOn ? "bolt.fill" : "eye")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(isOn ? Theme.autoMerge : Theme.inkSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(isOn ? "Merging automatically" : "Dry run")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text(isOn
                     ? "Rules merge through the GitLab API as soon as an MR is ready, pinned to the exact commit they checked. The app keeps refreshing in the background while this is on, as long as it's running."
                     : "Rules only report what they would merge, in Activity. Nothing is merged. Turn this on when the rules look right.")
                    .font(.callout)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isOn {
                    Text("Needs a token with the **api** scope and permission to merge in each project.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
            }
            Spacer()
            Toggle("Merge automatically", isOn: Binding(get: { isOn }, set: { center.setAutoMergeLive($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .tint(Theme.autoMerge)
        }
        .padding(16)
        .card(isSelected: isOn, accent: Theme.autoMerge)
    }
}

private struct RuleCard: View {
    @Bindable var rule: MergeRule
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        let covered = center.coveredMergeRequests(by: rule)
        let ready = covered.count { MergeRuleEngine.unmet(rule, $0).isEmpty }
        let isSelected = center.selectedRuleID == rule.id

        HStack(alignment: .top, spacing: 12) {
            Toggle("Enabled", isOn: $rule.isEnabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.autoMerge)
            VStack(alignment: .leading, spacing: 4) {
                Text(rule.name)
                    .font(.headline)
                    .foregroundStyle(rule.isEnabled ? Theme.ink : Theme.inkTertiary)
                Text(RuleDescription.filters(rule))
                    .font(.callout)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Text(covered.count == 1 ? "Covers 1 open MR" : "Covers \(covered.count) open MRs")
                    if ready > 0 { Text("\(ready) ready").foregroundStyle(Theme.ready) }
                    if rule.mergeCount > 0 { Text("Merged \(rule.mergeCount)") }
                }
                .font(.caption)
                .foregroundStyle(Theme.inkTertiary)
            }
            Spacer()
        }
        .padding(14)
        .card(isSelected: isSelected, accent: Theme.autoMerge)
        .contentShape(.rect)
        .onTapGesture { center.selectedRuleID = rule.id }
        .contextMenu {
            Button("Move Up") { center.move(rule, by: -1) }
            Button("Move Down") { center.move(rule, by: 1) }
            Divider()
            Button("Delete Rule", role: .destructive) { center.delete(rule) }
        }
    }
}

/// Plain-English summaries of a rule.
enum RuleDescription {
    static func filters(_ rule: MergeRule) -> String {
        var parts: [String] = []
        if rule.onlyMine { parts.append("your MRs") }
        let authors = rule.authorUsernames.filter { !$0.isEmpty }
        if !authors.isEmpty { parts.append("by " + authors.map { "@\($0)" }.formatted(.list(type: .or))) }
        if !rule.projectPattern.isEmpty { parts.append("in \(rule.projectPattern)") }
        if !rule.sourceBranchPattern.isEmpty { parts.append("from \(rule.sourceBranchPattern)") }
        if !rule.targetBranchPattern.isEmpty { parts.append("into \(rule.targetBranchPattern)") }
        if !rule.requiredLabels.isEmpty { parts.append("labeled " + rule.requiredLabels.formatted(.list(type: .and))) }
        let subject = parts.isEmpty ? "Every merge request" : "Merge requests " + parts.joined(separator: " ")
        return subject + ", once " + requirements(rule).formatted(.list(type: .and)) + "."
    }

    static func requirements(_ rule: MergeRule) -> [String] {
        var items = ["the pipeline passes", "approvals are met"]
        if rule.requireNoOpenThreads { items.append("threads are resolved") }
        if rule.requireChecksPass { items.append("static checks pass") }
        if rule.requireAILooksGood { items.append("the AI review looks good") }
        if rule.quietMinutes > 0 { items.append("\(rule.quietMinutes) min pass without a push") }
        return items
    }
}

/// Edits one rule, with a live list of the open MRs it covers.
struct RuleEditor: View {
    @Bindable var rule: MergeRule
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.isEnabled)
            } footer: {
                Text(RuleDescription.filters(rule))
            }

            Section {
                TextField("Project", text: $rule.projectPattern, prompt: Text("Any, or e.g. platform/*"))
                TextField("Target branch", text: $rule.targetBranchPattern, prompt: Text("Any, or e.g. main"))
                TextField("Source branch", text: $rule.sourceBranchPattern, prompt: Text("Any, or e.g. renovate/*"))
                TextField("Labels (all required)", text: listBinding(\.requiredLabels), prompt: Text("e.g. dependencies"))
                TextField("Authors", text: listBinding(\.authorUsernames), prompt: Text("Anyone, or e.g. renovate-bot"))
                Toggle("Only merge requests I opened", isOn: $rule.onlyMine)
            } header: {
                Text("Which merge requests")
            } footer: {
                Text("Patterns are globs: * matches anything. Separate several with commas. Empty fields match everything.")
            }

            Section {
                LabeledContent("Always") {
                    Text("Not a draft, pipeline passed on the latest commit, approvals met, no conflicts, and GitLab allows the merge")
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(.secondary)
                }
                Toggle("All threads resolved", isOn: $rule.requireNoOpenThreads)
                Toggle("Static checks pass", isOn: $rule.requireChecksPass)
                Toggle("AI review says it looks good", isOn: $rule.requireAILooksGood)
                Stepper(value: $rule.quietMinutes, in: 0...1440, step: 5) {
                    LabeledContent("Wait after the last push", value: rule.quietMinutes == 0 ? "No wait" : "\(rule.quietMinutes) min")
                }
                Stepper(value: $rule.maxChangedFiles, in: 0...500, step: 5) {
                    LabeledContent("Changed files", value: rule.maxChangedFiles == 0 ? "Any number" : "\(rule.maxChangedFiles) or fewer")
                }
            } header: {
                Text("When it's ready")
            }

            Section("How to merge") {
                Toggle("Squash commits", isOn: $rule.squash)
                Toggle("Delete the source branch", isOn: $rule.removeSourceBranch)
            }

            Section {
                let covered = center.coveredMergeRequests(by: rule)
                if covered.isEmpty {
                    Text("No open merge request matches this rule yet.").foregroundStyle(.secondary)
                }
                ForEach(covered, id: \.key) { mr in
                    let unmet = MergeRuleEngine.unmet(rule, mr)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(mr.title).lineLimit(1)
                            Spacer()
                            if unmet.isEmpty {
                                Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.ready)
                            }
                        }
                        Text(unmet.isEmpty ? mr.reference : "\(mr.reference) · waits until \(unmet.formatted(.list(type: .and)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        appModel.mergeRequests.selectedKey = mr.key
                        center.destination = .briefing
                    }
                }
            } header: {
                Text("Matches right now")
            } footer: {
                if !center.isAutoMergeLive {
                    Text("Merging is off (dry run). Ready matches are reported in Activity, not merged.")
                }
            }

            Section {
                Button("Delete Rule", role: .destructive) { center.delete(rule) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.canvas)
    }

    /// Edits a string list as comma-separated text.
    private func listBinding(_ keyPath: ReferenceWritableKeyPath<MergeRule, [String]>) -> Binding<String> {
        Binding(
            get: { rule[keyPath: keyPath].joined(separator: ", ") },
            set: { text in
                rule[keyPath: keyPath] = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            }
        )
    }
}
