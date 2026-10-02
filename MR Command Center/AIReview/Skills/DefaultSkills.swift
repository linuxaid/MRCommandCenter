import Foundation

/// Starter skills seeded on first launch. Every token here comes out of the ~8K context
/// the diff needs, and all skills for a file share `PromptBuilder.maxSkillTokens`.
nonisolated enum DefaultSkills {
    static let all: [(name: String, appliesTo: [String], content: String)] = [
        ("Python", ["*.py", "*.pyi"], """
        - Watch for mutable default arguments, bare except, and swallowed exceptions.
        - Check None handling on values that can be missing.
        - Flag blocking calls (time.sleep, sync HTTP) inside async code.
        - Check that new database queries are parameterized.
        """),
        ("TypeScript / JavaScript", ["*.ts", "*.tsx", "*.js", "*.jsx", "*.mjs"], """
        - Check for unhandled promise rejections and missing await.
        - Watch for floating-point math on money; prefer integer minor units.
        - Flag `any`, non-null assertions (!), and unchecked casts that hide bugs.
        - In React, check hook dependency arrays and keys in lists.
        """),
        ("Swift", ["*.swift"], """
        Flag only what a + line shows. Each point names the bug to report.
        Crashes
        - !, try!, as!, or [i] on values that can be missing (JSON, network, dictionary lookups, .first, user input, URL(string:)). Fine on literals, outlets, and values checked just above.
        - Integer division or modulo by a value that can be 0; array index from a count without a bounds check.
        Errors and optionals
        - try? or an empty catch that drops an error the caller needs; ?? with an empty string or 0 that hides a failure as valid data.
        - A completion handler not called on every path (early return, guard, catch).
        Memory
        - Escaping closure stored by self (property, sink, Timer, NotificationCenter, delegate) capturing self strongly: retain cycle. A plain Task {} or non-escaping closure is fine.
        - A delegate property that isn't weak.
        Concurrency
        - UI, @Published, or @Observable state changed off the main actor.
        - Blocking work on the main actor: Data(contentsOf:), sleep, semaphore.wait, DispatchQueue.main.sync.
        - @unchecked Sendable, nonisolated(unsafe), @preconcurrency, or Task.detached added to silence the compiler while state is still shared.
        - Actor or async state read before an await and trusted after it.
        - A stored Task never cancelled; long loops that never check Task.isCancelled.
        SwiftUI
        - @State or @StateObject initialized from an init parameter: later updates are ignored.
        - @ObservedObject var x = Model(): recreated on every redraw; use @StateObject or @State.
        - Side effects or slow work inside body.
        - ForEach with id: \\.self or indices over items that can change or repeat.
        - Work in .onAppear that should be .task so it's cancelled.
        Data
        - New non-optional Codable property: old JSON or saved data fails to decode. Renamed property without CodingKeys.
        - default: in a switch over our own enum hides new cases.
        - Hand-written == or hash(into:) missing a field.
        - Ranges (... vs ..<), String.Index math, and dates using 86400 seconds or a fixed time zone.
        Never flag style, naming, docs, access control, or force unwraps in test files.
        """),
        ("Go", ["*.go"], """
        - Check that every error is handled or returned with context.
        - Watch for goroutine leaks, missing context cancellation, and data races.
        - Flag defer inside loops and unclosed resources.
        """),
        ("Terraform", ["*.tf", "*.tfvars", "*.hcl"], """
        - Flag hard-coded credentials, open security groups (0.0.0.0/0), and public buckets.
        - Check provider and module version pins.
        - Note changes that force resource replacement.
        """),
        ("SQL migrations", ["*.sql", "migrations/*"], """
        - Check that migrations are reversible and safe on large tables (locks, defaults).
        - Flag missing indexes on new foreign keys and NOT NULL columns without defaults.
        """),
    ]

    /// Earlier built-in texts. A built-in skill still on one of these is upgraded to the
    /// current text on launch; a skill the user edited is left alone.
    static let previousContents: [String: [String]] = [
        "Swift": ["""
        - Watch for force unwraps, force tries, and retain cycles in closures.
        - Check actor isolation and Sendable issues in concurrent code.
        - Flag work on the main actor that could block the UI.
        """],
    ]

    /// Moves unedited built-in skills to the current text, bumping their versions.
    static func upgrade(_ skills: [ReviewSkill]) {
        for skill in skills where skill.isBuiltIn {
            guard previousContents[skill.name]?.contains(skill.content) == true,
                  let current = all.first(where: { $0.name == skill.name }) else { continue }
            skill.update(name: skill.name, appliesTo: skill.appliesTo, content: current.content)
        }
    }
}
