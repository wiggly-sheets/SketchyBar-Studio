#!/usr/bin/env bash
# The changelog of the estate: one shape, three modes.
#
# Usage:
#   changelog.sh check            Validate CHANGELOG.md.
#   changelog.sh bump X.Y.Z       Move [Unreleased] under X.Y.Z and open a new one.
#   changelog.sh notes X.Y.Z      Print the body of the X.Y.Z section.
#
# The shape:
#   ## [Unreleased]
#   ### Added|Changed|Deprecated|Removed|Fixed|Security
#   - entry
#
#   ## [X.Y.Z] - YYYY-MM-DD
#
# A `<!-- pre-versioning -->` line stops validation, so a changelog that
# predates the tag can keep its old headings.
#
# Exit codes:
#   0  success
#   1  the changelog breaks the shape
#   2  bad usage
#   3  no section for the version, or the section is empty
set -euo pipefail

usage() {
	echo "usage: $(basename "$0") check|bump|notes [VERSION] [CHANGELOG.md]" >&2
	exit 2
}

mode="${1:-}"
case "$mode" in
check)
	CHANGELOG="${2:-CHANGELOG.md}"
	;;
bump | notes)
	VERSION="${2:-}"
	CHANGELOG="${3:-CHANGELOG.md}"
	[[ -n "$VERSION" ]] || usage
	VERSION="${VERSION#v}"
	;;
*)
	usage
	;;
esac

if [[ ! -f "$CHANGELOG" ]]; then
	echo "error: no changelog at $CHANGELOG" >&2
	exit 1
fi

VERSION_RE='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'
HEADING_RE='^## \[[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$'

# Prints the version token of a "## [X]" heading, or nothing.
heading_version() {
	local line="$1" rest close
	[[ "$line" == "## ["* ]] || return 0
	rest="${line#\#\# }"
	[[ "$rest" == "["* ]] || return 0
	close="${rest%%]*}"
	printf '%s' "${close#\[}"
}

# Prints the first "## " line number above $1.
next_heading() {
	awk -v start="$1" 'NR > start && /^## / { print NR; exit }' "$CHANGELOG"
}

legacy_line() {
	grep -n '^<!-- pre-versioning -->$' "$CHANGELOG" | head -1 | cut -d: -f1 || true
}

fail() {
	echo "error: $*" >&2
	exit 1
}

# Prints the allowed rank of a category, or nothing.
category_rank() {
	case "$1" in
	Added) echo 1 ;;
	Changed) echo 2 ;;
	Deprecated) echo 3 ;;
	Removed) echo 4 ;;
	Fixed) echo 5 ;;
	Security) echo 6 ;;
	esac
}

