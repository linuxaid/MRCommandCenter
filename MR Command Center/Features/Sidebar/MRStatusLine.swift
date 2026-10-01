import Foundation

/// One status indicator in the sidebar row. Always has text and an icon, never color alone.
struct StatusItem: Identifiable, Equatable {
    enum Tone: Equatable {
        case positive, negative, warning, pending, neutral
    }

    let id: String
    let title: String
    let systemImage: String
    let tone: Tone
    let accessibilityLabel: String
}

/// Builds the compact status line for an MR. Pure so it can be unit tested.
enum MRStatusLine {
    static func items(for mr: TrackedMR) -> [StatusItem] {
        var items = [checksItem(for: mr), pipelineItem(for: mr)]
        if let approvals = approvalsItem(for: mr) { items.append(approvals) }
        if mr.hasConflicts {
            items.append(StatusItem(id: "conflicts", title: "Conflicts", systemImage: "exclamationmark.triangle.fill",
                                    tone: .negative, accessibilityLabel: "Has merge conflicts"))
        }
        if mr.isDraft {
            items.append(StatusItem(id: "draft", title: "Draft", systemImage: "pencil.line",
                                    tone: .neutral, accessibilityLabel: "Draft"))
        }
        if mr.unresolvedDiscussions > 0 {
            let count = mr.unresolvedDiscussions
            items.append(StatusItem(id: "threads", title: "\(count) open", systemImage: "bubble.left.and.exclamationmark.bubble.right",
                                    tone: .warning, accessibilityLabel: "\(count) unresolved \(count == 1 ? "thread" : "threads")"))
        }
        items.append(jiraItem(for: mr))
        // A reviewed MR shows its AI verdict as a badge above the title instead.
        if mr.aiVerdictRaw == nil {
            items.append(aiItem(for: mr))
        }
        return items
    }

    /// Summary of all static checks: metadata checks live, diff checks from the cached summary.
    static func checksItem(for mr: TrackedMR) -> StatusItem {
        let metadata = StaticChecks.metadataChecks(MRCheckInput(mr))
        let diffKnown = mr.diffCheckSHA == mr.headSHA && !mr.headSHA.isEmpty
        let failures = metadata.count { $0.outcome == .fail } + (diffKnown ? mr.diffCheckFailures : 0)
        let warnings = metadata.count { $0.outcome == .warning } + (diffKnown ? mr.diffCheckWarnings : 0)
        if failures > 0 {
            return StatusItem(id: "checks", title: "\(failures) failing", systemImage: "xmark.shield.fill", tone: .negative,
                              accessibilityLabel: "Static checks: \(failures) failing, \(warnings) warnings")
        }
        if !diffKnown {
            return StatusItem(id: "checks", title: "Checking", systemImage: "shield", tone: .pending,
                              accessibilityLabel: "Static checks: still running")
        }
        if warnings > 0 {
            return StatusItem(id: "checks", title: "\(warnings) \(warnings == 1 ? "warning" : "warnings")", systemImage: "exclamationmark.shield.fill",
                              tone: .warning, accessibilityLabel: "Static checks: \(warnings) warnings")
        }
        return StatusItem(id: "checks", title: "Checks pass", systemImage: "checkmark.shield.fill", tone: .positive,
                          accessibilityLabel: "Static checks: all passing")
    }

    static func aiItem(for mr: TrackedMR) -> StatusItem {
        guard let raw = mr.aiVerdictRaw, let verdict = VerdictStatus(rawValue: raw) else {
            return StatusItem(id: "ai", title: "Not reviewed", systemImage: "sparkles", tone: .neutral, accessibilityLabel: "AI review: not run")
        }
        let outdated = mr.aiReviewedSHA != mr.headSHA
        let (title, image, tone): (String, String, StatusItem.Tone) = switch verdict {
        case .looksGood: ("AI: looks good", "sparkles", .positive)
        case .needsHumanReview: ("AI: needs review", "sparkles", .warning)
        case .likelyProblem: ("AI: likely problem", "sparkles", .negative)
        }
        let open = mr.aiOpenConcerns
        let openText = open > 0 && !outdated ? " · \(open) open" : ""
        return StatusItem(id: "ai", title: (outdated ? title + " (outdated)" : title) + openText, systemImage: image,
                          tone: outdated ? .neutral : tone,
                          accessibilityLabel: "AI review: \(verdict.title.lowercased())\(outdated ? ", for an older commit" : "")"
                            + (open > 0 && !outdated ? ", \(open) open AI \(open == 1 ? "comment" : "comments")" : ""))
    }

