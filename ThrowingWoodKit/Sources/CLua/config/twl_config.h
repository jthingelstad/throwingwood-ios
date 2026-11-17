/*
 * Included before every Lua C file (`-include twl_config.h`, Package.swift).
 * Nothing in the vendored Lua sources is edited; what differs on iOS is here.
 */
#ifndef TWL_CONFIG_H
#define TWL_CONFIG_H

/* Lua's maths is musl's (CMusl/include/twm_names.h). TWL_APPLE_LIBM is
 * only for the manual proof in AGENTS.md ("Proving Apple's libm fails"): a
 * build with Lua on Apple's libm, which must fail the golden tests. Never
 * define it in a build anyone plays. */
#ifndef TWL_APPLE_LIBM
#include "twm_names.h"
#endif

/* iOS has no system(); os.execute says there is no shell, as Lua's own
 * iOS build does in later releases. The engine never calls it. */
#include <stdlib.h>
#define system(cmd) ((cmd) == NULL ? 0 : -1)

/* A fixed string-hash seed instead of one from the clock and the heap's
 * addresses, so every run lays out its tables the same way and a match
 * replays the same on every launch. */
#define luai_makeseed(L) ((unsigned int)0x2a)

#endif
