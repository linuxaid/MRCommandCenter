import Foundation
import Synchronization
@testable import MR_Command_Center

/// Replays canned responses in order and records requests.
nonisolated final class StubTransport: HTTPTransport {
    enum Reply: Sendable {
        case response(status: Int, body: Data = Data(), headers: [String: String] = [:])
        case failure(URLError.Code)
    }

    private let replies: Mutex<[Reply]>
    private let recorded = Mutex<[URLRequest]>([])

    init(_ replies: [Reply]) {
        self.replies = Mutex(replies)
    }

    var requests: [URLRequest] { recorded.withLock { $0 } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recorded.withLock { $0.append(request) }
        let reply = replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        switch reply {
        case .response(let status, let body, let headers):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (body, response)
        case .failure(let code):
            throw URLError(code)
        case nil:
            fatalError("StubTransport ran out of replies for \(request.url?.path() ?? "")")
        }
    }
}

nonisolated enum Fixture {
    private final class BundleToken {}

    static func data(_ name: String) throws -> Data {
        let bundle = Bundle(for: BundleToken.self)
        guard let url = bundle.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: name + ".json"])
        }
        return try Data(contentsOf: url)
    }
}
