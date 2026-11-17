# Throwing Wood for iPhone

Kubb: Throwing Wood for iPhone. Kubb is the Swedish lawn game of throwing
wooden batons at wooden blocks. Throwing Wood began on the Playdate and plays
in a browser at [throwingwood.com](https://throwingwood.com); this is the
iPhone version.

## What's here

So far, the foundation: the game engine running natively, and a placeholder
screen that shows it loaded, its match hash, and a button that lets the
computer throw.

- `ThrowingWoodKit/` is a Swift package. `KubbEngine` runs the game engine,
  a tagged release of [kubb-engine](https://github.com/jthingelstad/kubb-engine)
  (the same Lua the Playdate and web versions run), in Lua 5.4, with musl's
  math library compiled in so every result matches the web's WebAssembly
  engine to the last bit. Its tests play the engine's golden matches and
  check every hash against the engine's own corpus.
- `ThrowingWood/` is the SwiftUI app (iOS 26, iPhone).
- `scripts/` vendors the engine and the C sources, checks the C never calls
  Apple's libm, stamps the version, and uploads to TestFlight.

## The engine

The release the app runs is `TAG` in `scripts/vendor-engine.sh`. To move to
another, change it, run `scripts/vendor-engine.sh sync` (it reads the
kubb-engine checkout beside this one, at that tag), then run the tests.

## Building

Xcode 26. Open `ThrowingWood.xcodeproj`, or run the tests headless:

```sh
swift test --package-path ThrowingWoodKit
```

To sign a device build, put `DEVELOPMENT_TEAM = <team id>` in
`Config/Signing.local.xcconfig` (ignored by git).

## Licenses

The app is MIT (`LICENSE`). Lua is MIT (`ThrowingWoodKit/Sources/CLua/LICENSE`)
and musl is MIT (`ThrowingWoodKit/Sources/CMusl/COPYRIGHT`); each has a
`NOTICE.md` saying what was taken and how it was changed.
