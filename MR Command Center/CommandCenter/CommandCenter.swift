import Foundation
import Observation
import SwiftData
import os

/// A merge you started that GitLab refused or that failed on the way.
struct MergeFailure: Identifiable, Equatable {
    let mrKey: String
    let reference: String
    let title: String
    let message: String

    var id: String { mrKey }
}

/// A merge waiting for your confirmation, pinned to the commit you saw.
struct MergeDraft: Identifiable {
    let mrKey: String
    let reference: String
    let title: String
    let sourceBranch: String
    let targetBranch: String
    let sha: String
    /// Things that aren't green yet; GitLab will refuse or wait on them.
    let notReady: [String]
    /// The pipeline is still running, so "merge when it passes" is the sensible choice.
    let pipelineRunning: Bool
    var squash: Bool
    var removeSourceBranch: Bool
    var whenPipelineSucceeds: Bool

    var id: String { mrKey + sha }

    init(mr: TrackedMR, situation: MRSituation) {
        mrKey = mr.key
        reference = mr.reference
        title = mr.title
        sourceBranch = mr.sourceBranch
        targetBranch = mr.targetBranch
        sha = mr.headSHA
        notReady = situation.readiness.steps.filter { $0.state != .done }.map { "\($0.kind.shortTitle): \($0.summary)" }
        pipelineRunning = situation.readiness.step(.pipeline).state == .waiting && mr.pipelineStatus?.isActive == true
        squash = UserDefaults.standard.bool(forKey: "mergeSquash")
        removeSourceBranch = UserDefaults.standard.object(forKey: "mergeRemoveSourceBranch") as? Bool ?? true
        whenPipelineSucceeds = pipelineRunning
    }
}

/// What the main window's sidebar points at.
enum Destination: Hashable {
    case briefing
    case lane(Lane)
    case activity
    case rules
}

