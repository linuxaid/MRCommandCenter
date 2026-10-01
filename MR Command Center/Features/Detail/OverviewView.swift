import SwiftData
import SwiftUI

struct OverviewView: View {
    let mr: TrackedMR

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                StaticChecksSection(mr: mr)
                if let error = mr.detailsError {
                    Label("Couldn't load some details: \(error)", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                // Adaptive columns: two when wide, one when narrow. A `Grid` here caused an
                // endless AppKit constraint loop when the inspector was open.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    PipelineSection(mr: mr)
                    ApprovalsSection(mr: mr)
                    MergeabilitySection(mr: mr)
                    OverviewJiraSection(mr: mr)
                }
                DescriptionSection(text: mr.descriptionText)
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mr.title)
                .font(.title2.bold())
                .textSelection(.enabled)
            Text("\(mr.reference) · opened by \(mr.authorName) (@\(mr.authorUsername)) \(mr.createdAt, format: .relative(presentation: .named))")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .accessibilityHidden(true)
                Text(mr.sourceBranch).monospaced()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "arrow.right")
                    .accessibilityLabel("into")
                Text(mr.targetBranch).monospaced()
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .help("\(mr.sourceBranch) → \(mr.targetBranch)")
            .font(.callout)
            .textSelection(.enabled)
            if !mr.labels.isEmpty {
                LabelList(labels: mr.labels, styles: mr.labelStyles)
            }
        }
    }
}

/// A titled box used for each Overview section.
private struct OverviewSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Label(title, systemImage: systemImage)
                .font(.headline)
        }
    }
}

private struct PipelineSection: View {
    let mr: TrackedMR

    var body: some View {
        OverviewSection(title: "Pipeline", systemImage: "gearshape.2") {
            StatusChip(item: MRStatusLine.pipelineItem(for: mr))
                .font(.body)
            if let sha = mr.pipelineSHA, !mr.headSHA.isEmpty, sha != mr.headSHA {
                Label("This pipeline ran on \(sha.prefix(8)), not the head commit \(mr.shortSHA).", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            LabeledContent("Head commit") {
                Text(mr.shortSHA).monospaced().textSelection(.enabled)
            }
            if let link = mr.pipelineWebURL.flatMap(URL.init(string:)) {
                Link("View pipeline", destination: link)
            }
        }
    }
}

private struct ApprovalsSection: View {
    let mr: TrackedMR

    var body: some View {
        OverviewSection(title: "Approvals", systemImage: "checkmark.seal") {
            if let item = MRStatusLine.approvalsItem(for: mr) {
                StatusChip(item: item)
                    .font(.body)
                if mr.approvedBy.isEmpty {
                    Text("No approvals yet").foregroundStyle(.secondary)
                } else {
                    Text("Approved by \(mr.approvedBy.formatted(.list(type: .and)))")
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Loading…").foregroundStyle(.secondary)
            }
        }
    }
}

private struct MergeabilitySection: View {
    let mr: TrackedMR

    var body: some View {
        OverviewSection(title: "Mergeability", systemImage: "arrow.triangle.merge") {
            row(ok: !mr.hasConflicts, okText: "No merge conflicts", problemText: "Has merge conflicts")
            row(ok: !mr.isDraft, okText: "Ready (not a draft)", problemText: "Draft")
            row(ok: mr.unresolvedDiscussions == 0,
                okText: mr.resolvableDiscussions == 0 ? "No discussion threads"
                    : mr.resolvableDiscussions == 1 ? "The only thread is resolved" : "All \(mr.resolvableDiscussions) threads resolved",
                problemText: "\(mr.unresolvedDiscussions) unresolved of \(mr.resolvableDiscussions) threads")
        }
    }

    private func row(ok: Bool, okText: String, problemText: String) -> some View {
        Label {
            Text(ok ? okText : problemText)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}

private struct OverviewJiraSection: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @Query private var settingsRows: [AccountSettings]

    var body: some View {
        OverviewSection(title: "Jira", systemImage: "ticket") {
            if let key = mr.jiraKey {
                switch mr.jiraLookup {
                case .found, .failed:
                    if let details = appModel.jira.details(for: key) {
                        JiraDetails(details: details, passing: mr.jiraPassing == true, browseURL: browseURL(key))
                        if let error = mr.jiraError {
                            Label("Last refresh failed: \(error)", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Label("\(key): couldn't load the issue (\(mr.jiraError ?? "unknown error")).", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                case .notFound:
                    Label("\(key) wasn't found in Jira, or your token can't see it.", systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                case .notConfigured:
                    Text(key).font(.body.monospaced())
                    HStack {
                        Text("Connect Jira to see the story, status, and acceptance criteria.")
                            .font(.caption).foregroundStyle(.secondary)
                        SettingsLink { Text("Open Accounts…") }.font(.caption)
                    }
                case nil:
                    HStack {
                        Text(key).font(.body.monospaced())
                        ProgressView().controlSize(.small)
                    }
                }
            } else {
                Label("No Jira key in branch \(mr.sourceBranch)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
    }

    private func browseURL(_ key: String) -> URL? {
        guard let base = try? BaseURL.normalize(settingsRows.first?.jiraBaseURL ?? "", strippingSuffixes: BaseURL.jiraSuffixes) else { return nil }
        return base.appending(path: "browse").appending(path: key)
    }
}

private struct JiraDetails: View {
    let details: JiraIssueDetails
    let passing: Bool
    let browseURL: URL?
    @State private var showsDescription = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                if let browseURL {
                    Link(destination: browseURL) {
                        Text("\(details.key): \(details.summary)").bold()
                    }
                } else {
                    Text("\(details.key): \(details.summary)").bold()
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow {
                    Text("Status").foregroundStyle(.secondary)
                    Label(details.status, systemImage: passing ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(passing ? .green : .orange)
                        .accessibilityLabel("\(details.status)\(passing ? ", passing" : ", not a passing status")")
                }
                if let type = details.issueType {
                    GridRow { Text("Type").foregroundStyle(.secondary); Text(type) }
                }
                GridRow { Text("Assignee").foregroundStyle(.secondary); Text(details.assignee ?? "Unassigned") }
                GridRow {
                    Text("Priority").foregroundStyle(.secondary)
                    if details.hasPriority {
                        Text(details.priority ?? "")
                    } else {
                        Label("Not set", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                GridRow {
                    Text("Fix versions").foregroundStyle(.secondary)
                    Text(details.fixVersions.isEmpty ? "None" : details.fixVersions.joined(separator: ", "))
                }
            }
            .font(.callout)

            if let criteria = details.acceptanceCriteria {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text("Acceptance criteria").font(.callout.bold())
                        Text(details.acceptanceCriteriaSource == .customField ? "from the criteria field" : "from the description")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text(criteria)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                .padding(.top, 4)
            } else {
                Text("No acceptance criteria found; the AI review compares against the story description.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let description = details.description, !description.isEmpty {
                DisclosureGroup("Story description", isExpanded: $showsDescription) {
                    Text(description).font(.callout).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.callout)
            }
        }
    }
}

private struct DescriptionSection: View {
    let text: String

    var body: some View {
        OverviewSection(title: "Description", systemImage: "text.alignleft") {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("No description").foregroundStyle(.secondary)
            } else {
                Text(rendered)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Inline Markdown (bold, code, links) with line breaks preserved. GitLab-specific
    /// syntax shows as plain text.
    private var rendered: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
