/*
 * The engine's maths, named apart from the system's.
 *
 * Every function and table that ThrowingWoodKit's musl files define, and
 * every one Lua calls from them, gets a twm_ prefix. The musl files and the
 * Lua files are both compiled with this header included first
 * (`-include twm_names.h`), so Lua's sin() is musl's twm_sin, while the rest
 * of the app, Swift and Apple's frameworks included, keeps calling Apple's
 * libm under the plain names. Nothing here is visible to code that does not
 * include this header.
 *
 * The list is every external symbol of the vendored musl files
 * (scripts/vendor-c.sh). Adding a musl file means adding its names here.
 */
#ifndef TWM_NAMES_H
#define TWM_NAMES_H

/* What Lua calls (lmathlib, lvm, lobject, ltable, lstrlib). */
#define acos twm_acos
#define asin twm_asin
#define atan twm_atan
#define atan2 twm_atan2
#define ceil twm_ceil
#define cos twm_cos
#define exp twm_exp
#define fabs twm_fabs
#define floor twm_floor
#define fmod twm_fmod
#define frexp twm_frexp
#define ldexp twm_ldexp
#define log twm_log
#define log10 twm_log10
#define log2 twm_log2
#define pow twm_pow
#define scalbn twm_scalbn
#define sin twm_sin
#define sqrt twm_sqrt
#define tan twm_tan

/* musl's own helpers and tables. */
#define __cos twm___cos
#define __sin twm___sin
#define __tan twm___tan
#define __rem_pio2 twm___rem_pio2
#define __rem_pio2_large twm___rem_pio2_large
#define __math_divzero twm___math_divzero
#define __math_invalid twm___math_invalid
#define __math_oflow twm___math_oflow
#define __math_uflow twm___math_uflow
#define __math_xflow twm___math_xflow
#define __exp_data twm___exp_data
#define __log_data twm___log_data
#define __log2_data twm___log2_data
#define __pow_log_data twm___pow_log_data
#define __rsqrt_tab twm___rsqrt_tab

#endif
