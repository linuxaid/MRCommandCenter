import Foundation

/// The lowest network seam. Mock this to test clients without a server.
nonisolated protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

nonisolated struct URLSessionTransport: HTTPTransport {
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport("The server sent a non-HTTP response.")
        }
        return (data, http)
    }
}

nonisolated struct HTTPResponse: Sendable {
    let data: Data
    let response: HTTPURLResponse

    func header(_ name: String) -> String? {
        response.value(forHTTPHeaderField: name)
    }
}
