#!/bin/bash
# Throwing Wood's version number: the one in VERSION at the repo's root,
# MAJOR.MINOR or MAJOR.MINOR.PATCH, set by hand when Jamie names the next
# release. It starts at 0.1.
#
#   scripts/version.sh                  the version a build carries
#   scripts/version.sh test             checks VERSION is MAJOR.MINOR[.PATCH]
#   scripts/version.sh stamp <plist>    stamps a built Info.plist
#
# A build's number for Apple (CFBundleVersion) has to be whole numbers and
# go up, so it is the count of commits; the commit itself goes in
# ThrowingWoodCommit.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

number() {
  local number
  number=$(tr -d '[:space:]' < "$root/VERSION")
  if [[ ! $number =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))?$ ]]; then
    echo "VERSION should be MAJOR.MINOR or MAJOR.MINOR.PATCH, like 1.0 or 0.9.0; it says '$number'" >&2
    return 1
  fi
  echo "$number"
}

case "${1:-}" in
  test)
    # Assigned first, so a bad VERSION fails the check (an echo around
    # $(number) would succeed anyway).
    version=$(number)
    echo "version $version: ok"
    ;;
  stamp)
    plist=${2:?the built Info.plist}
    version=$(number)
    commit=$(git -C "$root" rev-parse HEAD 2>/dev/null || true)
    count=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)
    plutil -replace CFBundleShortVersionString -string "$version" "$plist"
    plutil -replace CFBundleVersion -string "$count" "$plist"
    plutil -replace ThrowingWoodCommit -string "$commit" "$plist"
    plutil -replace ThrowingWoodBuiltAt -string "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$plist"
    echo "Throwing Wood $version, build ${commit:0:7}"
    ;;
  "")
    number
    ;;
  *)
    echo "usage: scripts/version.sh [test | stamp <Info.plist>]" >&2
    exit 64
    ;;
esac
