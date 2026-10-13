# spm-artifactory-mirror

Makes a Swift package resolvable on a network that blocks GitHub. It walks the
package's dependency tree by reading each `Package.swift`, downloads every
GitHub-hosted dependency through an Artifactory remote that proxies
github.com, and publishes it to an Artifactory Swift local repository.

The package has no dependencies, so it builds behind the GitHub block.

## Artifactory setup

| Repo | Type | Purpose |
|---|---|---|
| `github` | Remote, Generic | Proxies `https://github.com` (tag zips and `tags.atom`) |
| `omni-swift-local` | Local, Swift | Where mirrored packages are published |
| `omni-swift` | Virtual, Swift | Includes `omni-swift-local`; what SwiftPM resolves against |

## Build

```bash
swift build -c release
```

## Run

See the whole dependency tree without changing anything:

```bash
.build/release/spm-artifactory-mirror --list-only ~/path/to/YourPackage
```

Mirror everything and check that it resolves:

```bash
.build/release/spm-artifactory-mirror ~/path/to/YourPackage
```

Add `-v` to see every download, command and decision, or `-vvv` to also see
full command output and run SwiftPM with `-vvv`. Run with `--help` for all
options. It runs anonymously by default. To log in, set `ART_USER` and `ART_TOKEN`,
or pass `--login` to be prompted.

## How it works

1. `swift package dump-package` reads the package's direct dependencies.
   This evaluates `Package.swift` locally and fetches nothing.
2. For each GitHub dependency, `tags.atom` (through Artifactory) lists the
   10 newest tags. The newest tag that satisfies the requirement is used.
   If none does, it tries the lowest version the requirement allows, as
   `1.2.0`, `v1.2.0`, `1.2` and `v1.2`.
3. The tag's source zip is downloaded through Artifactory, its own
   `Package.swift` is read, and its dependencies are queued. That repeats
   until the whole tree is covered.
4. Each version is published to the Swift local repo, unless it's already
   there, with its GitHub URL in the metadata, so Artifactory can map
   `https://github.com/owner/repo` to the registry package.
5. The package is pointed at the Swift virtual repo, and
   `swift package resolve --replace-scm-with-registry` confirms it all
   resolves. If SwiftPM still asks for a GitHub package the manifests didn't
   lead to, that package is mirrored and the resolve is tried again.

Dependencies on other git hosts aren't published, because SwiftPM fetches
them with git directly, but their manifests are read so their GitHub
dependencies get mirrored too.

Step 5 points the package at the `omni-swift` registry and moves any existing
`Package.resolved` to `Package.resolved.bak`. `--list-only` skips steps 4
and 5.

## Limits

- Dependencies pinned with `branch:` or `revision:` can't be published as
  registry versions. They're listed under Problems.
- `.binaryTarget(url:)` downloads aren't mirrored.
- `tags.atom` only lists the 10 newest tags, so older versions are found by
  trying the lowest allowed version's usual tag spellings.
