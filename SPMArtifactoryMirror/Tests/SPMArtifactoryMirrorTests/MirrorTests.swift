import Foundation
import Testing
@testable import spm_artifactory_mirror

@Suite struct VersionTests {
    @Test func parsesTagSpellings() {
        #expect(Version("1.2.3")?.description == "1.2.3")
        #expect(Version("v1.2.3")?.description == "1.2.3")
        #expect(Version("1.2")?.description == "1.2.0")
        #expect(Version("2.0.0-beta.1+build.5")?.description == "2.0.0-beta.1")
        #expect(Version("release-1") == nil)
    }

    @Test func ordersBySemver() {
        let versions = ["1.10.0", "1.2.0", "2.0.0-beta.2", "2.0.0-beta.10", "2.0.0", "2.0.0-alpha"]
            .compactMap { Version($0) }
            .sorted()
            .map(\.description)
        #expect(versions == ["1.2.0", "1.10.0", "2.0.0-alpha", "2.0.0-beta.2", "2.0.0-beta.10", "2.0.0"])
    }

    @Test func suggestsTagCandidates() {
        #expect(Version("3.0.0")?.tagCandidates == ["3.0.0", "v3.0.0", "3.0", "v3.0"])
        #expect(Version("3.0.4")?.tagCandidates == ["3.0.4", "v3.0.4"])
    }
}

@Suite struct RequirementTests {
    @Test func rangeAllowsVersionsInsideIt() throws {
        let requirement = Requirement.range(try #require(Version("3.0.0")), try #require(Version("4.0.0")))
        #expect(requirement.allows(try #require(Version("3.0.7"))))
        #expect(!requirement.allows(try #require(Version("4.0.0"))))
        #expect(!requirement.allows(try #require(Version("2.9.9"))))
        #expect(!requirement.allows(try #require(Version("3.1.0-beta.1"))))
        #expect(requirement.minimumVersion?.description == "3.0.0")
    }

    @Test func exactAllowsOnlyItself() throws {
        let requirement = Requirement.exact(try #require(Version("2.60.0")))
        #expect(requirement.allows(try #require(Version("2.60.0"))))
        #expect(!requirement.allows(try #require(Version("2.60.1"))))
    }
}

@Suite struct ManifestTests {
    @Test func parsesDumpPackageOutput() throws {
        let json = """
            {"dependencies": [
              {"sourceControl": [{"identity": "trustkit",
                "location": {"remote": [{"urlString": "https://github.com/datatheorem/TrustKit.git"}]},
                "requirement": {"range": [{"lowerBound": "3.0.0", "upperBound": "4.0.0"}]}}]},
              {"sourceControl": [{"identity": "mobileprotect-ios",
                "location": {"remote": [{"urlString": "https://mobile-protect-repos.securetheorem.com/mobileprotect-ios"}]},
                "requirement": {"exact": ["26.3.2"]}}]},
              {"sourceControl": [{"identity": "swift-algorithms",
                "location": {"remote": ["https://github.com/apple/swift-algorithms"]},
                "requirement": {"branch": ["main"]}}]},
              {"registry": [{"identity": "mona.LinkedList",
                "requirement": {"range": [{"lowerBound": "1.0.0", "upperBound": "2.0.0"}]}}]},
              {"fileSystem": [{"identity": "sub", "path": "/tmp/sub"}]}
            ]}
            """
        let dependencies = try Manifest.parse(Data(json.utf8))
        #expect(dependencies.map(\.summary) == [
            "datatheorem/TrustKit 3.0.0..<4.0.0",
            "https://mobile-protect-repos.securetheorem.com/mobileprotect-ios exactly 26.3.2 (git)",
            "apple/swift-algorithms branch main",
            "mona.LinkedList 1.0.0..<2.0.0 (registry)",
            "sub at /tmp/sub (local path)",
        ])
    }
}

@Suite struct GitHubRepoTests {
    @Test func parsesGitHubURLs() {
        #expect(GitHubRepo(urlString: "https://github.com/datatheorem/TrustKit.git")?.description == "datatheorem/TrustKit")
        #expect(GitHubRepo(urlString: "https://github.com/apple/swift-nio")?.description == "apple/swift-nio")
        #expect(GitHubRepo(urlString: "git@github.com:apple/swift-log.git")?.description == "apple/swift-log")
        #expect(GitHubRepo(urlString: "https://gitlab.com/group/project") == nil)
    }

    @Test func extractsReposFromResolveOutput() {
        let log = """
            Fetching https://github.com/datatheorem/TrustKit from cache
            error: Failed to clone repository https://github.com/krzyzanowskim/OpenSSL.git:
            Fetching https://mobile-protect-repos.securetheorem.com/mobileprotect-ios
            """
        #expect(GitHubRepo.extract(fromLog: log).sorted().map(\.description) == [
            "datatheorem/TrustKit",
            "krzyzanowskim/OpenSSL",
        ])
    }

    @Test func sanitizesRegistryIdentity() {
        #expect(GitHubRepo(owner: "socketio", repo: "socket.io-client-swift").identity == "socketio.socket_io-client-swift")
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

@Suite struct TagsFeedTests {
    @Test func readsTagsFromAtom() {
        let xml = """
            <feed><entry>
              <link rel="alternate" type="text/html" href="https://github.com/datatheorem/TrustKit/releases/tag/3.0.7"/>
              <title>3.0.7</title>
            </entry><entry>
              <link rel="alternate" type="text/html" href="https://github.com/datatheorem/TrustKit/releases/tag/v3.0.6"/>
            </entry></feed>
            """
        #expect(TagsFeed.tags(fromAtom: xml) == ["3.0.7", "v3.0.6"])
    }
}

@Suite struct ConfigTests {
    @Test func buildsArtifactoryURLs() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appending(path: "Package.swift").path, contents: Data())

        let config = try Config.parse([directory.path], environment: [:])
        let repo = GitHubRepo(owner: "datatheorem", repo: "TrustKit")
        #expect(try config.archiveURL(for: repo, tag: "3.0.7").absoluteString
            == "https://artifactory.us.bank-dns.com/artifactory/github/datatheorem/TrustKit/archive/refs/tags/3.0.7.zip")
        #expect(try config.tagsFeedURL(for: repo).absoluteString
            == "https://artifactory.us.bank-dns.com/artifactory/github/datatheorem/TrustKit/tags.atom")
        #expect(config.localRegistryURL.absoluteString
            == "https://artifactory.us.bank-dns.com/artifactory/api/swift/omni-swift-local")
    }

    @Test func parsesVerbosity() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        FileManager.default.createFile(atPath: directory.appending(path: "Package.swift").path, contents: Data())

        #expect(try Config.parse(["-v", directory.path], environment: [:]).verbosity == .verbose)
        #expect(try Config.parse(["-vvv", directory.path], environment: [:]).verbosity == .debug)
        #expect(try Config.parse([directory.path], environment: [:]).verbosity == .normal)
    }
}
