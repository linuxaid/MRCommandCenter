import Foundation

struct ArtifactoryClient: Sendable {
    let config: Config
    let credentials: Credentials
    let logger: Logger

    private static let registryMediaType = "application/vnd.swift.registry.v1+json"

    /// Tag names from the repo's tags.atom feed, newest first (at most 10).
    func listedTags(of repo: GitHubRepo) async throws -> [String] {
        let response = try await get(config.tagsFeedURL(for: repo))
        guard response.status == 200 else {
            throw MirrorError("HTTP \(response.status): \(preview(response.data))")
        }
        return TagsFeed.tags(fromAtom: String(decoding: response.data, as: UTF8.self))
    }

    /// The source zip for one tag, or nil if the tag doesn't exist.
    func downloadArchive(of repo: GitHubRepo, tag: String) async throws -> Data? {
        let response = try await get(config.archiveURL(for: repo, tag: tag))
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
        let status = try? await get(url, accept: Self.registryMediaType).status
        return status == 200
    }

    private func get(_ url: URL, accept: String? = nil) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        // Credentials only ever go to the Artifactory host.
        if url.host()?.lowercased() == config.artifactoryBase.host()?.lowercased() {
            request.setValue(credentials.basicAuthorization, forHTTPHeaderField: "Authorization")
        }
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        let start = Date()
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        logger.verbose("GET \(url.absoluteString) → \(status), \(formatBytes(data.count)) in \(formatSeconds(since: start))")
        return (data, status)
    }

    private func preview(_ data: Data) -> String {
        String(decoding: data.prefix(300), as: UTF8.self)
    }
}
