import Foundation

/// The on-device model's guided generation can end a JSON string at the first `"` it
/// copies from code (e.g. `loading="lazy"`), truncating the structured output. In a live
/// comparison, sending code with single quotes in place of double quotes parsed 10/10
/// files, versus 9/10 unchanged and 8/10 with a full-width quote. So everything sent to the
/// model uses single quotes, and the instructions say so.
nonisolated enum QuoteSafety {
    static let note = "Note: double quote characters in code are shown as single quotes here; that is not a change in the code."

    static func encode(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
    }

    static func encodeInstructions(_ text: String) -> String {
        encode(text) + "\n" + note
    }
}
