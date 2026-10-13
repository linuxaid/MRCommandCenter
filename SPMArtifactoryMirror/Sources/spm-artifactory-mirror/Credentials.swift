import Foundation

struct Credentials: Sendable {
    let user: String
    let token: String

    var basicAuthorization: String {
        "Basic " + Data("\(user):\(token)".utf8).base64EncodedString()
    }

    static func load(environment: [String: String]) throws -> Credentials {
        var user = environment["ART_USER"] ?? ""
        if user.isEmpty {
            FileHandle.standardError.write(Data("Artifactory username: ".utf8))
            user = readLine()?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        guard !user.isEmpty else { throw MirrorError("no Artifactory username") }

        var token = environment["ART_TOKEN"] ?? ""
        if token.isEmpty {
            token = try readSecret(prompt: "Artifactory token or password for \(user): ")
        }
        guard !token.isEmpty else { throw MirrorError("no Artifactory token") }

        return Credentials(user: user, token: token)
    }

    /// SwiftPM subprocesses read credentials from this file, so the token never
    /// appears on a command line. Only the owner can read it.
    func writeNetrc(to url: URL, host: String) throws {
        let entry = "machine \(host) login \(user) password \(token)\n"
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data(entry.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MirrorError("could not write \(url.path)")
        }
    }
}

private func readSecret(prompt: String) throws -> String {
    var buffer = [CChar](repeating: 0, count: 4096)
    let secret: String? = buffer.withUnsafeMutableBufferPointer { buffer in
        guard let result = readpassphrase(prompt, buffer.baseAddress, buffer.count, 0) else { return nil }
        return String(cString: result)
    }
    guard let secret else { throw MirrorError("could not read the token") }
    return secret
}
