import Foundation
import Testing
@testable import MR_Command_Center

struct HTTPClientTests {
    private func client(_ transport: StubTransport) -> HTTPClient {
        var client = HTTPClient(
            baseURL: URL(string: "https://gitlab.example.com/sub")!,
            transport: transport,
            defaultHeaders: ["PRIVATE-TOKEN": "secret"]
        )
        client.sleep = { _ in }
        return client
    }

    @Test func buildsURLUnderBasePathWithHeaders() throws {
        let request = try client(StubTransport([])).makeRequest(
            path: "/api/v4/merge_requests",
            query: [URLQueryItem(name: "state", value: "opened")]
        )
        #expect(request.url?.absoluteString == "https://gitlab.example.com/sub/api/v4/merge_requests?state=opened")
        #expect(request.value(forHTTPHeaderField: "PRIVATE-TOKEN") == "secret")
    }

    @Test(arguments: [(401, APIError.unauthorized), (403, .forbidden), (404, .notFound), (500, .server(status: 500))])
    func mapsStatusCodes(status: Int, expected: APIError) async throws {
        let transport = StubTransport([.response(status: status)])
        let request = try client(transport).makeRequest(path: "/x")
        await #expect(throws: expected) {
            _ = try await client(transport).send(request)
        }
    }

    @Test func retriesAfterRateLimitThenSucceeds() async throws {
        let transport = StubTransport([
            .response(status: 429, headers: ["Retry-After": "2"]),
            .response(status: 200, body: Data("{}".utf8)),
        ])
        let delays = SleepRecorder()
        var http = client(transport)
        http.sleep = { await delays.record($0) }

        let response = try await http.send(try http.makeRequest(path: "/x"))
        #expect(response.response.statusCode == 200)
        #expect(transport.requests.count == 2)
        #expect(await delays.values == [2])
    }

    @Test func givesUpAfterMaxRateLimitRetries() async throws {
        let transport = StubTransport(Array(repeating: .response(status: 429, headers: ["Retry-After": "1"]), count: 4))
        let http = client(transport)
        await #expect(throws: APIError.rateLimited(retryAfter: 1)) {
            _ = try await http.send(try http.makeRequest(path: "/x"))
        }
        #expect(transport.requests.count == 4)
    }

    @Test func capsRetryAfter() async throws {
        let transport = StubTransport([
            .response(status: 429, headers: ["Retry-After": "3600"]),
            .response(status: 200),
        ])
        let delays = SleepRecorder()
        var http = client(transport)
        http.sleep = { await delays.record($0) }
        _ = try await http.send(try http.makeRequest(path: "/x"))
        #expect(await delays.values == [60])
    }

    @Test func parsesRetryAfterFormats() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(HTTPClient.parseRetryAfter("30") == 30)
        #expect(HTTPClient.parseRetryAfter(nil) == nil)
        #expect(HTTPClient.parseRetryAfter("soon") == nil)
        // `now` is 2023-11-14 22:13:20 UTC.
        #expect(HTTPClient.parseRetryAfter("Tue, 14 Nov 2023 22:13:40 GMT", now: now) == 20)
        #expect(HTTPClient.parseRetryAfter("Tue, 14 Nov 2023 22:00:00 GMT", now: now) == 0)
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .timedOut])
    func mapsConnectivityErrorsToOffline(code: URLError.Code) async throws {
        let transport = StubTransport([.failure(code)])
        let http = client(transport)
        await #expect(throws: APIError.offline) {
            _ = try await http.send(try http.makeRequest(path: "/x"))
        }
    }

    @Test func decodingErrorsDoNotLeakValues() throws {
        let body = Data(#"{"id": "not-a-number-secret", "username": "u", "name": "n"}"#.utf8)
        do {
            _ = try HTTPClient.decode(GitLabUser.self, from: body, decoder: .gitLab)
            Issue.record("Expected decoding to fail")
        } catch let APIError.decoding(detail) {
            #expect(!detail.contains("secret"))
            #expect(detail.contains("id"))
        }
    }
}

private actor SleepRecorder {
    private(set) var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { values.append(value) }
}
