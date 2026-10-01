import Foundation

/// Starter skills seeded on first launch. Short on purpose: every token here comes out of
/// the ~8K context the diff needs.
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
        - Watch for force unwraps, force tries, and retain cycles in closures.
        - Check actor isolation and Sendable issues in concurrent code.
        - Flag work on the main actor that could block the UI.
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
}
