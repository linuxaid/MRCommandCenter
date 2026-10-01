import Foundation
import SwiftData

/// Instructions for the per-file sessions and the merge (verdict) session, versioned
/// together. Runs reference the version they used. Versions are immutable once saved:
/// editing creates a new one (phase 6 adds the editor).
@Model
final class PromptVersion {
    @Attribute(.unique) var id: UUID
    var name: String
    var fileInstructions: String
    var mergeInstructions: String
    var notes: String
    var createdAt: Date

    init(name: String, fileInstructions: String, mergeInstructions: String, notes: String = "", createdAt: Date = .now) {
        id = UUID()
        self.name = name
        self.fileInstructions = fileInstructions
        self.mergeInstructions = mergeInstructions
        self.notes = notes
        self.createdAt = createdAt
    }

    var snapshot: PromptSnapshot {
        PromptSnapshot(id: id, name: name, fileInstructions: fileInstructions, mergeInstructions: mergeInstructions)
    }

    static let defaultFileInstructions = """
    You review one file from a GitLab merge request for logic problems.
    Focus on the changed lines: bugs, wrong conditions, missing error handling, unhandled edge cases, security problems, and whether the change does what the acceptance criteria ask.
    Ignore formatting, naming, and style.
    In the diff, "+" lines were added and "-" lines were removed; the number before a line is its new line number.
    Only raise concerns you can point to in the diff. If the change looks correct, return no concerns.
    Static analysis flags are hints, not proof.
    """

    static let defaultMergeInstructions = """
    You combine per-file review findings for one merge request into an overall verdict.
    Use looksGood when no file has a medium or high concern, likelyProblem when a high-severity concern looks real, and needsHumanReview otherwise or when files could not be reviewed.
    Judge criteria coverage only from the acceptance criteria provided; if none were provided, say so.
    Do not invent new concerns; only summarize the ones given.
    """
}

nonisolated struct PromptSnapshot: Codable, Sendable, Equatable {
    let id: UUID
    let name: String
    let fileInstructions: String
    let mergeInstructions: String
}
