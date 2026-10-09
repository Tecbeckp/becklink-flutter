#!/usr/bin/env bash
# Checks that the release metadata of becklink_flutter (the repository root) agrees with itself:
#   - `version` in pubspec.yaml equals `sdkVersion` in lib/src/sdk_info.dart. The SDK sends that
#     value as X-SDK-Version and the server picks the enum values it may send by it (contract
#     section 13), so a stale value could deliver values this SDK version does not know;
#   - CHANGELOG.md has a `## <version>` entry (pub.dev shows it as the release notes);
#   - with --tag: the tag is `v<version>` (the tag pattern configured on pub.dev)
#     and the CHANGELOG entry no longer says "unreleased".
#
# CI only (GitHub Actions, Linux), like the other scripts under .github/.
# Usage: version-check.sh [--tag <git tag>]
set -euo pipefail

usage() {
  echo "Usage: $0 [--tag <git tag>]" >&2
  exit 2
}

fail() {
  echo "::error::$*" >&2
  exit 1
}

tag=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag)
      [ "$#" -ge 2 ] || usage
      tag="$2"
      shift 2
      ;;
    *) usage ;;
  esac
done

sdk_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pubspec="$sdk_dir/pubspec.yaml"
sdk_info="$sdk_dir/lib/src/sdk_info.dart"
changelog="$sdk_dir/CHANGELOG.md"

# Top-level `version:` only (nested keys are indented), with optional quotes and comment.
version_pattern="^version:[[:space:]]*[\"']?([^\"'[:space:]#]+)[\"']?[[:space:]]*(#.*)?$"
versions="$(sed -nE "s/${version_pattern}/\1/p" "$pubspec")"
[ -n "$versions" ] || fail "No top-level version in pubspec.yaml."
[ "$(printf '%s\n' "$versions" | wc -l)" -eq 1 ] ||
  fail "More than one top-level version in pubspec.yaml."
version="$versions"

semver='^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
[[ "$version" =~ $semver ]] ||
  fail "pubspec.yaml version '$version' is not a semantic version."

sdk_versions="$(sed -nE "s/^const String sdkVersion = '([^']*)';[[:space:]]*$/\1/p" "$sdk_info")"
[ -n "$sdk_versions" ] ||
  fail "No \`const String sdkVersion = '...';\` line in lib/src/sdk_info.dart."
[ "$(printf '%s\n' "$sdk_versions" | wc -l)" -eq 1 ] ||
  fail "More than one sdkVersion in lib/src/sdk_info.dart."
[ "$sdk_versions" = "$version" ] ||
  fail "sdkVersion '$sdk_versions' in lib/src/sdk_info.dart is not pubspec.yaml's '$version'."

# `## 1.2.3`, `## 1.2.3 (2026-10-07)` or `## [1.2.3] - 2026-10-07`. The semver check above
# leaves `.` and `+` as the only characters that are special in the pattern.
escaped="$(printf '%s' "$version" | sed 's/[.+]/\\&/g')"
heading="$(grep -E -m 1 '^## \[?'"$escaped"'\]?([[:space:]]|$)' "$changelog" || true)"
[ -n "$heading" ] || fail "CHANGELOG.md has no '## $version' entry."

if [ -n "$tag" ]; then
  expected_tag="v$version"
  [ "$tag" = "$expected_tag" ] ||
    fail "Tag '$tag' does not match pubspec.yaml version '$version' (expected '$expected_tag')."
  if printf '%s' "$heading" | grep -qi 'unreleased'; then
    fail "The CHANGELOG entry for $version still says unreleased; put the release date there."
  fi
fi

echo "becklink_flutter $version: pubspec.yaml, sdk_info.dart and CHANGELOG.md agree."
if [ -n "$tag" ]; then
  echo "Tag $tag matches."
fi
