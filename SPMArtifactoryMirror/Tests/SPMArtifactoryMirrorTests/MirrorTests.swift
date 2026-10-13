import Foundation
import Testing
@testable import spm_artifactory_mirror

@Suite struct VersionsTests {
    @Test func picksSemverTagsNewestFirst() {
        let tags = ["v1.2.3", "1.0", "2.0.0-beta.1", "not-a-version", "3.1.0", "v3.1.0", "2.0.0"]
        let releases = Versions.pick(from: tags, max: 0, includePrereleases: false)
        #expect(releases == [
            ReleaseTag(tag: "3.1.0", version: "3.1.0"),
            ReleaseTag(tag: "2.0.0", version: "2.0.0"),
            ReleaseTag(tag: "v1.2.3", version: "1.2.3"),
            ReleaseTag(tag: "1.0", version: "1.0.0"),
        ])
    }

    @Test func releaseSortsAbovePrerelease() {
        let releases = Versions.pick(from: ["2.0.0-beta.1", "2.0.0"], max: 0, includePrereleases: true)
        #expect(releases.map(\.version) == ["2.0.0", "2.0.0-beta.1"])
    }

    @Test func limitsToNewest() {
        let releases = Versions.pick(from: ["1.0.0", "1.1.0", "1.2.0"], max: 2, includePrereleases: false)
        #expect(releases.map(\.version) == ["1.2.0", "1.1.0"])
    }
}

@Suite struct GitHubRepoTests {
    @Test func extractsReposFromResolveOutput() {
        let log = """
            Fetching https://github.com/datatheorem/TrustKit from cache
            warning: 'openssl': skipping cache due to an error: Failed to clone repository https://github.com/krzyzanowskim/OpenSSL.git:
            Fetching git@github.com:apple/swift-log.git
            Fetching https://mobile-protect-repos.securetheorem.com/mobileprotect-ios
            """
        let repos = GitHubRepo.extract(fromLog: log).sorted()
        #expect(repos.map(\.url) == [
            "https://github.com/apple/swift-log",
            "https://github.com/datatheorem/TrustKit",
            "https://github.com/krzyzanowskim/OpenSSL",
        ])
    }

    @Test func sanitizesRegistryIdentity() {
        let repo = GitHubRepo(owner: "socketio", repo: "socket.io-client-swift")
        #expect(repo.identity == "socketio.socket_io-client-swift")
    }

    @Test func metadataListsRepositoryURLs() throws {
        let data = try GitHubRepo(owner: "datatheorem", repo: "TrustKit").metadataJSON()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["repositoryURLs"] as? [String] == [
            "https://github.com/datatheorem/TrustKit",
            "https://github.com/datatheorem/TrustKit.git",
            "git@github.com:datatheorem/TrustKit.git",
        ])
    }
}

@Suite struct ArtifactoryURLTests {
    @Test func tagIsEncodedAsOnePathComponent() {
        let url = URL(string: "https://example.com/artifactory/api/vcs/downloadTag")!
            .appending(component: "release/1.0")
        #expect(url.absoluteString.hasSuffix("/downloadTag/release%2F1.0"))
    }
}
