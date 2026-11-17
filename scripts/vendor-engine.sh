#!/bin/bash
# The game engine's Lua, vendored into ThrowingWoodKit as resources: the same
# modules the web bundles (tools/lua-bundle.mjs in kubb.thingelstad.xyz):
# its vendor/core/*.lua as core/<name> and its lua/web/*.lua as web/<name>.
#
#   scripts/vendor-engine.sh sync    copy them from the source checkout at its
#                                    HEAD and write engine.json (commit and
#                                    sha256 of every file)
#   scripts/vendor-engine.sh check   the vendored files are the ones engine.json
#                                    names, byte for byte (CI runs this)
#
# The source checkout is only read, never written. It must be clean in the
# folders copied, so engine.json's commit is exactly what was copied.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)

# Where the engine comes from: the web's checkout beside this one, for now.
# (It moves to tagged releases of kubb-engine; only this line changes.)
source_dir=${KUBB_ENGINE_SOURCE:-$root/../kubb.thingelstad.xyz}

engine=$root/ThrowingWoodKit/Sources/KubbEngine/Engine
manifest=$engine/engine.json
dirs=("core:vendor/core" "web:lua/web")

sha() { shasum -a 256 "$1" | cut -d' ' -f1; }

case "${1:-}" in
  sync)
    git -C "$source_dir" rev-parse --git-dir > /dev/null
    paths=()
    for d in "${dirs[@]}"; do paths+=("${d#*:}"); done
    if [[ -n $(git -C "$source_dir" status --porcelain -- "${paths[@]}") ]]; then
      echo "$source_dir has changes in ${paths[*]}; commit or stash them first." >&2
      exit 1
    fi
    commit=$(git -C "$source_dir" rev-parse HEAD)
    rm -rf "$engine"
    mkdir -p "$engine"
    entries=()
    for d in "${dirs[@]}"; do
      prefix=${d%%:*} from=${d#*:}
      mkdir -p "$engine/$prefix"
      for f in "$source_dir/$from"/*.lua; do
        cp "$f" "$engine/$prefix/"
        entries+=("$prefix/$(basename "$f")")
      done
    done
    {
      echo "{"
      echo "  \"source\": \"jthingelstad/kubb.thingelstad.xyz\","
      echo "  \"commit\": \"$commit\","
      echo "  \"files\": {"
      n=${#entries[@]} i=0
      for e in $(printf '%s\n' "${entries[@]}" | LC_ALL=C sort); do
        i=$((i + 1))
        sep=","; [[ $i == "$n" ]] && sep=""
        echo "    \"$e\": \"$(sha "$engine/$e")\"$sep"
      done
      echo "  }"
      echo "}"
    } > "$manifest"
    echo "vendored ${#entries[@]} modules from ${commit:0:7}"
    ;;
  check)
    status=0 count=0
    while IFS= read -r line; do
      name=$(sed -E 's/^ *"([^"]+)": "([0-9a-f]{64})",?$/\1/' <<< "$line")
      want=$(sed -E 's/^ *"([^"]+)": "([0-9a-f]{64})",?$/\2/' <<< "$line")
      count=$((count + 1))
      if [[ ! -f $engine/$name ]]; then
        echo "missing: $name" >&2; status=1
      elif [[ $(sha "$engine/$name") != "$want" ]]; then
        echo "changed: $name (vendored files are never edited; sync instead)" >&2; status=1
      fi
    done < <(grep -E '^ *"[a-z]+/[^"]+\.lua": "[0-9a-f]{64}",?$' "$manifest")
    actual=$(find "$engine/core" "$engine/web" -name '*.lua' | wc -l | tr -d ' ')
    if [[ $actual != "$count" ]]; then
      echo "engine.json names $count files, Engine/ has $actual" >&2; status=1
    fi
    [[ $status == 0 ]] && echo "engine: $count files match engine.json ($(sed -nE 's/^ *"commit": "([0-9a-f]{7}).*/\1/p' "$manifest"))"
    exit $status
    ;;
  *)
    echo "usage: scripts/vendor-engine.sh sync | check" >&2
    exit 64
    ;;
esac
