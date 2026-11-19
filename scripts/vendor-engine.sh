#!/bin/bash
# The game engine, vendored from a tagged release of kubb-engine
# (jthingelstad/kubb-engine), byte for byte, as the engine's own docs ask
# (its docs/VERSIONING.md "Releases and vendoring"):
#
#   ThrowingWoodKit/Sources/KubbEngine/Engine/   core/, room/, session/, tune/,
#       version.lua, engine.json (the engine's manifest: its version and a
#       sha256 for every Lua file) and LICENSE
#   ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/golden/   the engine's
#       golden driver and corpus (tests/golden/drive.lua and hashes.json),
#       the hashes its reference platform gives, which the tests must match
#
#   scripts/vendor-engine.sh sync    copy them from the kubb-engine checkout
#                                    beside this repo, at TAG (the tag's tree,
#                                    never the working tree; the checkout is
#                                    only read)
#   scripts/vendor-engine.sh check   the vendored copy is the release TAG
#                                    names: every Lua file as engine.json
#                                    says, byte for byte, no file missing or
#                                    extra, the corpus recorded by this engine
#                                    version or an earlier one (a hash-neutral
#                                    release keeps its corpus: 0.4.1 carries
#                                    0.2.0's, kubb-engine docs/VERSIONING.md).
#                                    Needs no kubb-engine checkout (CI runs it)
#
# To move to a new release: change TAG, run sync, then the tests (AGENTS.md).
set -euo pipefail

# The kubb-engine release this app runs.
TAG=v0.5.1

root=$(cd "$(dirname "$0")/.." && pwd)
source_dir=${KUBB_ENGINE_SOURCE:-$root/../kubb-engine}
engine=$root/ThrowingWoodKit/Sources/KubbEngine/Engine
golden=$root/ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/golden

# What is copied: engine paths into Engine/, test paths into Fixtures/golden/.
engine_paths=(core room session tune version.lua engine.json LICENSE)
golden_files=(drive.lua hashes.json)

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

# engine.json's "files" map as "<path> <sha256>" lines (it is written one
# entry a line by the engine's tools/manifest.mjs).
manifest_files() {
  sed -nE '/^  "files": \{/,/^  \}/s/^ *"([^"]+\.lua)": "([0-9a-f]{64})",?$/\1 \2/p' "$engine/engine.json"
}

json_version() {
  sed -nE 's/^ *"version": "([^"]+)",?$/\1/p' "$1" | head -1
}

case "${1:-}" in
  sync)
    git -C "$source_dir" rev-parse --git-dir > /dev/null
    commit=$(git -C "$source_dir" rev-parse --verify --quiet "$TAG^{commit}") || {
      echo "$source_dir has no tag $TAG; fetch its tags first (git -C $source_dir fetch --tags)." >&2
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
    echo "vendored kubb-engine $TAG (${commit:0:7}): $count files, and the golden driver and corpus"
    exec "$0" check
    ;;
  check)
    status=0
    fail() { echo "$*" >&2; status=1; }
    [[ -f $engine/engine.json ]] || { echo "no $engine/engine.json; run sync" >&2; exit 1; }
    version=$(json_version "$engine/engine.json")
    [[ "v$version" == "$TAG" ]] || fail "engine.json is version $version, TAG is $TAG; run sync"
    count=0
    while read -r name want; do
      count=$((count + 1))
      if [[ ! -f $engine/$name ]]; then
        fail "missing: $name"
      elif [[ $(sha "$engine/$name") != "$want" ]]; then
        fail "changed: $name (vendored files are never edited; fix it in kubb-engine and move to its next tag)"
      fi
    done < <(manifest_files)
    [[ $count -gt 0 ]] || fail "engine.json names no files"
    # Nothing beside what engine.json names, but its own LICENSE and itself.
    while IFS= read -r f; do
      name=${f#"$engine"/}
      case $name in engine.json | LICENSE) continue ;; esac
      manifest_files | grep -q "^$name " || fail "extra: $name (not in engine.json)"
    done < <(find "$engine" -type f | LC_ALL=C sort)
    [[ -s $engine/LICENSE ]] || fail "missing: LICENSE"
    for f in "${golden_files[@]}"; do [[ -s $golden/$f ]] || fail "missing: Fixtures/golden/$f"; done
    if [[ -s $golden/hashes.json ]]; then
      corpus=$(json_version "$golden/hashes.json")
      # 0.4.1 is explicitly hash-neutral and ships 0.2.0's exact corpus.
      # Do not accept arbitrary older corpora when moving to another release.
      expected=$version
      [[ $version == 0.4.1 ]] && expected=0.2.0
      [[ $version == 0.5.1 ]] && expected=0.5.0
      [[ $corpus == "$expected" ]] || fail "golden corpus is $corpus, expected $expected; run sync"
    fi
    [[ $status == 0 ]] && echo "engine: kubb-engine $TAG, $count files match engine.json, golden corpus recorded by $corpus"
    exit $status
    ;;
  *)
    echo "usage: scripts/vendor-engine.sh sync | check" >&2
    exit 64
    ;;
esac
