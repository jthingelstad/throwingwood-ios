#!/bin/bash
# Copies the C the engine runs on into ThrowingWoodKit, from upstream
# sources unpacked by hand (ThrowingWoodKit/Sources/CLua/NOTICE.md and
# CMusl/NOTICE.md name the exact commit, release and checksums):
#
#   scripts/vendor-c.sh <lua checkout or archive dir> <musl-1.2.5 dir>
#
# Lua: the C sources and headers of the core and the standard libraries
# (not lua.c, luac.c, onelua.c or ltests). musl: only the double-precision
# functions Lua calls (math.*, ^, %, floor, frexp for float keys) and what
# they call, plus the headers they include. Nothing is edited; bits/alltypes.h
# is generated the way musl's Makefile does it.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
lua=${1:?the Lua source dir}
musl=${2:?the musl source dir}

# Lua
clua=$root/ThrowingWoodKit/Sources/CLua
rm -rf "$clua/lua" "$clua/include/lua.h" "$clua/include/luaconf.h" "$clua/include/lualib.h" "$clua/include/lauxlib.h"
mkdir -p "$clua/lua" "$clua/include"
for f in "$lua"/*.c "$lua"/*.h; do
  case $(basename "$f") in
    lua.c | luac.c | onelua.c | ltests.c | ltests.h) ;;
    lua.h | luaconf.h | lualib.h | lauxlib.h) cp "$f" "$clua/include/" ;;
    *) cp "$f" "$clua/lua/" ;;
  esac
done

# musl
cmusl=$root/ThrowingWoodKit/Sources/CMusl
rm -rf "$cmusl/musl"
m=$cmusl/musl
mkdir -p "$m/src/math" "$m/src/include" "$m/src/internal" "$m/include" "$m/arch/aarch64/bits" "$m/arch/generic"
functions="acos asin atan atan2 ceil cos exp fabs floor fmod frexp ldexp log log10 log2 pow scalbn sin sqrt tan
  __cos __sin __tan __rem_pio2 __rem_pio2_large __math_divzero __math_invalid __math_oflow __math_uflow __math_xflow
  exp_data log_data log2_data pow_data sqrt_data"
for f in $functions; do cp "$musl/src/math/$f.c" "$m/src/math/"; done
for f in exp_data log_data log2_data pow_data sqrt_data; do cp "$musl/src/math/$f.h" "$m/src/math/"; done
cp "$musl/src/internal/libm.h" "$m/src/internal/"
cp "$musl/src/include/features.h" "$m/src/include/"
for f in endian.h features.h float.h math.h stdint.h; do cp "$musl/include/$f" "$m/include/"; done
cp "$musl/arch/aarch64/bits/float.h" "$musl/arch/aarch64/bits/stdint.h" "$m/arch/aarch64/bits/"
sed -f "$musl/tools/mkalltypes.sed" "$musl/arch/aarch64/bits/alltypes.h.in" "$musl/include/alltypes.h.in" \
  > "$m/arch/aarch64/bits/alltypes.h"
# The generic barrier (a volatile store), not aarch64's inline asm, so the
# same files build for every simulator architecture. Neither changes a value.
cp "$musl/arch/generic/fp_arch.h" "$m/arch/generic/"
cp "$musl/COPYRIGHT" "$cmusl/COPYRIGHT"
echo "vendored Lua ($(ls "$clua/lua"/*.c | wc -l | tr -d ' ') C files) and musl ($(ls "$m/src/math"/*.c | wc -l | tr -d ' ') C files)"
