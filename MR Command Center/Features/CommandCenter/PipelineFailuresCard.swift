import AppKit
import SwiftUI

/// Why the pipeline failed (#35): each failed job, with the end of its log on request, so you
/// can troubleshoot without leaving the app.
struct PipelineFailuresCard: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel
    @State private var failures = PipelineFailures()
    @State private var openJobs: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("WHY THE PIPELINE FAILED").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                Spacer()
                if let link = mr.pipelineWebURL.flatMap(URL.init(string:)) {
                    Link("Open Pipeline in GitLab", destination: link).font(.caption)
                }
            }
            content
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .card()
        }
        .task(id: LoadKey(mrKey: mr.key, pipelineID: mr.pipelineID)) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        switch failures.phase {
        case .idle, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the failed jobs…").foregroundStyle(Theme.inkSecondary)
            }
            .padding(14)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await load() } }.controlSize(.small)
            }
            .padding(14)
        case .loaded(let jobs) where jobs.isEmpty:
            Text("GitLab lists no failed jobs. The pipeline may have failed before any job ran; open it in GitLab to see why.")
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
        case .loaded(let jobs):
            VStack(spacing: 0) {
                ForEach(Array(jobs.enumerated()), id: \.element.id) { index, job in
                    if index > 0 { Divider().padding(.leading, 40) }
                    jobRow(job)
                }
            }
        }
    }

    private func jobRow(_ job: GitLabJob) -> some View {
        let isOpen = openJobs.contains(job.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                toggle(job)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 10, height: 16)
                    Image(systemName: job.allowFailure == true ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(job.allowFailure == true ? Theme.caution : Theme.danger)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(job.name).fontWeight(.medium).foregroundStyle(Theme.ink)
                            if let stage = job.stage {
                                Text(stage).font(.caption).foregroundStyle(Theme.inkTertiary)
                            }
                        }
                        let notes = [job.failureText, job.allowFailure == true ? "Allowed to fail" : nil].compactMap(\.self)
                        if !notes.isEmpty {
                            Text(notes.joined(separator: " · "))
                                .font(.caption)
                                .foregroundStyle(Theme.inkSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Job \(job.name), failed")
            .accessibilityHint(isOpen ? "Hides its log" : "Shows the end of its log")
            if isOpen {
                log(of: job)
                    .padding(.leading, 18)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func log(of job: GitLabJob) -> some View {
        switch failures.logs[job.id] {
        case nil, .loading?:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading the log…").font(.caption).foregroundStyle(Theme.inkSecondary)
            }
        case .failed(let message)?:
            VStack(alignment: .leading, spacing: 6) {
                Label(message, systemImage: "exclamationmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { Task { await loadLog(job) } }.controlSize(.small)
            }
        case .loaded(let lines, let omitted)?:
            VStack(alignment: .leading, spacing: 6) {
                if lines.isEmpty {
                    Text("The log is empty.").font(.caption).foregroundStyle(Theme.inkSecondary)
                } else {
                    // Fixed height and no minimum width: the log's length must never size the
                    // brief (see the AppKit layout loop gotcha in PLAN.md). It opens at the end,
                    // where the error usually is.
                    ScrollView([.vertical, .horizontal]) {
                        Text(lines.joined(separator: "\n"))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .textSelection(.enabled)
                            .fixedSize()
                            .padding(8)
                    }
                    .defaultScrollAnchor(.bottomLeading)
                    .frame(minWidth: 0, maxWidth: .infinity)
                    .frame(height: 240)
                    .background(Theme.sunken, in: .rect(cornerRadius: 6))
                }
                HStack(spacing: 12) {
                    if omitted > 0 {
                        Text("Last \(lines.count) of \(lines.count + omitted) lines")
                            .font(.caption)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(.link)
                    .disabled(lines.isEmpty)
                    if let link = job.webUrl.flatMap(URL.init(string:)) {
                        Link("Full Log in GitLab", destination: link)
                    }
                }
                .font(.caption)
            }
        }
    }

    private func toggle(_ job: GitLabJob) {
        if openJobs.remove(job.id) == nil {
            openJobs.insert(job.id)
            Task { await loadLog(job) }
        }
    }

    private func load() async {
        guard let pipelineID = mr.pipelineID else { return }
        if failures.pipelineID != pipelineID { openJobs = [] }
        guard let client = try? appModel.commandCenter.gitLabClient() else { return }
        await failures.load(projectID: mr.projectID, pipelineID: pipelineID, client: client)
        // Open the only job that broke the pipeline, since that's the one you'd click.
        if case .loaded(let jobs) = failures.phase, openJobs.isEmpty,
           let only = PipelineFailures.jobToOpen(jobs) {
            openJobs = [only.id]
            await loadLog(only)
        }
    }

    private func loadLog(_ job: GitLabJob) async {
        guard let client = try? appModel.commandCenter.gitLabClient() else { return }
        await failures.loadLog(of: job, projectID: mr.projectID, client: client)
    }

    private struct LoadKey: Equatable {
        let mrKey: String
        let pipelineID: Int?
    }
}
