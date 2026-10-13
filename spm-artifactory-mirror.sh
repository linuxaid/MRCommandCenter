#!/usr/bin/env bash
#
# spm-artifactory-mirror.sh
#
# Makes a Swift package resolvable on a network that blocks GitHub by
# publishing every GitHub-hosted dependency (direct and transitive) into an
# Artifactory Swift local repository. GitHub is only reached through an
# Artifactory VCS remote repository, never from this machine.
#
# How it works:
#   1. Run `swift package resolve --replace-scm-with-registry` against the
#      Artifactory Swift virtual repo.
#   2. Collect every github.com URL SwiftPM still tried to fetch with git
#      (meaning the registry didn't know it yet).
#   3. For each one, list its tags through the VCS remote, download each
#      version's source zip, and `swift package-registry publish` it to the
#      Swift local repo with its GitHub URL recorded in the metadata, so
#      Artifactory can map the URL to the registry package.
#   4. Repeat. Each round uncovers the next layer of transitive dependencies,
#      until resolve succeeds.
#
# Artifactory setup this expects:
#   - VCS remote repo   (URL https://github.com, Git provider GitHub, token)
#   - Swift local repo  (where packages get published)
#   - Swift virtual repo that includes the Swift local repo
#
# Usage:
#   ./spm-artifactory-mirror.sh /path/to/package
#
# Credentials: set ART_USER and ART_TOKEN, or the script prompts for them.
# They are written to a private temporary netrc file, never passed as
# command-line arguments, and deleted on exit.
#
# Settings (override with environment variables):
ART_BASE="${ART_BASE:-https://artifactory-uat.us.bank-dns.com/artifactory}"
SWIFT_VIRTUAL="${SWIFT_VIRTUAL:-omni-swift}"
SWIFT_LOCAL="${SWIFT_LOCAL:-omni-swift-local}"
VCS_REMOTE="${VCS_REMOTE:-omni-github-vcs}"
MAX_VERSIONS="${MAX_VERSIONS:-0}"            # 0 = every version tag, N = newest N per package
INCLUDE_PRERELEASES="${INCLUDE_PRERELEASES:-0}"
MAX_ROUNDS="${MAX_ROUNDS:-15}"

set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*" >&2; }

