import Foundation

/// What a piece of code is, for coloring. Mirrors the categories of Xcode's default theme.
nonisolated enum SyntaxKind: Sendable, Equatable {
    case keyword, string, comment, number, type, attribute, directive
}

/// A colored run in a line, as character offsets into the line's display text.
nonisolated struct SyntaxToken: Sendable, Equatable {
    let range: Range<Int>
    let kind: SyntaxKind
}

/// The rules for one language: enough to color keywords, strings, comments, numbers and types.
/// A lightweight lexer, not a parser; it only has to look right line by line in a diff.
nonisolated struct CodeLanguage: Sendable, Equatable {
    let name: String
    let keywords: Set<String>
    var caseInsensitiveKeywords = false
    var lineComments: [String] = []
    var blockComment: Pair?
    var quotes: [Character] = ["\""]
    /// Strings that can span lines: `"""` (Swift, Python, Kotlin), `'''` (Python),
    /// and backticks (JS/TS template literals, Go raw strings).
    var multilineQuotes: [String] = []
    /// `@` for Swift attributes, Java annotations, Python decorators.
    var attributePrefix: Character?
    /// `#` for Swift (`#if`) and C (`#include`) directives.
    var directivePrefix: Character?
    /// Capitalized identifiers are type names (Swift, Java, TypeScript...).
    var capitalizedTypes = true
    /// A line comment only starts at the beginning or after whitespace (shell's `$#` isn't one).
    var commentNeedsSpaceBefore = false
    /// Characters that may end an identifier (Ruby's `defined?`, `save!`).
    var identifierSuffixes: Set<Character> = []
    /// `#1C00CF` is one color value (CSS), not a directive or a stray number.
    var hashHexColors = false

    nonisolated struct Pair: Sendable, Equatable {
        let open: String
        let close: String
    }

    /// The language for a file path, by extension (or name, for Dockerfile and Makefile).
    static func forPath(_ path: String) -> CodeLanguage? {
        let name = (path as NSString).lastPathComponent
        if name == "Dockerfile" || name.hasPrefix("Dockerfile.") { return .shell }
        if name == "Makefile" || name == "Podfile" || name == "Fastfile" { return name == "Makefile" ? .shell : .ruby }
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp", "hh": return .c
        case "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts": return .javaScript
        case "java", "kt", "kts", "scala", "groovy", "gradle", "dart": return .java
        case "cs": return .cSharp
        case "go": return .go
        case "rs": return .rust
        case "py", "pyi": return .python
        case "rb", "rake", "gemspec": return .ruby
        case "sh", "bash", "zsh", "fish", "env": return .shell
        case "yml", "yaml": return .yaml
        case "json", "jsonc": return .json
        case "tf", "tfvars", "hcl": return .hcl
        case "sql": return .sql
        case "css": return .css
        case "scss", "sass", "less": return .scss
        case "html", "htm", "xml", "plist", "svg", "xib", "storyboard", "vue": return .markup
        case "php": return .php
        default: return nil
        }
    }
}

