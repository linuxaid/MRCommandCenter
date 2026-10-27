#!/usr/bin/env bash
# Sets the app's version (MARKETING_VERSION, shown in the app's sidebar) for a release.
# Usage: bash scripts/claude/set-version.sh 26.10.27
set -euo pipefail

VERSION="${1:-}"
if ! [[ "$VERSION" =~ ^[0-9]{2}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
  echo "Usage: $0 <yy.m.d>, for example 26.10.27" >&2
  exit 1
fi

PROJECT="$(cd "$(dirname "$0")/../.." && pwd)/MR Command Center.xcodeproj/project.pbxproj"
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/" "$PROJECT"

COUNT=$(grep -c "MARKETING_VERSION = $VERSION;" "$PROJECT")
if [ "$COUNT" = "0" ]; then
  echo "Didn't find MARKETING_VERSION in $PROJECT" >&2
  exit 1
fi
echo "Set MARKETING_VERSION to $VERSION ($COUNT build configurations)."
