import Foundation

/// Where an MR sits from your point of view. Every open MR is in exactly one lane.
enum Lane: String, CaseIterable, Identifiable {
    case yourMove, readyToMerge, autoMerge, inFlight, drafts, setAside

    var id: Self { self }

    var title: String {
        switch self {
        case .yourMove: "Your move"
        case .readyToMerge: "Ready to merge"
        case .autoMerge: "Merging on its own"
        case .inFlight: "In flight"
        case .drafts: "Drafts"
        case .setAside: "Set aside"
        }
    }

    var subtitle: String {
        switch self {
        case .yourMove: "Waiting on a decision or a reply from you"
        case .readyToMerge: "All green and waiting for someone to merge"
        case .autoMerge: "A merge rule or GitLab will merge these when they're ready"
        case .inFlight: "Moving along without you"
        case .drafts: "Not ready for review yet"
        case .setAside: "Your move, parked until something new happens"
        }
    }

    var systemImage: String {
        switch self {
        case .yourMove: "hand.point.right.fill"
        case .readyToMerge: "checkmark.circle.fill"
        case .autoMerge: "wand.and.stars"
        case .inFlight: "airplane"
        case .drafts: "pencil.line"
        case .setAside: "tray.and.arrow.down"
        }
    }
}

/// Who has to act next.
enum Party: Equatable {
    case you
    case author(String)
    case reviewers
    case pipeline
    case rule(String)
    case gitLab
    case nobody

    var title: String {
        switch self {
        case .you: "You"
        case .author(let name): name
        case .reviewers: "Other reviewers"
        case .pipeline: "The pipeline"
        case .rule(let name): "Rule “\(name)”"
        case .gitLab: "GitLab auto-merge"
        case .nobody: "Whoever merges it"
        }
    }
}

/// A merge rule's view of one MR.
struct RuleStatus: Equatable {
    let ruleID: UUID
    let ruleName: String
    /// Requirements the MR doesn't meet yet. Empty means the rule would merge it now.
    let unmet: [String]
    /// False when automatic merging is switched off, so the rule only reports.
    let isLive: Bool

    var isReady: Bool { unmet.isEmpty }
}

/// The answer to "what's happening with this MR, and do I need to do anything?"
struct MRSituation: Equatable {
    let lane: Lane
    /// One plain sentence, e.g. "Priya replied to your thread".
    let headline: String
    let ballWith: Party
    /// Other things worth knowing, beyond the headline.
    let notes: [String]
    let readiness: Readiness
    let rule: RuleStatus?

    /// Like `ignoringSetAside`, except a Your move MR you set aside sits in its own lane until
    /// something new happens on it.
    static func make(for mr: TrackedMR, me: String?, rule: RuleStatus?) -> MRSituation {
        let natural = ignoringSetAside(for: mr, me: me, rule: rule)
        guard natural.lane == .yourMove, isStillSetAside(mr, reason: natural.headline) else { return natural }
        return MRSituation(lane: .setAside, headline: "Set aside: \(natural.headline)", ballWith: .you,
                           notes: natural.notes + ["It comes back to Your move when something new happens"],
                           readiness: natural.readiness, rule: natural.rule)
    }

    /// A set-aside MR stays parked while nothing has changed since: the same commit, the same
    /// reason it needed you, and no reply to you newer than when you set it aside.
    static func isStillSetAside(_ mr: TrackedMR, reason: String) -> Bool {
        guard let setAsideAt = mr.setAsideAt else { return false }
        let noNewReply = mr.lastReplyToMeAt.map { $0 <= setAsideAt } ?? true
        return mr.setAsideSHA == mr.headSHA && mr.setAsideReason == reason && noNewReply
    }