[[ $# -eq 1 ]] || die "usage: $0 /path/to/package"
PKG_DIR="$(cd "$1" && pwd)"
[[ -f "$PKG_DIR/Package.swift" ]] || die "no Package.swift in $PKG_DIR"

for tool in swift curl unzip python3; do
  command -v "$tool" >/dev/null || die "$tool not found"
done

ART_USER="${ART_USER:-}"
[[ -n "$ART_USER" ]] || read -r -p "Artifactory username: " ART_USER
if [[ -z "${ART_TOKEN:-}" ]]; then
  read -r -s -p "Artifactory token or password for $ART_USER: " ART_TOKEN
  echo >&2
fi

VIRTUAL_URL="$ART_BASE/api/swift/$SWIFT_VIRTUAL"
LOCAL_URL="$ART_BASE/api/swift/$SWIFT_LOCAL"
ART_HOST="$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname)' "$ART_BASE")"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/spm-mirror.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

NETRC="$WORK/netrc"
(umask 077; printf 'machine %s login %s password %s\n' "$ART_HOST" "$ART_USER" "$ART_TOKEN" > "$NETRC")
unset ART_TOKEN

art_curl() { curl -sS --fail-with-body --netrc-file "$NETRC" "$@" </dev/null; }

urlencode() {
  python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Prints one tag name per line for github.com/<owner>/<repo>.
list_tags() {
  art_curl "$ART_BASE/api/vcs/tags/$VCS_REMOTE/$1/$2" | python3 -I -c '
import json, sys
for t in json.load(sys.stdin):
    name = t.get("name") if isinstance(t, dict) else t
    if name:
        print(name)
'
}

# Reads tag names on stdin; prints "<tag>\t<semver>" newest first.
# Accepts "1.2.3", "v1.2.3" and "1.2" (as 1.2.0), like SwiftPM does.
pick_versions() {
  python3 -I -c '
import re, sys
max_n, prereleases = int(sys.argv[1]), sys.argv[2] == "1"
pattern = re.compile(r"^v?(\d+)\.(\d+)(?:\.(\d+))?(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$")
found = {}
for tag in sys.stdin.read().split():
    m = pattern.match(tag)
    if not m:
        continue
    major, minor, patch, pre, _ = m.groups()
    if pre and not prereleases:
        continue
    major, minor, patch = int(major), int(minor), int(patch or 0)
    version = f"{major}.{minor}.{patch}{pre or str()}"
    found.setdefault(version, ((major, minor, patch, pre is None, pre or str()), tag))
rows = sorted(found.items(), key=lambda kv: kv[1][0], reverse=True)
if max_n > 0:
    rows = rows[:max_n]
for version, (_, tag) in rows:
    print(f"{tag}\t{version}")
' "$MAX_VERSIONS" "$INCLUDE_PRERELEASES"
}

version_exists() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --netrc-file "$NETRC" \
    -H 'Accept: application/vnd.swift.registry.v1+json' \
    "$LOCAL_URL/$1/$2/$3" </dev/null || true)"
  [[ "$code" == "200" ]]
}

write_metadata() {
  python3 -I -c '
import json, sys
owner, repo, out = sys.argv[1:4]
base = f"https://github.com/{owner}/{repo}"
urls = [base, base + ".git", f"git@github.com:{owner}/{repo}.git"]
with open(out, "w") as f:
    json.dump({"repositoryURLs": urls, "description": f"Mirrored from {base}"}, f)
' "$1" "$2" "$3"
}

publish_version() {
  local owner=$1 repo=$2 scope=$3 name=$4 tag=$5 version=$6
  local dir="$WORK/src/$scope.$name/$version"
  mkdir -p "$dir/extract"

  if ! art_curl -L -o "$dir/source.zip" \
      "$ART_BASE/api/vcs/downloadTag/$VCS_REMOTE/$owner/$repo/$(urlencode "$tag")"; then
    log "  $version: download failed, skipping"
    return 0
  fi
  if ! unzip -q "$dir/source.zip" -d "$dir/extract"; then
    log "  $version: could not unzip, skipping"
    return 0
  fi

  local manifest
  manifest="$(find "$dir/extract" -maxdepth 2 -name Package.swift -print -quit)"
  if [[ -z "$manifest" ]]; then
    log "  $version: no Package.swift at this tag, skipping"
    rm -rf "$dir"
    return 0
  fi

  write_metadata "$owner" "$repo" "$dir/metadata.json"
  if swift package-registry publish "$scope.$name" "$version" \
      --url "$LOCAL_URL" \
      --package-path "$(dirname "$manifest")" \
      --metadata-path "$dir/metadata.json" \
      --scratch-directory "$dir/scratch" \
      --netrc-file "$NETRC" \
      </dev/null >"$dir/publish.log" 2>&1; then
    log "  $version: published"
  else
    log "  $version: publish failed:"
    sed 's/^/      /' "$dir/publish.log" >&2
  fi
  rm -rf "$dir"
}

mirror_package() {
  local url=$1 path owner repo scope name tags versions tag version
  path="${url#https://github.com/}"
  owner="${path%%/*}"
  repo="${path#*/}"
  repo="${repo%.git}"
  # Registry identities: scope is [A-Za-z0-9-], name is [A-Za-z0-9_-].
  scope="$(printf '%s' "$owner" | tr -c 'A-Za-z0-9-' '-')"
  name="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9_-' '_')"

  log "Mirroring github.com/$owner/$repo as $scope.$name"
  if ! tags="$(list_tags "$owner" "$repo")"; then
    log "  could not list tags through $VCS_REMOTE, skipping"
    return 0
  fi
  versions="$(printf '%s\n' "$tags" | pick_versions)"
  if [[ -z "$versions" ]]; then
    log "  no version tags found (a registry can only serve tagged versions), skipping"
    return 0
  fi

  while IFS=$'\t' read -r tag version; do
    if version_exists "$scope" "$name" "$version"; then
      log "  $version: already published"
    else
      publish_version "$owner" "$repo" "$scope" "$name" "$tag" "$version"
    fi
  done <<<"$versions"
}

resolve() {
  swift package resolve --package-path "$PKG_DIR" \
    --replace-scm-with-registry --netrc-file "$NETRC" \
    </dev/null >"$WORK/resolve.log" 2>&1
}

# GitHub URLs SwiftPM fell back to fetching with git, normalized to
# https://github.com/<owner>/<repo>.
github_urls_from_log() {
  {
    grep -oE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$WORK/resolve.log" || true
    grep -oE 'git@github\.com:[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' "$WORK/resolve.log" \
      | sed 's#^git@github\.com:#https://github.com/#' || true
  } | sed -E 's/\.git$//; s/\.$//' | sort -u
}

log "Package:  $PKG_DIR"
log "Registry: $VIRTUAL_URL"
log "Publish:  $LOCAL_URL"
swift package-registry set "$VIRTUAL_URL" --package-path "$PKG_DIR" </dev/null >/dev/null

if [[ -f "$PKG_DIR/Package.resolved" ]]; then
  mv "$PKG_DIR/Package.resolved" "$PKG_DIR/Package.resolved.bak"
  log "Moved existing Package.resolved to Package.resolved.bak"
fi
swift package reset --package-path "$PKG_DIR" </dev/null

: > "$WORK/seen"
for (( round = 1; round <= MAX_ROUNDS; round++ )); do
  log "Round $round: resolving"
  if resolve; then
    log "Resolved. Every dependency is now available from $SWIFT_VIRTUAL."
    exit 0
  fi

  github_urls_from_log > "$WORK/found"
  new="$(comm -13 "$WORK/seen" "$WORK/found")"
  if [[ -z "$new" ]]; then
    log "Resolve still fails and there are no new GitHub packages to publish."
    log "Last resolve output:"
    tail -n 40 "$WORK/resolve.log" >&2
    cat >&2 <<'EOF'

Common causes:
  - A manifest pins a dependency with branch: or revision: instead of a version.
  - A .binaryTarget(url:) downloads from a blocked host.
  - A dependency is hosted somewhere other than GitHub.
  - A required version failed to publish (see "publish failed" above), or
    MAX_VERSIONS excluded it.
EOF
    exit 1
  fi

  while read -r url; do
    mirror_package "$url"
  done <<<"$new"
  sort -u "$WORK/seen" "$WORK/found" -o "$WORK/seen"
done

die "gave up after $MAX_ROUNDS rounds"
