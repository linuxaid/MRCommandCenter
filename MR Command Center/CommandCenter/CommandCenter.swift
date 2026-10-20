import Foundation
import Observation
import SwiftData
import os

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
    var destination: Destination = .briefing
    /// The rule being edited on the Rules page.
    var selectedRuleID: UUID?
    private(set) var rules: [MergeRule] = []
    /// MRs with a merge request in flight right now.
    private(set) var mergingKeys: Set<String> = []

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
