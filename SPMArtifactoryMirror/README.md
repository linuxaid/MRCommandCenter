# spm-artifactory-mirror

Makes a Swift package resolvable on a network that blocks GitHub. It publishes
every GitHub-hosted dependency, direct and transitive, into an Artifactory
Swift local repository. GitHub is only reached through an Artifactory VCS
remote repository, never from your machine.

The package has no dependencies, so it builds behind the GitHub block.

## Artifactory setup

| Repo | Type | Settings |
|---|---|---|
| `omni-github-vcs` | Remote, VCS | URL `https://github.com`, Git provider GitHub, GitHub token as password |
| `omni-swift-local` | Local, Swift | |
| `omni-swift` | Virtual, Swift | Includes `omni-swift-local` (plus any Swift remotes, such as a vendor registry) |

## Build

```bash
swift build -c release
```

The binary is `.build/release/spm-artifactory-mirror`.

## Run

```bash
.build/release/spm-artifactory-mirror ~/path/to/YourPackage
```

It asks for your Artifactory username and token, or reads `ART_USER` and
`ART_TOKEN`. Run with `--help` for every option.

Each round it runs `swift package resolve --replace-scm-with-registry`, finds
the GitHub packages SwiftPM couldn't get from the registry, publishes their
version tags to the local repo, and tries again. It stops when resolve succeeds.

It points the package at the `omni-swift` registry and moves any existing
`Package.resolved` to `Package.resolved.bak`. Versions already in the local
repo are skipped, so rerunning it is safe.

## Limits

- Dependencies pinned with `branch:` or `revision:` can't be published as registry versions.
- `.binaryTarget(url:)` downloads aren't mirrored.
- Only GitHub-hosted dependencies are mirrored.
