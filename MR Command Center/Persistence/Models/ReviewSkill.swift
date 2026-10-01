import Foundation
import SwiftData

/// Language- or area-specific review guidance added to the model's instructions for
/// files that match `appliesTo`. Editable in Settings; every save bumps `version`, and
/// each review run records the exact skill versions it used.
@Model
final class ReviewSkill {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Glob patterns, e.g. `*.py` or `src/**/*.ts`. A pattern without `/` matches the file name.
    var appliesTo: [String]
    var content: String
    var isEnabled: Bool
    var version: Int
    var isBuiltIn: Bool
    var createdAt: Date
    var updatedAt: Date

    init(name: String, appliesTo: [String], content: String, isEnabled: Bool = true, isBuiltIn: Bool = false, now: Date = .now) {
        id = UUID()
        self.name = name
        self.appliesTo = appliesTo
        self.content = content
        self.isEnabled = isEnabled
        version = 1
        self.isBuiltIn = isBuiltIn
        createdAt = now
        updatedAt = now
    }

    var snapshot: SkillSnapshot {
        SkillSnapshot(id: id, name: name, version: version, appliesTo: appliesTo, content: content)
    }

    /// Applies an edit, bumping the version only if something changed.
    func update(name: String, appliesTo: [String], content: String) {
        guard name != self.name || appliesTo != self.appliesTo || content != self.content else { return }
        self.name = name
        self.appliesTo = appliesTo
        self.content = content
        version += 1
        updatedAt = .now
    }
}

/// An immutable copy of a skill as used in a review.
nonisolated struct SkillSnapshot: Codable, Sendable, Equatable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let version: Int
    let appliesTo: [String]
    let content: String

    var label: String { "\(name) v\(version)" }
}
