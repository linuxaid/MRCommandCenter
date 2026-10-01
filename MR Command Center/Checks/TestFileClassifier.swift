import Foundation

/// Decides whether a changed file is source code, a test, or neither (docs, config, lock files…).
nonisolated enum TestFileClassifier {
    enum Kind: Equatable {
        case source, test, other
    }

    static let sourceExtensions: Set<String> = [
        "swift", "m", "mm", "py", "ts", "tsx", "js", "jsx", "mjs", "cjs", "go", "rb", "java", "kt", "kts",
        "rs", "cs", "cpp", "cc", "c", "h", "hpp", "php", "scala", "ex", "exs", "dart", "vue", "svelte",
    ]

    static let testDirectories: Set<String> = ["test", "tests", "spec", "specs", "__tests__", "testing", "e2e", "integration_tests"]

    static func classify(_ path: String, extraTestPatterns: [String] = []) -> Kind {
        let lower = path.lowercased()
        let originalName = (path as NSString).lastPathComponent
        let name = originalName.lowercased()
        let ext = (name as NSString).pathExtension
        let directories = path.split(separator: "/").dropLast().map(String.init)

        if extraTestPatterns.contains(where: { !$0.isEmpty && lower.contains($0.lowercased()) }) { return .test }
        // `tests/`, `__tests__/`, or Xcode-style "MyApp Tests/" / "MyAppTests/" (case-sensitive
        // so "contests/" doesn't count).
        if directories.contains(where: { testDirectories.contains($0.lowercased()) || $0.hasSuffix("Tests") || $0.hasSuffix(" tests") }) {
            return .test
        }

        guard sourceExtensions.contains(ext) else { return .other }
        let stem = (name as NSString).deletingPathExtension
        let originalStem = (originalName as NSString).deletingPathExtension
        let isTestName = stem.hasPrefix("test_") || stem.hasSuffix("_test") || stem.hasSuffix("_spec")
            || stem.hasSuffix(".test") || stem.hasSuffix(".spec")
            // CamelCase only, so "Contest" and "latest" stay source.
            || originalStem.hasSuffix("Test") || originalStem.hasSuffix("Tests")
        return isTestName ? .test : .source
    }
}
