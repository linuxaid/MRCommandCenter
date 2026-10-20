import SwiftUI

/// Approve (or revoke) and Merge for one MR. Approving is immediate; merging asks first.
struct MRActionButtons: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    private var center: CommandCenter { appModel.commandCenter }

    var body: some View {
        let situation = center.situation(for: mr)
        let iApproved = appModel.mergeRequests.username.map { mr.approvedByUsernames.contains($0) } ?? false
        let isBusy = center.mergingKeys.contains(mr.key)

        if !mr.isAuthor {
            if iApproved {
                Button {
                    Task { await center.revokeApproval(mr) }
                } label: {
                    Label("Revoke", systemImage: "seal")
                }
                .disabled(isBusy)
                .help("Remove your approval (⇧⌘A)")
            } else {
                Button {
                    Task { await center.approve(mr) }
                } label: {
                    Label("Approve", systemImage: "checkmark.seal.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ready)
                .disabled(isBusy || !mr.hasLoadedDetails)
                .help("Approve commit \(mr.shortSHA) (⇧⌘A)")
            }
        }

        Button {
            center.requestMerge(mr)
        } label: {
            Label(mr.mergeWhenPipelineSucceeds ? "Merging…" : "Merge…", systemImage: "arrow.triangle.merge")
        }
        .buttonStyle(.borderedProminent)
        .tint(situation.readiness.isReady ? Theme.ready : Theme.inkSecondary)
        .disabled(isBusy || mr.isDraft || !mr.hasLoadedDetails)
        .help(mr.isDraft ? "Drafts can't be merged" : situation.readiness.isReady ? "Merge into \(mr.targetBranch) (⇧⌘M)"
              : "Not everything is green yet. You'll see what's missing before merging (⇧⌘M).")

        if isBusy {
            ProgressView().controlSize(.small)
        }
    }
}

/// The last approve/merge failure for an MR.
struct MRActionError: View {
    let mr: TrackedMR
    @Environment(AppModel.self) private var appModel

    var body: some View {
        if let error = appModel.commandCenter.actionErrors[mr.key] {
            Label(error, systemImage: "exclamationmark.octagon.fill")
                .font(.callout)
                .foregroundStyle(Theme.danger)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Confirms a merge: what goes where, at which commit, what isn't green, and how to merge.
struct MergeSheet: View {
    @State var draft: MergeDraft
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("MERGE").font(Theme.eyebrow).foregroundStyle(Theme.inkTertiary)
                Text(draft.title)
                    .font(Theme.headline(20))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(draft.reference)
                    Text("·")
                    Text(draft.sourceBranch).lineLimit(1).truncationMode(.middle)
                    Image(systemName: "arrow.right").accessibilityLabel("into")
                    Text(draft.targetBranch).fontWeight(.semibold)
                }
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.inkSecondary)
                Text("At commit \(draft.sha.prefix(8)). If anything is pushed after this, GitLab won't merge it.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkTertiary)
            }

            if !draft.notReady.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Not everything is green", systemImage: "exclamationmark.triangle.fill")
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.caution)
                    ForEach(draft.notReady, id: \.self) { item in
                        Text("• \(item)").foregroundStyle(Theme.inkSecondary)
                    }
                    Text("GitLab will refuse the merge if one of these is required in this project.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkTertiary)
                }
                .font(.callout)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.caution.opacity(0.08), in: .rect(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 8) {
                if draft.pipelineRunning {
                    Toggle("Merge when the pipeline succeeds", isOn: $draft.whenPipelineSucceeds)
                }
                Toggle("Squash commits", isOn: $draft.squash)
                Toggle("Delete the source branch", isOn: $draft.removeSourceBranch)
            }

            if let mr = appModel.mergeRequests.mergeRequest(forKey: draft.mrKey) {
                MRActionError(mr: mr)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    UserDefaults.standard.set(draft.squash, forKey: "mergeSquash")
                    UserDefaults.standard.set(draft.removeSourceBranch, forKey: "mergeRemoveSourceBranch")
                    Task {
                        await appModel.commandCenter.merge(draft)
                        if appModel.commandCenter.actionErrors[draft.mrKey] == nil { dismiss() }
                    }
                } label: {
                    Text(draft.pipelineRunning && draft.whenPipelineSucceeds ? "Merge When Pipeline Succeeds" : "Merge")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.ready)
                .keyboardShortcut(.defaultAction)
                .disabled(appModel.commandCenter.mergingKeys.contains(draft.mrKey))
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Theme.canvas)
    }
}
