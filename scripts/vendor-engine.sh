#!/bin/bash
# The game engines, vendored from tagged releases of kubb-engine
# (jthingelstad/kubb-engine), byte for byte, as the engine's own docs ask
# (its docs/VERSIONING.md "Releases and vendoring"). The newest engine, which
# every new match plays on, and each older minor the app still carries so a
# match keeps its own engine (docs/ENGINES.md):
#
#   ThrowingWoodKit/Sources/KubbEngine/Engine/   the newest (TAG): core/,
#       room/, session/, tune/, version.lua, engine.json (the engine's
#       manifest: its version and a sha256 for every Lua file) and LICENSE
#   ThrowingWoodKit/Sources/KubbEngine/Engines/<major.minor>/   each of OLDER,
#       laid out the same way
#   ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/golden/   the newest's
#       golden driver and corpus (tests/golden/drive.lua and hashes.json),
#       the hashes its reference platform gives, which the tests must match
#   ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/engines/<major.minor>/golden/
#       the same for each of OLDER
#
#   scripts/vendor-engine.sh sync    copy them from the kubb-engine checkout
#                                    beside this repo, each at its tag (the
#                                    tag's tree, never the working tree; the
#                                    checkout is only read)
#   scripts/vendor-engine.sh check   every vendored copy is the release its tag
#                                    names: every Lua file as its engine.json
#                                    says, byte for byte, no file missing or
#                                    extra, the corpus recorded by this engine
#                                    version or an earlier one (a hash-neutral
#                                    release keeps its corpus: 0.4.1 carries
#                                    0.2.0's, 0.7.1 to 0.7.4 0.5.0's, 0.8.1 0.8.0's;
#                                    kubb-engine docs/VERSIONING.md), and no
#                                    engine under Engines/ that OLDER does not
#                                    name. Needs no kubb-engine checkout (CI runs it)
#
# To move to a new patch of the newest: change TAG, run sync, then the tests
# (AGENTS.md). To move to a new minor and keep the last one: put the old TAG in
# OLDER, the new one in TAG. To stop carrying an older minor: take it out of
# OLDER and run sync.

set -euo pipefail

# The kubb-engine release new matches play on, and the older ones carried beside it,
# one per major.minor, newest first.
TAG=v0.8.1
OLDER=(v0.7.4)

root=$(cd "$(dirname "$0")/.." && pwd)
source_dir=${KUBB_ENGINE_SOURCE:-$root/../kubb-engine}
sources=$root/ThrowingWoodKit/Sources/KubbEngine
fixtures=$root/ThrowingWoodKit/Tests/KubbEngineTests/Fixtures

