import Foundation

struct ArtifactoryClient: Sendable {
    let config: Config
    /// nil with --list-only when ART_USER and ART_TOKEN aren't set.
    let credentials: Credentials?
    let logger: Logger

    private static let registryMediaType = "application/vnd.swift.registry.v1+json"

    /// GitHub downloads go anonymously first: Artifactory rejects a request
    /// that carries credentials it doesn't accept, even when the URL needs none.
    private enum Auth {
        case anonymousFirst
        case always
    }

    /// Tag names from the repo's tags.atom feed, newest first (at most 10).
    func listedTags(of repo: GitHubRepo) async throws -> [String] {
        let response = try await get(config.tagsFeedURL(for: repo), auth: .anonymousFirst)
        guard response.status == 200 else {
            throw MirrorError("HTTP \(response.status): \(preview(response.data))")
        }
        return TagsFeed.tags(fromAtom: String(decoding: response.data, as: UTF8.self))
    }

    /// The source zip for one tag, or nil if the tag doesn't exist.
    func downloadArchive(of repo: GitHubRepo, tag: String) async throws -> Data? {
        let response = try await get(config.archiveURL(for: repo, tag: tag), auth: .anonymousFirst)
        switch response.status {
        case 200: return response.data
        case 404: return nil
        default: throw MirrorError("HTTP \(response.status): \(preview(response.data))")
        }
    }

    func isPublished(_ repo: GitHubRepo, version: Version) async -> Bool {
        let url = config.localRegistryURL
            .appending(component: repo.scope)
            .appending(component: repo.name)
            .appending(component: version.description)
        let status = try? await get(url, accept: Self.registryMediaType, auth: .always).status
        return status == 200
    }

    private func get(_ url: URL, accept: String? = nil, auth: Auth) async throws -> (data: Data, status: Int) {
        // Credentials only ever go to the Artifactory host.
        let isArtifactory = url.host()?.lowercased() == config.artifactoryBase.host()?.lowercased()
        let canAuthenticate = isArtifactory && credentials != nil

        let response = try await send(url, accept: accept, withCredentials: canAuthenticate && auth == .always)
        if response.status == 401 && auth == .anonymousFirst && canAuthenticate {
            logger.verbose("  401 without credentials; retrying with them")
            return try await send(url, accept: accept, withCredentials: true)
        }
        return response
    }

    private func send(_ url: URL, accept: String?, withCredentials: Bool) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        if withCredentials, let credentials {
            request.setValue(credentials.basicAuthorization, forHTTPHeaderField: "Authorization")
        }
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let mode = withCredentials ? "with credentials" : "anonymous"
        logger.verbose("GET \(url.absoluteString) (\(mode)) → \(status), \(formatBytes(data.count)) in \(formatSeconds(since: start))")
        if status == 401 && withCredentials {
            logger.warn("Artifactory rejected the credentials for \(url.host() ?? "?"). Check ART_USER and ART_TOKEN.")
        }
        return (data, status)
    }

    private func preview(_ data: Data) -> String {
        String(decoding: data.prefix(300), as: UTF8.self)
    }
}