nonisolated extension CodeLanguage {
    private static let cFamilyBlock = Pair(open: "/*", close: "*/")

    static let swift = CodeLanguage(
        name: "Swift",
        keywords: ["actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue",
                   "convenience", "default", "defer", "deinit", "didSet", "do", "dynamic", "else", "enum", "extension",
                   "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in",
                   "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let", "mutating", "nil",
                   "nonisolated", "nonmutating", "open", "operator", "optional", "override", "package", "private",
                   "protocol", "public", "repeat", "required", "rethrows", "return", "self", "Self", "set", "some",
                   "static", "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
                   "unowned", "var", "weak", "where", "while", "willSet", "consuming", "borrowing", "sending"],
        lineComments: ["//"], blockComment: cFamilyBlock, multilineQuotes: ["\"\"\""], attributePrefix: "@", directivePrefix: "#"
    )

    static let c = CodeLanguage(
        name: "C",
        keywords: ["auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern",
                   "float", "for", "goto", "if", "inline", "int", "long", "register", "return", "short", "signed", "sizeof",
                   "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "true",
                   "false", "NULL", "nullptr", "class", "namespace", "template", "typename", "public", "private", "protected",
                   "virtual", "override", "new", "delete", "this", "using", "nil", "YES", "NO", "self", "super", "id",
                   "@interface", "@implementation", "@end", "@property", "@synthesize", "@protocol", "instancetype"],
        lineComments: ["//"], blockComment: cFamilyBlock, quotes: ["\"", "'"], attributePrefix: "@", directivePrefix: "#"
    )

    static let javaScript = CodeLanguage(
        name: "JavaScript",
        keywords: ["abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue",
                   "debugger", "declare", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally",
                   "for", "from", "function", "get", "if", "implements", "import", "in", "instanceof", "interface", "is",
                   "keyof", "let", "namespace", "new", "null", "of", "private", "protected", "public", "readonly",
                   "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "true", "try", "type",
                   "typeof", "undefined", "var", "void", "while", "with", "yield"],
        lineComments: ["//"], blockComment: cFamilyBlock, quotes: ["\"", "'"], multilineQuotes: ["`"], attributePrefix: "@"
    )

    static let java = CodeLanguage(
        name: "Java",
        keywords: ["abstract", "assert", "boolean", "break", "byte", "case", "catch", "char", "class", "const", "continue",
                   "data", "default", "do", "double", "else", "enum", "extends", "final", "finally", "float", "for", "fun",
                   "if", "implements", "import", "in", "instanceof", "int", "interface", "internal", "is", "long",
                   "native", "new", "null", "object", "open", "override", "package", "private", "protected", "public",
                   "return", "sealed", "short", "static", "super", "suspend", "switch", "synchronized", "this", "throw",
                   "throws", "true", "false", "try", "val", "var", "void", "volatile", "when", "while",
                   "required", "async", "await", "companion", "lateinit", "typealias"],
        lineComments: ["//"], blockComment: cFamilyBlock, quotes: ["\"", "'"], multilineQuotes: ["\"\"\""], attributePrefix: "@"
    )

    static let cSharp = CodeLanguage(
        name: "C#",
        keywords: ["abstract", "as", "async", "await", "base", "bool", "break", "case", "catch", "class", "const", "continue",
                   "decimal", "default", "delegate", "do", "double", "else", "enum", "event", "false", "finally", "float",
                   "for", "foreach", "get", "if", "in", "int", "interface", "internal", "is", "lock", "long", "namespace",
                   "new", "null", "object", "out", "override", "private", "protected", "public", "readonly", "record",
                   "ref", "return", "sealed", "set", "static", "string", "struct", "switch", "this", "throw", "true", "try",
                   "typeof", "using", "var", "virtual", "void", "while", "yield"],
        lineComments: ["//"], blockComment: cFamilyBlock, quotes: ["\"", "'"], directivePrefix: "#"
    )

    static let go = CodeLanguage(
        name: "Go",
        keywords: ["break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "false", "for",
                   "func", "go", "goto", "if", "import", "interface", "map", "nil", "package", "range", "return", "select",
                   "struct", "switch", "true", "type", "var", "string", "int", "int64", "bool", "error", "byte", "float64"],
        lineComments: ["//"], blockComment: cFamilyBlock, quotes: ["\"", "'"], multilineQuotes: ["`"]
    )

    static let rust = CodeLanguage(
        name: "Rust",
        keywords: ["as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "false",
                   "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
                   "self", "Self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use", "where", "while"],
        lineComments: ["//"], blockComment: cFamilyBlock, quotes: ["\""], directivePrefix: "#"
    )

    static let python = CodeLanguage(
        name: "Python",
        keywords: ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                   "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is",
                   "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "self", "try", "while", "with", "yield",
                   "match", "case"],
        lineComments: ["#"], quotes: ["\"", "'"], multilineQuotes: ["\"\"\"", "'''"], attributePrefix: "@"
    )

    static let ruby = CodeLanguage(
        name: "Ruby",
        keywords: ["alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else", "elsif", "end",
                   "ensure", "false", "for", "if", "in", "module", "next", "nil", "not", "or", "redo", "require", "rescue",
                   "retry", "return", "self", "super", "then", "true", "undef", "unless", "until", "when", "while", "yield"],
        lineComments: ["#"], quotes: ["\"", "'"], attributePrefix: "@", identifierSuffixes: ["?", "!"]
    )

    static let shell = CodeLanguage(
        name: "Shell",
        keywords: ["if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in",
                   "function", "return", "local", "export", "readonly", "set", "unset", "echo", "exit", "source",
                   "FROM", "RUN", "COPY", "ADD", "CMD", "ENTRYPOINT", "ENV", "ARG", "WORKDIR", "EXPOSE", "USER", "LABEL"],
        lineComments: ["#"], quotes: ["\"", "'"], capitalizedTypes: false, commentNeedsSpaceBefore: true
    )

    static let yaml = CodeLanguage(
        name: "YAML", keywords: ["true", "false", "null"],
        lineComments: ["#"], quotes: ["\"", "'"], capitalizedTypes: false, commentNeedsSpaceBefore: true
    )

    static let json = CodeLanguage(name: "JSON", keywords: ["true", "false", "null"], quotes: ["\""], capitalizedTypes: false)

    static let hcl = CodeLanguage(
        name: "HCL",
        keywords: ["resource", "data", "variable", "output", "module", "provider", "terraform", "locals", "true", "false",
                   "null", "for", "in", "if", "required_providers", "required_version", "source", "version"],
        lineComments: ["#", "//"], blockComment: cFamilyBlock, quotes: ["\""], capitalizedTypes: false
    )

    static let sql = CodeLanguage(
        name: "SQL",
        keywords: ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete",
                   "create", "table", "alter", "drop", "index", "on", "join", "left", "right", "inner", "outer", "group",
                   "by", "order", "having", "limit", "offset", "as", "distinct", "null", "is", "in", "exists", "primary",
                   "key", "foreign", "references", "default", "unique", "constraint", "begin", "commit", "rollback",
                   "case", "when", "then", "else", "end", "union", "all", "varchar", "integer", "int", "text", "boolean",
                   "timestamp", "true", "false", "like", "between", "with", "returning", "add", "column"],
        caseInsensitiveKeywords: true, lineComments: ["--"], blockComment: cFamilyBlock, quotes: ["'", "\""], capitalizedTypes: false
    )

    /// Plain CSS has only block comments: `//` would eat `url(http://…)`.
    static let css = CodeLanguage(
        name: "CSS", keywords: ["important", "inherit", "initial", "none", "auto"],
        blockComment: cFamilyBlock, quotes: ["\"", "'"], attributePrefix: "@", capitalizedTypes: false, hashHexColors: true
    )

    static let scss = CodeLanguage(
        name: "SCSS", keywords: ["important", "inherit", "initial", "none", "auto"],
        lineComments: ["//"], blockComment: cFamilyBlock, quotes: ["\"", "'"], attributePrefix: "@", capitalizedTypes: false,
        hashHexColors: true
    )

    static let markup = CodeLanguage(
        name: "Markup", keywords: [], blockComment: Pair(open: "<!--", close: "-->"), quotes: ["\""], capitalizedTypes: false
    )

    static let php = CodeLanguage(
        name: "PHP",
        keywords: ["abstract", "array", "as", "break", "case", "catch", "class", "const", "continue", "default", "do", "echo",
                   "else", "elseif", "extends", "false", "final", "finally", "fn", "for", "foreach", "function", "if",
                   "implements", "interface", "namespace", "new", "null", "private", "protected", "public", "return",
                   "static", "switch", "this", "throw", "trait", "true", "try", "use", "while"],
        lineComments: ["//", "#"], blockComment: cFamilyBlock, quotes: ["\"", "'"]
    )
}