minor_of() { local v=${1#v}; echo "${v%.*}"; }
# Where the engine of tag $1 and its golden corpus live.
engine_dir() { [[ $1 == "$TAG" ]] && echo "$sources/Engine" || echo "$sources/Engines/$(minor_of "$1")"; }
golden_dir() { [[ $1 == "$TAG" ]] && echo "$fixtures/golden" || echo "$fixtures/engines/$(minor_of "$1")/golden"; }

# What is copied: engine paths into the engine's folder, test paths into its golden/.
engine_paths=(core room session tune version.lua engine.json LICENSE)
golden_files=(drive.lua hashes.json)

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# engine.json's "files" map as "<path> <sha256>" lines (it is written one
# entry a line by the engine's tools/manifest.mjs).
manifest_files() {
  sed -nE '/^  "files": \{/,/^  \}/s/^ *"([^"]+\.lua)": "([0-9a-f]{64})",?$/\1 \2/p' "$1/engine.json"
}

json_version() {
  sed -nE 's/^ *"version": "([^"]+)",?$/\1/p' "$1" | head -1
}

sync_one() {
  local tag=$1 engine golden commit count path f
  engine=$(engine_dir "$tag")
  golden=$(golden_dir "$tag")
  commit=$(git -C "$source_dir" rev-parse --verify --quiet "$tag^{commit}") || {
    echo "$source_dir has no tag $tag; fetch its tags first (git -C $source_dir fetch --tags)." >&2
    exit 1
  }
  rm -rf "$engine" "$golden"
  mkdir -p "$engine" "$golden"
  # Blobs straight from the tag's tree: no working tree, no filters.
  count=0
  while IFS= read -r path; do
    mkdir -p "$engine/$(dirname "$path")"
    git -C "$source_dir" cat-file blob "$commit:$path" > "$engine/$path"
    count=$((count + 1))
  done < <(git -C "$source_dir" ls-tree -r --name-only "$commit" -- "${engine_paths[@]}")
  for f in "${golden_files[@]}"; do
    git -C "$source_dir" cat-file blob "$commit:tests/golden/$f" > "$golden/$f"
  done
  echo "vendored kubb-engine $tag (${commit:0:7}): $count files, and the golden driver and corpus"
}

check_one() {
  local tag=$1 engine golden version count name want f corpus expected
  engine=$(engine_dir "$tag")
  golden=$(golden_dir "$tag")
  corpus=none
  [[ -f $engine/engine.json ]] || { fail "no ${engine#"$root"/}/engine.json; run sync"; return; }
  version=$(json_version "$engine/engine.json")
  [[ "v$version" == "$tag" ]] || fail "$(minor_of "$tag"): engine.json is version $version, its tag is $tag; run sync"
  count=0
  while read -r name want; do
    count=$((count + 1))
    if [[ ! -f $engine/$name ]]; then
      fail "missing: $name"
    elif [[ $(sha "$engine/$name") != "$want" ]]; then
      fail "changed: $name (vendored files are never edited; fix it in kubb-engine and move to its next tag)"
    fi
  done < <(manifest_files "$engine")
  [[ $count -gt 0 ]] || fail "engine.json names no files"
  # Nothing beside what engine.json names, but its own LICENSE and itself.
  while IFS= read -r f; do
    name=${f#"$engine"/}
    case $name in engine.json | LICENSE) continue ;; esac
    manifest_files "$engine" | grep -q "^$name " || fail "extra: $name (not in engine.json)"
  done < <(find "$engine" -type f | LC_ALL=C sort)
  [[ -s $engine/LICENSE ]] || fail "missing: LICENSE"
  for f in "${golden_files[@]}"; do [[ -s $golden/$f ]] || fail "missing: ${golden#"$fixtures"/}/$f"; done
  if [[ -s $golden/hashes.json ]]; then
    corpus=$(json_version "$golden/hashes.json")
    # A hash-neutral patch ships the exact corpus of the last release that changed
    # hashes (kubb-engine docs/VERSIONING.md "Release notes"): 0.4.1 carries 0.2.0's,
    # 0.5.1 and 0.7.1 to 0.7.4 0.5.0's, 0.8.1 0.8.0's. Arbitrary older corpora are
    # not accepted when moving to another release.
    case $version in
      0.4.1) expected=0.2.0 ;;
      0.5.1 | 0.7.[1-4]) expected=0.5.0 ;;
      0.8.1) expected=0.8.0 ;;
      *) expected=$version ;;
    esac
    [[ $corpus == "$expected" ]] || fail "golden corpus is $corpus, expected $expected; run sync"
  fi
  if [[ $status == 0 ]]; then
    echo "engine $(minor_of "$tag"): kubb-engine $tag, $count files match engine.json, golden corpus recorded by $corpus"
  fi
}

status=0
fail() { echo "$*" >&2; status=1; }

case "${1:-}" in
  sync)
    git -C "$source_dir" rev-parse --git-dir > /dev/null
    rm -rf "$sources/Engines" "$fixtures/engines"
    for tag in "$TAG" ${OLDER[@]+"${OLDER[@]}"}; do sync_one "$tag"; done
    exec "$0" check
    ;;
  check)
    for tag in "$TAG" ${OLDER[@]+"${OLDER[@]}"}; do check_one "$tag"; done
    # One engine per major.minor, and nothing under Engines/ that OLDER does not name.
    pinned=" $(minor_of "$TAG") "
    for tag in ${OLDER[@]+"${OLDER[@]}"}; do pinned+="$(minor_of "$tag") "; done
    for d in "$sources/Engines"/* "$fixtures/engines"/*; do
      [[ -e $d ]] || continue
      [[ $pinned == *" $(basename "$d") "* && $(basename "$d") != "$(minor_of "$TAG")" ]] ||
        fail "unpinned: ${d#"$root"/} (not in OLDER; run sync)"
    done
    exit $status
    ;;
  *)
    echo "usage: scripts/vendor-engine.sh sync | check" >&2
    exit 64
    ;;
esac