    /// Where the MR would be if you hadn't set it aside.
    static func ignoringSetAside(for mr: TrackedMR, me: String?, rule: RuleStatus?) -> MRSituation {
        let readiness = Readiness(mr)
        let author = firstName(mr.authorName)
        let pipeline = readiness.step(.pipeline)
        let mergeable = readiness.step(.mergeable)
        let iApproved = me.map { mr.approvedByUsernames.contains($0) } ?? false
        var notes: [String] = []

        func situation(_ lane: Lane, _ headline: String, _ party: Party) -> MRSituation {
            MRSituation(lane: lane, headline: headline, ballWith: party, notes: notes, readiness: readiness, rule: rule)
        }

        if mr.threadsAwaitingOthers > 0 {
            let count = mr.threadsAwaitingOthers
            notes.append(count == 1 ? "1 of your threads is waiting on a reply" : "\(count) of your threads are waiting on replies")
        }
        if mr.isReviewer && !mr.isAuthor && !iApproved && !mr.approvalsMet && mr.hasLoadedDetails {
            notes.append("You haven't approved yet")
        }
        if let error = mr.autoMergeError {
            notes.append("Last automatic merge failed: \(error)")
        }

        if mr.isDraft {
            return situation(.drafts, mr.isAuthor ? "Your draft" : "\(author) is still working on it", mr.isAuthor ? .you : .author(author))
        }

        // Your move.
        if mr.threadsAwaitingMe > 0 {
            let who = mr.lastReplyFrom.map(firstName) ?? "Someone"
            let headline = mr.threadsAwaitingMe == 1
                ? (mr.isAuthor ? "\(who) left a comment for you" : "\(who) replied to your thread")
                : "\(mr.threadsAwaitingMe) threads are waiting on your reply"
            return situation(.yourMove, headline, .you)
        }
        if mr.isAuthor {
            if pipeline.state == .blocked {
                return situation(.yourMove, "Your pipeline \(pipeline.summary.lowercased())", .you)
            }
            if mergeable.state == .blocked {
                return situation(.yourMove, mergeable.summary, .you)
            }
        } else if mr.isReviewer, !iApproved, mr.hasLoadedDetails, !mr.approvalsMet,
                  pipeline.state != .blocked, mergeable.state != .blocked, mr.threadsAwaitingOthers == 0 {
            return situation(.yourMove, "Waiting on your approval", .you)
        }

        // Ready, or about to be merged without anyone.
        if readiness.isReady {
            if let rule {
                if rule.isReady {
                    let headline = rule.isLive ? "Merging on the next check" : "Rule would merge this now (dry run)"
                    return situation(.autoMerge, headline, .rule(rule.ruleName))
                }
                notes.append(contentsOf: rule.unmet.map { "Rule “\(rule.ruleName)” waits until \($0)" })
            }
            return situation(.readyToMerge, mr.isAuthor ? "Ready for you to merge" : "Ready to merge", mr.isAuthor ? .you : .nobody)
        }
        if mr.mergeWhenPipelineSucceeds {
            return situation(.autoMerge, "GitLab will merge it when the pipeline passes", .gitLab)
        }
        if let rule, readiness.step(.pipeline).state != .blocked, mergeable.state != .blocked {
            let waitingOn = rule.unmet.first.map { "Will merge once \($0)" } ?? "Will merge on the next check"
            return situation(.autoMerge, waitingOn, .rule(rule.ruleName))
        }

        // In flight: name the first thing it's waiting on, and who has to act.
        if pipeline.state == .blocked {
            return situation(.inFlight, "Waiting on \(mr.isAuthor ? "a pipeline fix" : "\(author) to fix the \(pipeline.summary.lowercased()) pipeline")",
                             mr.isAuthor ? .you : .author(author))
        }
        if mergeable.state == .blocked {
            return situation(.inFlight, "\(mergeable.summary). Waiting on \(author).", .author(author))
        }
        if mr.threadsAwaitingOthers > 0 {
            return situation(.inFlight, "Waiting on \(author) to answer your thread", .author(author))
        }
        if pipeline.state == .waiting || pipeline.state == .unknown {
            return situation(.inFlight, "Pipeline \(pipeline.summary.lowercased())", .pipeline)
        }
        if readiness.step(.approvals).state != .done {
            let left = max(0, mr.approvalsRequired - mr.approvalsGiven)
            let more = left == 1 ? "1 more approval" : "\(left) more approvals"
            return situation(.inFlight, iApproved ? "You approved. Waiting on \(more)." : "Waiting on \(more)", .reviewers)
        }
        if readiness.step(.threads).state != .done {
            let open = mr.unresolvedDiscussions
            return situation(.inFlight, open == 1 ? "1 open thread to resolve" : "\(open) open threads to resolve", .author(author))
        }
        if let status = readiness.gitLabStatus, Readiness.blockingGitLabStatuses.contains(status) {
            return situation(.inFlight, "GitLab says: \(status.replacingOccurrences(of: "_", with: " "))", .author(author))
        }
        return situation(.inFlight, "In progress", .author(author))
    }

    static func firstName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}

extension String {
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }

    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