validate_categories() {
	local body="$1" seen="" last=0 heading rank
	while IFS= read -r heading; do
		[[ -n "$heading" ]] || continue
		rank="$(category_rank "${heading#\#\#\# }")"
		[[ -n "$rank" ]] || fail "unknown category heading: $heading"
		[[ "$rank" -gt "$last" ]] || fail "category out of order or repeated: $heading"
		[[ " $seen " != *" $rank "* ]] || fail "category repeated: $heading"
		seen="$seen $rank"
		last="$rank"
	done < <(printf '%s\n' "$body" | grep '^### ' || true)
}

# validate_section START END LABEL REQUIRE_CATEGORIES
validate_section() {
	local start="$1" end="$2" label="$3" require_categories="$4"
	local body bullets categories
	body="$(sed -n "${start},${end}p" "$CHANGELOG")"
	bullets="$(printf '%s\n' "$body" | grep -c '^- ' || true)"
	categories="$(printf '%s\n' "$body" | grep -c '^### ' || true)"
	validate_categories "$body"
	if [[ "$categories" -eq 0 ]]; then
		[[ "$require_categories" -eq 0 ]] || fail "$label has no ### category"
	fi
	if [[ "$bullets" -eq 0 ]]; then
		[[ "$label" == "[Unreleased]" ]] || fail "$label has no entries"
	fi
}

semver_gt() {
	local a="$1" b="$2" a_core b_core a_pre b_pre
	a_core="${a%%-*}"
	b_core="${b%%-*}"
	a_pre=""
	b_pre=""
	[[ "$a" == *-* ]] && a_pre="${a#*-}"
	[[ "$b" == *-* ]] && b_pre="${b#*-}"

	local IFS=.
	local -a a_parts b_parts
	read -r -a a_parts <<<"$a_core"
	read -r -a b_parts <<<"$b_core"
	local i
	for i in 0 1 2; do
		if ((10#${a_parts[$i]:-0} > 10#${b_parts[$i]:-0})); then return 0; fi
		if ((10#${a_parts[$i]:-0} < 10#${b_parts[$i]:-0})); then return 1; fi
	done
	[[ -z "$a_pre" && -n "$b_pre" ]] && return 0
	[[ -n "$a_pre" && -z "$b_pre" ]] && return 1
	[[ -z "$a_pre" && -z "$b_pre" ]] && return 1
	[[ "$a_pre" > "$b_pre" ]]
}

check_changelog() {
	local legacy first_line version label start end previous=""
	legacy="$(legacy_line)"

	first_line="$(awk '/^## / { print NR; exit }' "$CHANGELOG")"
	[[ -n "$first_line" ]] || fail "the changelog has no ## section"
	version="$(heading_version "$(sed -n "${first_line}p" "$CHANGELOG")")"
	[[ "$version" == "Unreleased" ]] || fail "the first section must be ## [Unreleased]"

	if [[ -n "$legacy" ]]; then
		if grep -n '^---$' "$CHANGELOG" | awk -F: -v stop="$legacy" '$1 < stop { found = 1 } END { exit !found }'; then
			fail "the changelog must not contain a --- separator"
		fi
	else
		grep -q '^---$' "$CHANGELOG" && fail "the changelog must not contain a --- separator"
	fi

	while IFS=: read -r line _; do
		[[ -n "$line" ]] || continue
		[[ -z "$legacy" || "$line" -lt "$legacy" ]] || break

		label="$(sed -n "${line}p" "$CHANGELOG")"
		version="$(heading_version "$label")"

		if [[ "$version" == "Unreleased" ]]; then
			[[ "$label" == "## [Unreleased]" ]] || fail "the Unreleased heading must be exactly ## [Unreleased]"
		else
			[[ "$version" =~ $VERSION_RE ]] || fail "bad version heading: $label"
			[[ "$label" =~ $HEADING_RE ]] || fail "bad version heading: $label"
			[[ -z "$previous" ]] || semver_gt "$previous" "$version" || fail "version $version is not below $previous"
			previous="$version"
		fi

		end="$(next_heading "$line")"
		[[ -n "$end" ]] || end="$(wc -l <"$CHANGELOG" | tr -d ' ')"
		if [[ "$version" == "Unreleased" ]]; then
			validate_section "$((line + 1))" "$((end - 1))" "[Unreleased]" 0
		else
			validate_section "$((line + 1))" "$((end - 1))" "[$version]" 1
		fi
	done < <(grep -n '^## ' "$CHANGELOG" || true)
}

bump_changelog() {
	[[ "$VERSION" =~ $VERSION_RE ]] || fail "the version \"$VERSION\" is not X.Y.Z"
	grep -Eq "^## \[${VERSION//./\\.}\]" "$CHANGELOG" && fail "the changelog already holds a section for $VERSION"

	local today tmp start end body bullets categories
	today="$(date -u +%F)"
	start="$(awk '/^## / { print NR; exit }' "$CHANGELOG")"
	[[ -n "$start" ]] || fail "the changelog has no ## section"
	[[ "$(sed -n "${start}p" "$CHANGELOG")" == "## [Unreleased]" ]] || fail "the first section must be ## [Unreleased]"

	end="$(next_heading "$start")"
	[[ -n "$end" ]] || end="$(wc -l <"$CHANGELOG" | tr -d ' ')"
	body="$(sed -n "$((start + 1)),$((end - 1))p" "$CHANGELOG")"
	bullets="$(printf '%s\n' "$body" | grep -c '^- ' || true)"
	categories="$(printf '%s\n' "$body" | grep -c '^### ' || true)"
	[[ "$bullets" -gt 0 ]] || fail "the [Unreleased] section has no entries; add a bullet before releasing"
	[[ "$categories" -gt 0 ]] || fail "the [Unreleased] section has no ### category; see scripts/changelog.sh"

	tmp="$(mktemp "${TMPDIR:-/tmp}/changelog.XXXXXX")"
	awk -v version="$VERSION" -v today="$today" '
		!done && $0 == "## [Unreleased]" {
			print "## [Unreleased]"
			print ""
			print "## [" version "] - " today
			done = 1
			next
		}
		{ print }
	' "$CHANGELOG" >"$tmp"
	mv "$tmp" "$CHANGELOG"
	echo "Moved [Unreleased] to [$VERSION] - $today"
}

notes_changelog() {
	local tmp notes
	tmp="$(mktemp "${TMPDIR:-/tmp}/changelog-notes.XXXXXX")"
	if ! awk -v want="$VERSION" '
		function version_of(line,   rest, stop, token, at) {
			if (substr(line, 1, 3) != "## ") return ""
			rest = substr(line, 4)
			if (substr(rest, 1, 1) == "[") {
				stop = index(rest, "]")
				if (stop == 0) return ""
				return substr(rest, 2, stop - 2)
			}
			# Frozen history may keep the old bare heading, optionally with an
			# em dash, a date or a note after the version token.
			token = rest
			sub(/[ \t].*$/, "", token)
			at = index(token, "—")
			if (at == 0) at = index(token, "–")
			if (at > 0) token = substr(token, 1, at - 1)
			sub(/-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/, "", token)
			return token
		}
		version_of($0) == want { found = 1; next }
		found && /^## / { exit }
		found { print }
		END { if (!found) exit 3 }
	' "$CHANGELOG" >"$tmp"; then
		rm -f "$tmp"
		echo "error: $CHANGELOG has no section for $VERSION" >&2
		exit 3
	fi
	notes="$(awk 'NF { started = 1 } started { print }' "$tmp")"
	rm -f "$tmp"
	if [[ -z "$notes" ]]; then
		echo "error: $CHANGELOG has no entries for $VERSION" >&2
		exit 3
	fi
	printf '%s\n' "$notes"
}

case "$mode" in
check) check_changelog ;;
bump) bump_changelog ;;
notes) notes_changelog ;;
esac