    static func pipelineItem(for mr: TrackedMR) -> StatusItem {
        guard mr.hasLoadedDetails || mr.pipelineStatusRaw != nil else {
            return StatusItem(id: "pipeline", title: "Loading", systemImage: "ellipsis.circle",
                              tone: .neutral, accessibilityLabel: "Pipeline status loading")
        }
        let (title, image, tone): (String, String, StatusItem.Tone) = switch mr.pipelineStatus {
        case nil: ("No pipeline", "minus.circle", .neutral)
        case .success: ("Passed", "checkmark.circle.fill", .positive)
        case .failed: ("Failed", "xmark.circle.fill", .negative)
        case .running: ("Running", "arrow.triangle.2.circlepath.circle", .pending)
        case .created, .waitingForResource, .preparing, .pending, .scheduled: ("Pending", "clock", .pending)
        case .canceled: ("Canceled", "slash.circle", .neutral)
        case .skipped: ("Skipped", "forward.circle", .neutral)
        case .manual: ("Manual", "hand.raised.circle", .warning)
        case .unknown: ("Unknown", "questionmark.circle", .neutral)
        }
        return StatusItem(id: "pipeline", title: title, systemImage: image, tone: tone,
                          accessibilityLabel: "Pipeline: \(title.lowercased())")
    }

    static func approvalsItem(for mr: TrackedMR) -> StatusItem? {
        guard mr.hasLoadedDetails else { return nil }
        let given = mr.approvalsGiven
        let required = mr.approvalsRequired
        if required == 0 {
            return StatusItem(id: "approvals", title: "\(given) approved", systemImage: "person.2",
                              tone: .neutral, accessibilityLabel: "\(given) approvals, none required")
        }
        let met = given >= required
        return StatusItem(id: "approvals", title: "\(given)/\(required) approved",
                          systemImage: met ? "checkmark.seal.fill" : "person.2",
                          tone: met ? .positive : .warning,
                          accessibilityLabel: "\(given) of \(required) required approvals\(met ? ", met" : "")")
    }

    static func jiraItem(for mr: TrackedMR) -> StatusItem {
        guard let key = mr.jiraKey else {
            return StatusItem(id: "jira", title: "No Jira key", systemImage: "ticket",
                              tone: .warning, accessibilityLabel: "No Jira key in branch name")
        }
        switch mr.jiraLookup {
        case .found:
            let status = mr.jiraStatus ?? "unknown"
            let passing = mr.jiraPassing == true
            return StatusItem(id: "jira", title: "\(key) · \(status)", systemImage: "ticket",
                              tone: passing ? .positive : .warning,
                              accessibilityLabel: "Jira issue \(key), \(status)\(passing ? "" : ", not a passing status")")
        case .notFound:
            return StatusItem(id: "jira", title: "\(key) · not found", systemImage: "ticket",
                              tone: .negative, accessibilityLabel: "Jira issue \(key) not found")
        case .failed:
            return StatusItem(id: "jira", title: "\(key) · check failed", systemImage: "ticket",
                              tone: .warning, accessibilityLabel: "Jira issue \(key), couldn't check status")
        case .notConfigured, nil:
            return StatusItem(id: "jira", title: key, systemImage: "ticket",
                              tone: .neutral, accessibilityLabel: "Jira issue \(key), status not checked")
        }
    }
}
