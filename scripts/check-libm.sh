#!/bin/bash
# The engine's C never calls Apple's libm: every maths function CLua and CMusl
# reference is musl's, renamed twm_* (ThrowingWoodKit/Sources/CMusl/NOTICE.md).
# Builds both C targets in Debug and release and fails if either object
# references a symbol that Apple's libm (the SDK's libsystem_m) exports, or if
# CMusl defines any global symbol without the twm_ prefix.
#
#   scripts/check-libm.sh            build, then check (CI runs it)
#   scripts/check-libm.sh --no-build check what the last builds left
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
kit=$root/ThrowingWoodKit
build=1
[[ ${1:-} == --no-build ]] && build=0

# Every name Apple's libm exports, from the SDK's text stub.
tbd=$(xcrun --sdk macosx --show-sdk-path)/usr/lib/system/libsystem_m.tbd
libm=$(grep -oE "'?_[A-Za-z0-9_]+'?" "$tbd" | tr -d "'" | LC_ALL=C sort -u)
[[ $(wc -l <<< "$libm") -gt 100 ]] || { echo "could not read libm's symbols from $tbd" >&2; exit 1; }

# A target's object for a configuration, from either SwiftPM build system.
object() { # <target> <debug|release>
  local cfg=$2 cap
  cap=$(tr '[:lower:]' '[:upper:]' <<< "${cfg:0:1}")${cfg:1}
  local merged=$kit/.build/out/Products/$cap/$1.o
  if [[ -f $merged ]]; then echo "$merged"; return; fi
  ls "$kit"/.build/"$cfg"/"$1".build/*.o 2> /dev/null || true
}

status=0
for cfg in debug release; do
  if [[ $build == 1 ]]; then
    swift build --package-path "$kit" -c "$cfg" --target CLua > /dev/null
  fi
  for target in CMusl CLua; do
    objs=$(object "$target" "$cfg")
    [[ -n $objs ]] || { echo "$cfg: no $target objects; build first" >&2; status=1; continue; }
    # shellcheck disable=SC2086
    bad=$(nm -u $objs 2> /dev/null | grep -E '^_' | LC_ALL=C sort -u | LC_ALL=C comm -12 - <(echo "$libm") || true)
    if [[ -n $bad ]]; then
      echo "$cfg $target references Apple's libm: $(tr '\n' ' ' <<< "$bad")" >&2
      status=1
    fi
    if [[ $target == CMusl ]]; then
      # shellcheck disable=SC2086
      loose=$(nm -g -U -j $objs 2> /dev/null | grep -E '^_' | grep -v '^_twm_' | LC_ALL=C sort -u || true)
      if [[ -n $loose ]]; then
        echo "$cfg CMusl defines names without twm_: $(tr '\n' ' ' <<< "$loose")" >&2
        status=1
      fi
    fi
  done
done
[[ $status == 0 ]] && echo "libm: CLua and CMusl reference none of Apple's libm, Debug and release"
exit $status
