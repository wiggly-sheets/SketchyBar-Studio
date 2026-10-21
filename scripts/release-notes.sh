#!/usr/bin/env bash
# Print the section of CHANGELOG.md that belongs to one version.
#
# Usage: scripts/release-notes.sh <version>
#
# The section starts at the "## " heading that names the version and ends at the
# next "## " heading. The exit status is 0 when the section exists and 3 when it
# does not, so a release without a changelog section fails.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $(basename "$0") <version>" >&2
  exit 2
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="$ROOT_DIR/CHANGELOG.md"

if [[ ! -f "$CHANGELOG" ]]; then
  echo "error: $CHANGELOG is missing." >&2
  exit 2
fi

awk -v version="$VERSION" '
  /^## / {
    if (printing) { exit }
    rest = substr($0, 4)
    if (substr(rest, 1, 1) == "[") {
      name = substr(rest, 2, index(rest, "]") - 2)
    } else {
      name = rest
      sub(/[[:space:]].*$/, "", name)
    }
    if (name == version) { printing = 1; found = 1 }
  }
  printing { print }
  END {
    if (!found) {
      print "error: CHANGELOG.md has no section for version " version > "/dev/stderr"
      exit 3
    }
  }
' "$CHANGELOG"
