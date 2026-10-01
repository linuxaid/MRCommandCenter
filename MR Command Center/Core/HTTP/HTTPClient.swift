import os
import Foundation

/// Shared request plumbing for GitLab and Jira: status mapping, 429 retry with
/// `Retry-After`, offline detection, and decoding off the main actor.
nonisolated struct HTTPClient: Sendable {
    let baseURL: URL
    let transport: any HTTPTransport
    let defaultHeaders: [String: String]
    var maxRateLimitRetries = 3
    var maxRetryAfter: TimeInterval = 60
    var defaultRetryAfter: TimeInterval = 5
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds))
    }

    func makeRequest(
        path: String,
        query: [URLQueryItem] = [],
        method: String = "GET",
        body: Data? = nil
    ) throws(APIError) -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw .invalidBaseURL("That doesn't look like a valid URL.")
        }
        let basePath = components.percentEncodedPath.hasSuffix("/")
            ? String(components.percentEncodedPath.dropLast())
            : components.percentEncodedPath
        components.percentEncodedPath = basePath + (path.hasPrefix("/") ? path : "/" + path)
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw .invalidBaseURL("Could not build a request URL.") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        for (name, value) in defaultHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await transport.send(request)
            } catch let error as URLError {
                throw Self.map(error)
            }

            let status = response.statusCode
            Log.network.debug("\(request.httpMethod ?? "GET", privacy: .public) \(request.url?.path() ?? "", privacy: .private) → \(status, privacy: .public)")

            switch status {
            case 200..<300:
                return HTTPResponse(data: data, response: response)
            case 401:
                throw APIError.unauthorized
            case 403:
                throw APIError.forbidden
            case 404:
                throw APIError.notFound
            case 429:
                let retryAfter = Self.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After"))
                guard attempt < maxRateLimitRetries else {
                    throw APIError.rateLimited(retryAfter: retryAfter)
                }
                attempt += 1
                let delay = min(retryAfter ?? defaultRetryAfter, maxRetryAfter)
                Log.network.notice("Rate limited; retrying in \(delay, privacy: .public)s (attempt \(attempt, privacy: .public))")
                try await sleep(delay)
            default:
                throw APIError.server(status: status)
            }
        }
    }

    @concurrent
    func get<T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = [],
        decoder: JSONDecoder
    ) async throws -> T {
        let request = try makeRequest(path: path, query: query)
        let response = try await send(request)
        return try Self.decode(type, from: response.data, decoder: decoder)
    }

    /// POSTs a JSON body (snake_case keys, nil fields omitted) and decodes the response.
    @concurrent
    func post<Body: Encodable & Sendable, T: Decodable & Sendable>(
        _ type: T.Type,
        path: String,
        body: Body,
        decoder: JSONDecoder
    ) async throws -> T {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let request = try makeRequest(path: path, method: "POST", body: try encoder.encode(body))
        let response = try await send(request)
        return try Self.decode(type, from: response.data, decoder: decoder)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, decoder: JSONDecoder) throws -> T {
        do {
            return try decoder.decode(type, from: data)
        } catch let error as DecodingError {
            let detail = describe(error)
            Log.network.error("Decoding \(String(describing: type), privacy: .public) failed: \(detail, privacy: .public)")
            throw APIError.decoding(detail)
        }
    }

    /// Accepts delta-seconds or an HTTP-date.
    static func parseRetryAfter(_ value: String?, now: Date = .now) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    static func map(_ error: URLError) -> Error {
        switch error.code {
        case .cancelled:
            return CancellationError()
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .timedOut,
             .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff:
            return APIError.offline
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot, .secureConnectionFailed:
            return APIError.transport("Secure connection failed. Check the server's certificate.")
        default:
            return APIError.transport(error.localizedDescription)
        }
    }

    /// Describes a decoding error by coding path only. Never includes values.
    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context):
            let prefix = path(context)
            return "missing key \(prefix.isEmpty ? "" : prefix + ".")\(key.stringValue)"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "unexpected value at \(path(context))"
        case .dataCorrupted(let context):
            return "invalid data at \(path(context).isEmpty ? "root" : path(context))"
        @unknown default:
            return "unknown decoding error"
        }
    }
}

nonisolated extension JSONDecoder {
    /// GitLab: snake_case keys, ISO 8601 dates with or without fractional seconds.
    static var gitLab: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom(FlexibleISO8601.decode)
        return decoder
    }

    /// Jira: camelCase keys; dates like `2024-05-01T10:00:00.000+0000`.
    static var jira: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(FlexibleISO8601.decode)
        return decoder
    }
}

nonisolated enum FlexibleISO8601 {
    static func decode(_ decoder: any Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = parse(string) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date format")
    }

    static func parse(_ string: String) -> Date? {
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let plain = Date.ISO8601FormatStyle()
        if let date = try? withFraction.parse(string) { return date }
        if let date = try? plain.parse(string) { return date }
        // Jira uses `+0000` offsets, which ISO8601FormatStyle rejects.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
