import Foundation

struct ArtifactoryClient: Sendable {
    let config: Config
    let authorization: String

    private static let registryMediaType = "application/vnd.swift.registry.v1+json"

    /// Tag names of github.com/<owner>/<repo>, listed through the VCS remote.
    func listTags(owner: String, repo: String) async throws -> [String] {
        let url = config.artifactoryBase
            .appending(path: "api/vcs/tags")
            .appending(component: config.vcsRemote)
            .appending(component: owner)
            .appending(component: repo)
        let (data, status) = try await get(url)
        guard status == 200 else {
            throw MirrorError("listing tags returned HTTP \(status): \(preview(data))")
        }
        guard let items = try JSONSerialization.jsonObject(with: data) as? [Any] else {
            throw MirrorError("unexpected tag list format: \(preview(data))")
        }
        return items.compactMap { item in
            if let tag = item as? [String: Any] { return tag["name"] as? String }
            return item as? String
        }
    }

    /// Source zip of one tag, downloaded through the VCS remote.
    func downloadTag(owner: String, repo: String, tag: String) async throws -> Data {
        let url = config.artifactoryBase
            .appending(path: "api/vcs/downloadTag")
            .appending(component: config.vcsRemote)
            .appending(component: owner)
            .appending(component: repo)
            .appending(component: tag)
        let (data, status) = try await get(url)
        guard status == 200 else {
            throw MirrorError("download returned HTTP \(status): \(preview(data))")
        }
        return data
    }

    func versionExists(scope: String, name: String, version: String) async -> Bool {
        let url = config.localRegistryURL
            .appending(component: scope)
            .appending(component: name)
            .appending(component: version)
        let status = try? await get(url, accept: Self.registryMediaType).status
        return status == 200
    }

    private func get(_ url: URL, accept: String? = nil) async throws -> (data: Data, status: Int) {
        var request = URLRequest(url: url)
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func preview(_ data: Data) -> String {
        String(decoding: data.prefix(300), as: UTF8.self)
    }
}
