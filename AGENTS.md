# Throwing Wood for iPhone: agent guide

Kubb: Throwing Wood for iPhone. The game itself is the Lua core of
[playdate-kubb](https://github.com/jthingelstad/playdate-kubb), run here the way
the web version (kubb.thingelstad.xyz, https://throwingwood.com) runs it.
`README.md` is the overview for people; this file is the working rules.

`CLAUDE.md` is a symlink to this file. Do not fork them.

## Rules

- **Private, kept clean as if public.** Never commit a team id, an email,
  a local path, keys or signing files. `Config/Signing.local.xcconfig` and
  `Config/AppStoreConnect.local` are ignored by git.
- **Pull requests only** after the first commit. Codex reviews each one.
- **Every upload is Jamie's call.** `scripts/testflight.sh` and
  `scripts/asc.swift` are here for that day; don't run them without Jamie's go.
  Never install to a physical iPhone without it either.
- No third-party Swift packages. No `withTaskGroup` (the optimizer has broken
  one in a sibling app). No analytics.
- Shut the simulators down when done: `xcrun simctl shutdown all`.

## The engine must match the web's, bit for bit

A match on a phone and one in a browser are the same match only if every hash
agrees. So:

- **Lua 5.4.5** (lua/lua at be908a7d, wasmoon 1.16's Lua) in `CLua`, with
  `config/twl_config.h` force-included: a fixed `luai_makeseed`, `system()`
  stubbed (iOS forbids it), and every libm name renamed to musl's.
- **musl 1.2.5's math** in `CMusl`, never Apple's libm: the web's WebAssembly
  uses musl, and Apple's differs in the last bit on some arguments. Each
  public and internal musl symbol is renamed `twm_*` (`include/twm_names.h`,
  force-included in both C targets), so nothing clashes with or falls back to
  Apple's. Both targets build with `-ffp-contract=off -fno-builtin` (no fused
  multiply-add, no compiler-folded maths) and `-fno-modules` (the Darwin
  module map would bring Apple's `math.h` and skip the renames). Don't drop
  any of these flags. `nm` on the objects should show no unprefixed libm call.
- Update Lua or musl only with `scripts/vendor-c.sh <lua dir> <musl dir>`, and
  record the source and its sha256 in the target's `NOTICE.md`.
- **The game's Lua** is vendored from the web checkout's `vendor/core/` and
  `lua/web/` into `ThrowingWoodKit/Sources/KubbEngine/Engine/` by
  `scripts/vendor-engine.sh sync` (it writes `engine.json`; `check` runs in
  CI). Fix behaviour in playdate-kubb, sync it to the web, then here. Never
  edit the vendored files, and never write in the web checkout from here.
- **Golden hashes.** After every engine sync run
  `node tools/golden-hashes.mjs`: it plays `Tests/KubbEngineTests/Fixtures/drive.lua`
  in the web's own wasmoon (its `node_modules`, read only) and writes
  `golden-hashes.json`. The Swift tests must then give every hash
  identically. A golden test that fails is a determinism bug, never a
  fixture to regenerate around.

## Testing

- `swift test --package-path ThrowingWoodKit`, and optimized:
  `swift test -c release -Xswiftc -enable-testing --package-path ThrowingWoodKit`.
- On the simulator: `cd ThrowingWoodKit && xcodebuild test -scheme ThrowingWoodKit
  -destination 'platform=iOS Simulator,name=iPhone 17'`.
- The app: `xcodebuild -project ThrowingWood.xcodeproj -scheme ThrowingWood
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build`.
- CI (`.github/workflows/test.yml`) runs these on `macos-26`. macOS minutes
  cost money on a private repo: add jobs only for a reason.
