import Foundation

/// A concern reduced to what's needed to place it in the diff.
nonisolated struct AIConcernRef: Sendable, Equatable {
    let id: UUID
    let path: String
    /// New-side line number parsed from the concern's line hint.
    let line: Int?
}

/// Where AI concerns go in the Changes view: on a diff line when the cited line is an
/// added or context line in the shown hunks, otherwise in a per-file "AI notes" group.
nonisolated struct AIConcernPlacement: Sendable, Equatable {
    var byLine: [DiffFile.ID: [DiffLine.ID: [UUID]]] = [:]
    var unplaced: [DiffFile.ID: [UUID]] = [:]

    func concerns(fileID: DiffFile.ID, lineID: DiffLine.ID) -> [UUID] {
        byLine[fileID]?[lineID] ?? []
    }

    func count(fileID: DiffFile.ID) -> Int {
        (byLine[fileID]?.values.reduce(0) { $0 + $1.count } ?? 0) + (unplaced[fileID]?.count ?? 0)
    }

    static func place(_ concerns: [AIConcernRef], in diff: MRDiff) -> AIConcernPlacement {
        var placement = AIConcernPlacement()
        for concern in concerns {
            guard let file = diff.files.first(where: { $0.path == concern.path }) else { continue }
            if let number = concern.line,
               let line = file.hunks.lazy.flatMap(\.lines).first(where: { $0.kind != .deletion && $0.kind != .noNewline && $0.newNumber == number }) {
                placement.byLine[file.id, default: [:]][line.id, default: []].append(concern.id)
            } else {
                placement.unplaced[file.id, default: []].append(concern.id)
            }
        }
        return placement
    }
}

/// The text posted to GitLab for an AI concern. Always attributed, so nobody mistakes
/// it for a human review.
nonisolated enum AICommentFormatter {
    static let attribution = "_Comment generated via MR Command Center_ 😃"

    static func body(severity: Severity, explanation: String) -> String {
        """
        \(attribution) · on-device AI review · severity: **\(severity.rawValue)**

        \(explanation.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    struct SummaryConcern: Sendable, Equatable {
        var path: String
        var lineHint: String
        var severity: Severity
        var explanation: String
    }

    /// A resolvable MR thread summarizing a review. Concerns are listed most severe first.
    static func summary(verdict: VerdictStatus?, rationale: String?, headSHA: String, promptName: String,
                        staticSummary: String, concerns: [SummaryConcern]) -> String {
        var lines = ["\(attribution) · on-device AI review of `\(headSHA.prefix(8))` (prompt \(promptName))", ""]
        if let verdict {
            lines.append("**Verdict: \(verdict.summaryTitle)**")
            lines.append("")
        }
        if let rationale, !rationale.isEmpty {
            lines.append(rationale.trimmingCharacters(in: .whitespacesAndNewlines))
            lines.append("")
        }
        if !concerns.isEmpty {
            lines.append("**Concerns**")
            for concern in concerns.sorted(by: { $0.severity > $1.severity }) {
                lines.append("- **\(concern.severity.rawValue)** `\(concern.path):\(concern.lineHint)`: \(concern.explanation.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            lines.append("")
        }
        lines.append("Static checks: \(staticSummary)")
        lines.append("")
        lines.append("_Automated review on the reviewer's Mac. Verify before acting; resolve this thread once addressed._")
        return lines.joined(separator: "\n")
    }

    /// Re-adds the attribution if an edit removed it.
    static func ensureAttribution(_ body: String) -> String {
        body.contains("Comment generated via MR Command Center") ? body : attribution + "\n\n" + body
    }
}

extension VerdictStatus {
    nonisolated var summaryTitle: String {
        switch self {
        case .looksGood: "Looks good"
        case .needsHumanReview: "Needs human review"
        case .likelyProblem: "Likely problem"
        }
    }
}
