# musl's maths

The double-precision maths of musl 1.2.5, the C library inside wasmoon's
WebAssembly build of Lua, so the engine's floats on a phone are the web's to
the last bit (Apple's libm differs from musl's by one unit in the last place
in sin, cos, tan, atan2, pow and others, and a throw's physics amplifies it).
From `https://musl.libc.org/releases/musl-1.2.5.tar.gz` (SHA-256
`a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4`).
Copyright Rich Felker et al., Sun Microsystems and Arm, under the MIT-style
terms in `COPYRIGHT`.

## What is here

`scripts/vendor-c.sh` copies, unedited:

- `musl/src/math/`: the portable C (never `src/math/aarch64` or other
  assembly) of every function Lua calls (`acos asin atan2 ceil cos exp fabs
  floor fmod frexp ldexp log log10 log2 pow sin sqrt tan`) and of what those
  call (`atan scalbn`, the `__sin`/`__cos`/`__tan` kernels, `__rem_pio2`,
  the `__math_*` error helpers and the exp, log, log2, pow and sqrt tables).
- the headers they include: `musl/include`, `musl/src/include`,
  `musl/src/internal/libm.h`, aarch64's `bits/float.h` and `bits/stdint.h`,
  and `bits/alltypes.h` generated with musl's `tools/mkalltypes.sed`.
- `musl/arch/generic/fp_arch.h`, the portable compiler barrier, in place of
  aarch64's inline-asm one, so the same files build for every simulator
  architecture. A barrier only stops the compiler folding; no value changes.

The long-double limits in aarch64's `bits/float.h` are not Apple's, but no
file here uses long double.

## How it is built and kept apart

- `-nostdinc`: compiled against musl's headers and nothing else.
- `-std=c99 -ffp-contract=off -U__FP_FAST_FMA -fno-builtin`: no fused
  multiply-add (WebAssembly has none) and no compiler built-ins in place of
  the code.
- `-include twm_names.h` (`include/twm_names.h`) renames every symbol these
  files define to `twm_*`; Lua is compiled with the same header, so its
  `sin` is `twm_sin`. Nothing in the app is linked to musl under Apple's
  names, and Swift, Foundation and the frameworks keep Apple's libm.
  `nm` on the objects shows only `twm_*` defined. A Debug (-O0) build keeps
  one reference outside the list, `__fpclassifyl`, from a branch of musl's
  `isnan` that is never taken for a double; it resolves to Apple's.

KubbEngineTests proves the result: probe arguments where the two libms
differ give musl's bits, and seeded matches hash as the web's do.