/// Colors the lines of a diff. Pure: produces tokens; the view turns them into colors.
nonisolated enum SyntaxHighlighter {
    /// What carries from one line to the next: an open block comment or multi-line string.
    struct State: Equatable, Sendable {
        var inBlockComment = false
        var openMultilineQuote: String?
    }

    /// Tokens per line, kept per side: a context line can read differently on the old side
    /// (inside a comment the change removed) than on the new side.
    struct Highlighted: Sendable, Equatable {
        var old: [DiffLine.ID: [SyntaxToken]] = [:]
        var new: [DiffLine.ID: [SyntaxToken]] = [:]

        /// For the unified view: removed lines as they were, everything else as it is now.
        func unified(_ line: DiffLine) -> [SyntaxToken]? {
            line.kind == .deletion ? old[line.id] : new[line.id]
        }
    }

    /// Tokens for a file's diff, or none when its language isn't recognized.
    static func highlight(for file: DiffFile) -> Highlighted {
        guard let language = CodeLanguage.forPath(file.path) else { return Highlighted() }
        return highlight(file.hunks, language: language)
    }

    /// The same, worked out off the main actor so large files don't stall scrolling.
    @concurrent
    static func highlightOffMain(_ file: DiffFile) async -> Highlighted {
        highlight(for: file)
    }

    /// Lexes the old side (context and removed lines) and the new side (context and added
    /// lines) separately, so a comment opened on one side doesn't color the other.
    static func highlight(_ hunks: [DiffHunk], language: CodeLanguage) -> Highlighted {
        let lexer = Lexer(language)
        var result = Highlighted()
        for hunk in hunks {
            // Each hunk starts fresh: lines between hunks aren't in the diff.
            var old = State()
            var new = State()
            for line in hunk.lines {
                let text = displayText(line.text)
                switch line.kind {
                case .addition:
                    result.new[line.id] = lexer.tokens(in: text, state: &new)
                case .deletion:
                    result.old[line.id] = lexer.tokens(in: text, state: &old)
                case .context:
                    result.new[line.id] = lexer.tokens(in: text, state: &new)
                    result.old[line.id] = lexer.tokens(in: text, state: &old)
                case .noNewline:
                    continue
                }
            }
        }
        return result
    }

    /// The text as the diff shows it: tabs as four spaces (token offsets refer to this).
    static func displayText(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: "    ")
    }

    static func tokens(in text: String, language: CodeLanguage, state: inout State) -> [SyntaxToken] {
        Lexer(language).tokens(in: text, state: &state)
    }

    /// The lexer for one language, with its patterns turned into character arrays once.
    struct Lexer {
        let language: CodeLanguage
        private let lineComments: [[Character]]
        private let blockOpen: [Character]?
        private let blockClose: [Character]?
        private let multiline: [(name: String, chars: [Character])]

        init(_ language: CodeLanguage) {
            self.language = language
            lineComments = language.lineComments.map { Array($0) }
            blockOpen = language.blockComment.map { Array($0.open) }
            blockClose = language.blockComment.map { Array($0.close) }
            multiline = language.multilineQuotes.map { (name: $0, chars: Array($0)) }
        }

        func tokens(in text: String, state: inout State) -> [SyntaxToken] {
            let chars = Array(text)
            var tokens: [SyntaxToken] = []
            var i = 0

            func matches(_ pattern: [Character], at index: Int) -> Bool {
                guard !pattern.isEmpty, index + pattern.count <= chars.count else { return false }
                for offset in pattern.indices where chars[index + offset] != pattern[offset] { return false }
                return true
            }

            func find(_ pattern: [Character], from index: Int) -> Int? {
                var j = index
                while j + pattern.count <= chars.count {
                    if matches(pattern, at: j) { return j }
                    j += 1
                }
                return nil
            }

            // Carry-over from the previous line.
            if state.inBlockComment, let close = blockClose {
                guard let found = find(close, from: 0) else {
                    return chars.isEmpty ? [] : [SyntaxToken(range: 0..<chars.count, kind: .comment)]
                }
                let end = found + close.count
                tokens.append(SyntaxToken(range: 0..<end, kind: .comment))
                state.inBlockComment = false
                i = end
            } else if let open = state.openMultilineQuote {
                let quote = Array(open)
                guard let found = find(quote, from: 0) else {
                    return chars.isEmpty ? [] : [SyntaxToken(range: 0..<chars.count, kind: .string)]
                }
                let end = found + quote.count
                tokens.append(SyntaxToken(range: 0..<end, kind: .string))
                state.openMultilineQuote = nil
                i = end
            }

            func isIdentifierStart(_ c: Character) -> Bool { c.isLetter || c == "_" || c == "$" }
            func isIdentifier(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "$" }

            lexing: while i < chars.count {
                let c = chars[i]
                if c.isWhitespace { i += 1; continue }

                let commentAllowedHere = !language.commentNeedsSpaceBefore || i == 0 || chars[i - 1].isWhitespace
                if commentAllowedHere, lineComments.contains(where: { matches($0, at: i) }) {
                    tokens.append(SyntaxToken(range: i..<chars.count, kind: .comment))
                    break lexing
                }

                if let open = blockOpen, let close = blockClose, matches(open, at: i) {
                    if let found = find(close, from: i + open.count) {
                        let end = found + close.count
                        tokens.append(SyntaxToken(range: i..<end, kind: .comment))
                        i = end
                    } else {
                        tokens.append(SyntaxToken(range: i..<chars.count, kind: .comment))
                        state.inBlockComment = true
                        break lexing
                    }
                    continue
                }

                if let quote = multiline.first(where: { matches($0.chars, at: i) }) {
                    if let found = find(quote.chars, from: i + quote.chars.count) {
                        let end = found + quote.chars.count
                        tokens.append(SyntaxToken(range: i..<end, kind: .string))
                        i = end
                    } else {
                        tokens.append(SyntaxToken(range: i..<chars.count, kind: .string))
                        state.openMultilineQuote = quote.name
                        break lexing
                    }
                    continue
                }

                if language.hashHexColors, c == "#", i + 1 < chars.count, chars[i + 1].isHexDigit {
                    var j = i + 1
                    while j < chars.count, chars[j].isHexDigit { j += 1 }
                    tokens.append(SyntaxToken(range: i..<j, kind: .number))
                    i = j
                    continue
                }

                if language.quotes.contains(c) {
                    var j = i + 1
                    while j < chars.count, chars[j] != c {
                        j += chars[j] == "\\" ? 2 : 1
                    }
                    let end = min(j + 1, chars.count)
                    tokens.append(SyntaxToken(range: i..<end, kind: .string))
                    i = end
                    continue
                }

                if c.isNumber, i == 0 || !isIdentifier(chars[i - 1]) {
                    let end = numberEnd(chars, from: i)
                    tokens.append(SyntaxToken(range: i..<end, kind: .number))
                    i = end
                    continue
                }

                if let prefix = language.attributePrefix, c == prefix, i + 1 < chars.count, isIdentifierStart(chars[i + 1]) {
                    var j = i + 1
                    while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                    let word = String(chars[i..<j])
                    tokens.append(SyntaxToken(range: i..<j, kind: language.keywords.contains(word) ? .keyword : .attribute))
                    i = j
                    continue
                }

                if let prefix = language.directivePrefix, c == prefix, i + 1 < chars.count,
                   chars[i + 1].isLetter || chars[i + 1] == "[" {
                    var j = i + 1
                    if chars[j] == "[" {
                        // Rust attributes: `#[derive(Debug)]`, up to the closing bracket.
                        while j < chars.count, chars[j] != "]" { j += 1 }
                        j = min(j + 1, chars.count)
                    } else {
                        while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                    }
                    tokens.append(SyntaxToken(range: i..<j, kind: .directive))
                    i = j
                    continue
                }

                if isIdentifierStart(c) {
                    var j = i + 1
                    while j < chars.count, isIdentifier(chars[j]) { j += 1 }
                    if j < chars.count, language.identifierSuffixes.contains(chars[j]) { j += 1 }
                    let word = String(chars[i..<j])
                    let isKeyword = language.caseInsensitiveKeywords
                        ? language.keywords.contains(word.lowercased())
                        : language.keywords.contains(word)
                    // `.keyword` after a dot is a member (`foo.default`), not a keyword.
                    let afterDot = i > 0 && chars[i - 1] == "."
                    if isKeyword && !afterDot {
                        tokens.append(SyntaxToken(range: i..<j, kind: .keyword))
                    } else if language.capitalizedTypes, c.isUppercase, word.contains(where: \.isLowercase) {
                        tokens.append(SyntaxToken(range: i..<j, kind: .type))
                    }
                    i = j
                    continue
                }

                i += 1
            }
            return tokens
        }

        /// Decimal (`42`, `3.14`, `1_000`, `1e9`), hex (`0x1F`), octal and binary (`0o7`, `0b1`).
        /// Stops before a range (`0..<n`) or a member (`1.description`).
        private func numberEnd(_ chars: [Character], from start: Int) -> Int {
            var j = start + 1
            if chars[start] == "0", j < chars.count, "xXoObB".contains(chars[j]) {
                j += 1
                while j < chars.count, chars[j].isHexDigit || chars[j] == "_" { j += 1 }
                return j
            }
            var seenDot = false
            while j < chars.count {
                let c = chars[j]
                if c.isNumber || c == "_" {
                    j += 1
                } else if c == ".", !seenDot, j + 1 < chars.count, chars[j + 1].isNumber {
                    seenDot = true
                    j += 1
                } else if c == "e" || c == "E", j + 1 < chars.count, chars[j + 1].isNumber {
                    j += 1
                } else {
                    break
                }
            }
            return j
        }
    }
}
