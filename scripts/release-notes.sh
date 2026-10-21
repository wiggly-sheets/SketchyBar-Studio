#!/usr/bin/env bash
# Print the release notes of one version.
#
# Usage: scripts/release-notes.sh <version>
#
# The notes carry the title, the download block, the Homebrew block, the notes
# block and the section of CHANGELOG.md that belongs to the version. The exit
# status is 0 when the section exists and 3 when it does not, so a release
# without a changelog section fails.
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

# The section starts at the "## " heading that names the version and ends at
# the next "## " heading. The awk exits 3 when there is no such section.
SECTION="$(awk -v version="$VERSION" '
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
' "$CHANGELOG")" || exit $?

printf '# SketchyBar Studio %s\n\n' "$VERSION"

cat <<'EOF'
## Download

- Download the attached universal DMG for macOS.
- GitHub automatically provides source code archives for this tag.

## Homebrew

```bash
brew tap wiggly-sheets/homebrew-tap
brew trust wiggly-sheets/homebrew-tap
brew install --cask sketchybar-studio
```

## Notes

- Universal binary includes Apple Silicon and Intel slices.
- Build is ad-hoc signed but not Developer ID signed or notarized. macOS may require opening through System Settings > Privacy & Security, right-clicking Open, or removing quarantine with `xattr` if you trust the download source.

EOF

printf '%s\n' "$SECTION"