/// The triage layer over `MergeRequestStore`: which lane each MR is in, the merge rules,
/// and the automatic merges they trigger.
@Observable
final class CommandCenter {
    var destination: Destination = .briefing {
        // Merged or closed MRs are only reachable from Activity.
        didSet { if destination != .activity { store.selectedPastKey = nil } }
    }
    /// The rule being edited on the Rules page.
    var selectedRuleID: UUID?
    private(set) var rules: [MergeRule] = []
    /// MRs with an approve or merge request in flight right now.
    private(set) var mergingKeys: Set<String> = []
    /// The last approve/merge failure per MR, shown in its brief until the next attempt.
    private(set) var actionErrors: [String: String] = [:]
    /// The MR waiting for you to confirm a merge (drives the merge sheet).
    var mergeDraft: MergeDraft?
    /// Merges you started that failed after the dialog closed, newest first. Shown as a banner
    /// until dismissed, since you've usually moved on to another MR by then.
    private(set) var mergeFailures: [MergeFailure] = []

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }
    private let dependencies: AppDependencies
    let store: MergeRequestStore

    init(container: ModelContainer, dependencies: AppDependencies, store: MergeRequestStore) {
        self.container = container
        self.dependencies = dependencies
        self.store = store
        reloadRules()
    }

    private var settings: AccountSettings { AccountSettings.current(in: context) }

    /// Off means rules run as a dry run: they report what they'd merge and merge nothing.
    var isAutoMergeLive: Bool { settings.autoMergeEnabled }

    var hasEnabledRules: Bool { rules.contains(where: \.isEnabled) }

    // MARK: Triage

    func ruleStatus(for mr: TrackedMR, now: Date = .now) -> RuleStatus? {
        MergeRuleEngine.status(for: mr, rules: rules,
                               context: .init(me: store.username, isLive: isAutoMergeLive, now: now))
    }

    func situation(for mr: TrackedMR) -> MRSituation {
        MRSituation.make(for: mr, me: store.username, rule: ruleStatus(for: mr))
    }

    /// Open MRs grouped by lane, each lane newest first.
    func lanes() -> [Lane: [TrackedMR]] {
        Dictionary(grouping: store.trackedMergeRequests) { situation(for: $0).lane }
    }

    /// The lanes a destination shows, in display order.
    func lanesShown(for destination: Destination) -> [Lane] {
        switch destination {
        case .briefing: [.yourMove, .readyToMerge, .autoMerge, .inFlight]
        case .lane(let lane): [lane]
        case .activity, .rules: []
        }
    }

    /// Keys in the order the list shows them, for keyboard navigation.
    func orderedKeys(for destination: Destination) -> [String] {
        let lanes = lanes()
        return lanesShown(for: destination).flatMap { lanes[$0] ?? [] }.map(\.key)
    }

    func selectNext() { store.moveSelection(by: 1, in: orderedKeys(for: destination)) }
    func selectPrevious() { store.moveSelection(by: -1, in: orderedKeys(for: destination)) }

    // MARK: Set aside

    /// Parks a Your move MR in the Set aside lane until something new happens on it.
    /// Local only: nothing is sent to GitLab.
    func setAside(_ mr: TrackedMR) {
        let situation = situation(for: mr)
        guard situation.lane == .yourMove, let reason = situation.yourMoveReason else { return }
        mr.setAsideAt = .now
        mr.setAsideSHA = mr.headSHA
        mr.setAsideReason = reason.rawValue
        mr.setAsideReplyAt = mr.lastReplyToMeAt
        recordOwn(.init(kind: .setAside, message: "You set this aside: \(situation.headline)"), for: mr)
        save()
    }

    /// Puts a set-aside MR back in Your move right away.
    func bringBack(_ mr: TrackedMR) {
        guard mr.setAsideAt != nil else { return }
        clearSetAside(mr)
        recordOwn(.init(kind: .broughtBack, message: "You brought this back to Your move"), for: mr)
        save()
    }

    /// Something you just did: it goes in Activity without marking the MR as having news.
    private func recordOwn(_ change: ActivityDetector.Change, for mr: TrackedMR) {
        let alreadySeen = !mr.hasUnseenActivity
        store.record(change, for: mr)
        if alreadySeen { mr.seenAt = mr.lastActivityAt }
    }

    /// After a refresh: MRs where something new happened leave Set aside for good, so the same
    /// reason coming round again can't park them a second time. An MR that's only out of Your
    /// move for a while (a pipeline rerunning, GitLab rechecking conflicts) stays set aside.
    func releaseSetAside() {
        var changed = false
        for mr in store.trackedMergeRequests where mr.setAsideAt != nil {
            // Stores from before reply times were kept: take the first one we learn as already seen.
            if mr.setAsideReplyAt == nil, let latest = mr.lastReplyToMeAt {
                mr.setAsideReplyAt = latest
                changed = true
            }
            let natural = MRSituation.ignoringSetAside(for: mr, me: store.username, rule: ruleStatus(for: mr))
            guard MRSituation.somethingNewSinceSetAside(mr, reason: natural.yourMoveReason) else { continue }
            clearSetAside(mr)
            changed = true
            if natural.lane == .yourMove {
                store.record(.init(kind: .broughtBack, message: "Something new happened, so it's back in Your move"), for: mr)
            }
        }
        if changed { save() }
    }

    private func clearSetAside(_ mr: TrackedMR) {
        mr.setAsideAt = nil
        mr.setAsideSHA = nil
        mr.setAsideReason = nil
        mr.setAsideReplyAt = nil
    }

    // MARK: Rules

    func reloadRules() {
        let descriptor = FetchDescriptor<MergeRule>(sortBy: [SortDescriptor(\.sortOrder), SortDescriptor(\.createdAt)])
        rules = (try? context.fetch(descriptor)) ?? []
    }

    /// A new rule, prefilled from an MR when given ("merge more like this one").
    @discardableResult
    func addRule(like mr: TrackedMR? = nil) -> MergeRule {
        let rule = MergeRule(name: "New rule", sortOrder: (rules.map(\.sortOrder).max() ?? -1) + 1)
        if let mr {
            rule.name = "Like \(mr.reference)"
            rule.projectPattern = mr.projectPath
            rule.targetBranchPattern = mr.targetBranch
            if mr.isAuthor {
                rule.onlyMine = true
            } else {
                rule.authorUsernames = [mr.authorUsername]
            }
            rule.requiredLabels = mr.labels
        } else {
            rule.targetBranchPattern = "main"
        }
        context.insert(rule)
        save()
        reloadRules()
        selectedRuleID = rule.id
        return rule
    }

    func delete(_ rule: MergeRule) {
        if selectedRuleID == rule.id { selectedRuleID = nil }
        context.delete(rule)
        save()
        reloadRules()
    }

    func move(_ rule: MergeRule, by offset: Int) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        let target = index + offset
        guard rules.indices.contains(target) else { return }
        var reordered = rules
        reordered.swapAt(index, target)
        for (order, rule) in reordered.enumerated() where rule.sortOrder != order {
            rule.sortOrder = order
        }
        save()
        reloadRules()
    }

    /// Open MRs this rule covers right now (whether or not they're ready).
    func coveredMergeRequests(by rule: MergeRule) -> [TrackedMR] {
        store.trackedMergeRequests.filter { MergeRuleEngine.covers(rule, $0, me: store.username) }
    }

    func setAutoMergeLive(_ isOn: Bool) {
        settings.autoMergeEnabled = isOn
        save()
    }

    // MARK: Approving and merging by hand

    /// Approves at the commit you're looking at, so nothing pushed since gets your approval.
    func approve(_ mr: TrackedMR) async {
        await perform(on: mr) { client in
            let approvals = try await client.approve(projectID: mr.projectID, iid: mr.iid, sha: mr.headSHA)
            mr.apply(approvals: approvals)
            self.store.record(.init(kind: .approved, message: "You approved"), for: mr)
        }
    }

    func revokeApproval(_ mr: TrackedMR) async {
        await perform(on: mr) { client in
            try await client.unapprove(projectID: mr.projectID, iid: mr.iid)
            if let me = self.store.username, let index = mr.approvedByUsernames.firstIndex(of: me) {
                mr.approvedByUsernames.remove(at: index)
                if mr.approvedBy.indices.contains(index) { mr.approvedBy.remove(at: index) }
                mr.approvalsGiven = max(0, mr.approvalsGiven - 1)
            }
            self.store.record(.init(kind: .approvalRevoked, message: "You removed your approval"), for: mr)
        }
    }

    /// Starts the merge confirmation for an MR.
    func requestMerge(_ mr: TrackedMR) {
        mergeDraft = MergeDraft(mr: mr, situation: situation(for: mr))
    }

    /// Starts the merge without waiting for GitLab, so the dialog can close and you can move on.
    /// Returns nil when it can't start (new commits arrived, or a merge or approval for this MR
    /// is already running); the reason is in `actionErrors` and the dialog should stay open.
    @discardableResult
    func startMerge(_ draft: MergeDraft) -> Task<Void, Never>? {
        guard let mr = store.mergeRequest(forKey: draft.mrKey) else { return nil }
        guard !mergingKeys.contains(mr.key) else {
            actionErrors[mr.key] = Self.busyMessage
            return nil
        }
        guard mr.headSHA == draft.sha else {
            actionErrors[mr.key] = Self.staleMergeMessage
            return nil
        }
        mergeFailures.removeAll { $0.mrKey == draft.mrKey }
        // Claimed now, not when the task runs: the row shows the spinner at once, and rules and
        // approvals can't act on this MR in between. The task holds `mr` itself, so the merge
        // still goes ahead if a refresh drops it from the list meanwhile.
        mergingKeys.insert(mr.key)
        return Task {
            guard let message = await send(draft, for: mr, isClaimed: true) else { return }
            mergeFailures.removeAll { $0.mrKey == draft.mrKey }
            mergeFailures.insert(MergeFailure(mrKey: draft.mrKey, reference: draft.reference, title: draft.title, message: message), at: 0)
        }
    }

    func dismissMergeFailure(_ failure: MergeFailure) {
        mergeFailures.removeAll { $0.id == failure.id }
    }

    /// Whether the failed MR is still in your list, so "Show" has something to open.
    func canShow(_ failure: MergeFailure) -> Bool {
        store.mergeRequest(forKey: failure.mrKey) != nil
    }

    /// Opens the MR whose merge failed (its brief has the same error) on a page that lists it,
    /// so the arrow keys carry on from there.
    func show(_ failure: MergeFailure) {
        guard let mr = store.mergeRequest(forKey: failure.mrKey) else { return }
        dismissMergeFailure(failure)
        let lane = situation(for: mr).lane
        if !lanesShown(for: destination).contains(lane) {
            destination = lanesShown(for: .briefing).contains(lane) ? .briefing : .lane(lane)
        }
        store.selectedKey = mr.key
    }

    private static let staleMergeMessage = "New commits arrived after you opened the merge dialog. Look again before merging."
    private static let busyMessage = "A merge or approval for this merge request is already running. Wait for it to finish."

    /// Merges at the commit the confirmation showed, or tells GitLab to merge once the pipeline passes.
    /// Returns this merge's failure message, or nil if it went through.
    @discardableResult
    private func send(_ draft: MergeDraft, for mr: TrackedMR, isClaimed: Bool = false) async -> String? {
        await perform(on: mr, isClaimed: isClaimed) { client in
            let options = MergeOptions(sha: draft.sha, squash: draft.squash, shouldRemoveSourceBranch: draft.removeSourceBranch,
                                       mergeWhenPipelineSucceeds: draft.whenPipelineSucceeds ? true : nil)
            let result = try await client.merge(projectID: mr.projectID, iid: mr.iid, options: options)
            if result.state == "merged" || !draft.whenPipelineSucceeds {
                mr.isInReviewerList = false
                self.store.record(.init(kind: .autoMerged, message: "You merged this"), for: mr)
                self.store.reloadFromStore()
            } else {
                mr.mergeWhenPipelineSucceeds = true
                self.store.record(.init(kind: .autoMergeWouldMerge, message: "You set it to merge when the pipeline passes"), for: mr)
            }
        }
    }

    /// Runs one approve or merge call with the MR marked busy. `isClaimed` means the caller already
    /// marked it. Returns the failure shown in the brief, or nil on success (or if it was busy).
    @discardableResult
    private func perform(on mr: TrackedMR, isClaimed: Bool = false,
                         _ action: @escaping (any GitLabAPI) async throws -> Void) async -> String? {
        if !isClaimed {
            guard !mergingKeys.contains(mr.key) else { return nil }
            mergingKeys.insert(mr.key)
        }
        defer { mergingKeys.remove(mr.key) }
        actionErrors[mr.key] = nil
        do {
            let client = try dependencies.gitLabClient(settings: settings)
            try await action(client)
            save()
            if mr.isInReviewerList {
                await store.refreshDetails(for: mr)
            }
            return nil
        } catch {
            let message = Self.describeActionFailure(error)
            actionErrors[mr.key] = message
            Log.sync.error("MR action failed: \(error.localizedDescription, privacy: .public)")
            return message
        }
    }

    static func describeActionFailure(_ error: any Error) -> String {
        switch error as? APIError {
        case .forbidden?:
            "GitLab refused (403). This needs a token with the api scope, and permission for this in the project."
        case .unauthorized?:
            "GitLab refused (401). You may have already approved, or the project doesn't let you approve this MR."
        case .server(status: 409)?:
            "New commits were pushed since you last refreshed, so GitLab refused. Look at the latest changes first."
        case .server(status: 405)?:
            "GitLab says it can't be merged right now (405): something it requires isn't met yet."
        case .server(status: 406)?:
            "GitLab couldn't merge the branch (406), usually because of conflicts."
        case .server(status: 422)?:
            "GitLab rejected the merge (422)."
        default:
            error.localizedDescription
        }
    }

    // MARK: Automatic merging

    /// Merges every MR whose rule says it's ready, at exactly the commit that was checked.
    /// Each head commit is handled once, so a refusal isn't retried until something is pushed.
    func runRules(now: Date = .now) async {
        guard hasEnabledRules else { return }
        let isLive = isAutoMergeLive
        var client: (any GitLabAPI)?
        var mergedAny = false

        for mr in store.trackedMergeRequests where !mr.isDraft && !mergingKeys.contains(mr.key) {
            guard let status = ruleStatus(for: mr, now: now), status.isReady,
                  mr.autoMergeHandledSHA != mr.headSHA, !mr.headSHA.isEmpty,
                  let rule = rules.first(where: { $0.id == status.ruleID }) else { continue }
            mr.autoMergeHandledSHA = mr.headSHA

            guard isLive else {
                store.record(.init(kind: .autoMergeWouldMerge,
                                   message: "Rule “\(rule.name)” would have merged this (dry run)"), for: mr)
                continue
            }
            if client == nil {
                client = try? dependencies.gitLabClient(settings: settings)
            }
            guard let client else { return }

            mergingKeys.insert(mr.key)
            defer { mergingKeys.remove(mr.key) }
            do {
                let options = MergeOptions(sha: mr.headSHA, squash: rule.squash, shouldRemoveSourceBranch: rule.removeSourceBranch)
                _ = try await client.merge(projectID: mr.projectID, iid: mr.iid, options: options)
                rule.mergeCount += 1
                rule.lastMergedAt = .now
                mr.autoMergeError = nil
                mr.isInReviewerList = false
                store.record(.init(kind: .autoMerged, message: "Merged automatically by rule “\(rule.name)”"), for: mr)
                mergedAny = true
                Log.sync.info("Rule merged an MR")
            } catch {
                let (message, retry) = Self.describeMergeFailure(error)
                mr.autoMergeError = message
                if retry { mr.autoMergeHandledSHA = nil }
                store.record(.init(kind: .autoMergeFailed, message: "Automatic merge failed: \(message)"), for: mr)
                Log.sync.error("Rule merge failed: \(message, privacy: .public)")
            }
        }
        save()
        if mergedAny { store.reloadFromStore() }
    }

    /// A readable reason, and whether to try again on the next refresh for the same commit.
    static func describeMergeFailure(_ error: any Error) -> (String, retry: Bool) {
        switch error as? APIError {
        case .server(status: 405)?:
            ("GitLab says it can't be merged right now (405). It may be waiting on a check GitLab knows about.", false)
        case .server(status: 406)?:
            ("GitLab couldn't merge the branch (406), usually because of conflicts.", false)
        case .server(status: 409)?:
            ("New commits arrived before the merge, so GitLab refused it (409). It'll be checked again.", true)
        case .server(status: 422)?:
            ("GitLab rejected the merge (422).", false)
        case .forbidden?, .unauthorized?:
            ("The token can't merge. Merging needs a token with the api scope and permission to merge in this project.", false)
        case .offline?, .rateLimited?:
            (error.localizedDescription, true)
        default:
            (error.localizedDescription, false)
        }
    }

    private func save() {
        do {
            try context.save()
        } catch {
            Log.persistence.error("Saving rules failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
