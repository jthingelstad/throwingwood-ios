/*
 * Included before every musl file (`-include twm_musl.h`, Package.swift), and
 * only those: the renames (twm_names.h), plus a long double classifier of our
 * own so no build references Apple's libm.
 *
 * musl's math.h picks a classifier by the argument's size: isnan(x) and the
 * rest call __fpclassifyl(x) when x is neither a float nor a double. Every
 * musl file here classifies doubles, so that branch is never taken, but an
 * unoptimized (-O0) build still emits the call, and it would resolve to
 * Apple's libm. Renamed, it is this static function, which the compiler
 * expands inline (no library call) and which answers in musl's FP_* numbers,
 * the ones math.h compares it with. A later declaration in math.h,
 * `int __fpclassifyl(long double)`, takes this one's internal linkage.
 */
#ifndef TWM_MUSL_H
#define TWM_MUSL_H

#include "twm_names.h"

#define __fpclassifyl twm___fpclassifyl

/* musl's include/math.h: FP_NAN 0, FP_INFINITE 1, FP_ZERO 2, FP_SUBNORMAL 3,
 * FP_NORMAL 4. __builtin_fpclassify takes them in the order NaN, infinite,
 * normal, subnormal, zero. */
static int twm___fpclassifyl(long double x) {
  return __builtin_fpclassify(0, 1, 4, 3, 2, x);
}

#endif
