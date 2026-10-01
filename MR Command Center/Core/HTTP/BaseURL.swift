import Foundation

/// Normalizes user-entered base URLs: trims whitespace and trailing slashes, and
/// strips API path suffixes users often paste (e.g. `/api/v4`).
nonisolated enum BaseURL {
    static let gitLabSuffixes = ["/api/v4"]
    static let jiraSuffixes = ["/rest/api/3", "/rest/api/2"]

    static func normalize(_ raw: String, strippingSuffixes suffixes: [String] = []) throws(APIError) -> URL {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw .missingBaseURL }
        if !text.contains("://") { text = "https://" + text }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty
        else { throw .invalidBaseURL("That doesn't look like a valid URL.") }
        guard scheme == "https" || scheme == "http" else {
            throw .invalidBaseURL("The URL must start with https://")
        }

        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in suffixes where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") { path.removeLast() }

        components.scheme = scheme
        components.path = path
        components.query = nil
        components.fragment = nil
        guard let url = components.url else { throw .invalidBaseURL("That doesn't look like a valid URL.") }
        return url
    }
}
