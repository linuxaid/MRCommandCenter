// swift-tools-version: 6.0
import PackageDescription

// No dependencies on purpose: this has to build on networks that block GitHub.
let package = Package(
    name: "SPMArtifactoryMirror",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "spm-artifactory-mirror"),
        .testTarget(
            name: "SPMArtifactoryMirrorTests",
            dependencies: ["spm-artifactory-mirror"]
        ),
    ]
)
