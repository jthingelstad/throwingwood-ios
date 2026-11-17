# Lua

Lua 5.4 as wasmoon 1.16 builds it for the web: the `lua/lua` repository at
commit `be908a7d4d8130264ad67c5789169769f824c5d1` (it reports 5.4.5), from
`https://github.com/lua/lua/archive/be908a7d4d8130264ad67c5789169769f824c5d1.tar.gz`
(SHA-256 `80387000ef85581b5ac9937d6eea7345e8483e843a3f729fb7ad5a17101b416f`).
Copyright Lua.org, PUC-Rio, under the MIT licence in `LICENSE`.

`lua/` and the four headers in `include/` are the upstream files, unedited
(`scripts/vendor-c.sh` copies them; `lua.c`, `luac.c`, `onelua.c` and the
test library are left out). What differs here is in `config/twl_config.h`,
included before every file:

- Lua's maths calls are musl's, renamed `twm_*` (`../CMusl/NOTICE.md`).
- `os.execute` reports no shell: iOS has no `system()`.
- The string-hash seed is a constant, not the clock and heap addresses.

`Package.swift` compiles it with `-ffp-contract=off -fno-builtin
-fno-modules` and `LUA_USE_POSIX`.
