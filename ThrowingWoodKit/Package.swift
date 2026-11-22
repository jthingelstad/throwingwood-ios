// swift-tools-version: 6.0
import PackageDescription

// Flags that keep the engine's floating point the same as the web's
// WebAssembly build (wasmoon: Lua 5.4 and musl's libm, compiled for wasm):
// no fused multiply-add (wasm has none), and no compiler built-ins standing
// in for the library's sin, pow, floor and the rest.
let exactFloatingPoint = ["-ffp-contract=off", "-fno-builtin"]

// Textual headers, not prebuilt modules: a module of Apple's math.h would be
// built without the twm_ names (CMusl/include/twm_names.h) and declare the
// system's sin in place of musl's.
let textualHeaders = ["-fno-modules"]

let package = Package(
  name: "ThrowingWoodKit",
  platforms: [.iOS("26.0"), .macOS("15.0")],
  products: [
    .library(name: "KubbEngine", targets: ["KubbEngine"]),
    .library(name: "KubbRenderer", targets: ["KubbRenderer"]),
    .library(name: "KubbPitch", targets: ["KubbPitch"]),
  ],
  targets: [
    // musl 1.2.5's portable C maths (src/math, not the arch assembly), only
    // the double functions Lua uses. Compiled against musl's own headers and
    // nothing else (-nostdinc), with every symbol renamed twm_* by
    // include/twm_names.h so none of it stands in for Apple's libm elsewhere
    // in the app, and config/twm_musl.h keeps even an unoptimized build off
    // Apple's libm. See NOTICE.md; scripts/check-libm.sh proves it.
    .target(
      name: "CMusl",
      exclude: ["NOTICE.md", "COPYRIGHT"],
      cSettings: [
        .headerSearchPath("musl/arch/aarch64"),
        .headerSearchPath("musl/arch/generic"),
        .headerSearchPath("musl/src/include"),
        .headerSearchPath("musl/src/internal"),
        .headerSearchPath("musl/include"),
        .headerSearchPath("config"),
        .unsafeFlags(
          ["-nostdinc", "-std=c99", "-U__FP_FAST_FMA", "-include", "twm_musl.h", "-w"]
            + exactFloatingPoint + textualHeaders),
      ]
    ),
    // Lua 5.4 at the commit wasmoon 1.16 ships, unedited; config/twl_config.h
    // points its maths at CMusl and fills in what iOS lacks. See NOTICE.md.
    .target(
      name: "CLua",
      dependencies: ["CMusl"],
      exclude: ["NOTICE.md", "LICENSE"],
      cSettings: [
        .define("LUA_USE_POSIX"),
        .headerSearchPath("config"),
        .unsafeFlags(["-include", "twl_config.h", "-w"] + exactFloatingPoint + textualHeaders),
      ]
    ),
    // The game engine: a kubb-engine release (Engine/, vendored byte for
    // byte by scripts/vendor-engine.sh) behind kubbCall. Were an older engine
    // supported again (OLDER in that script), Engines/ would be copied too.
    .target(name: "KubbEngine", dependencies: ["CLua"], resources: [.copy("Engine")]),
    .target(name: "KubbRenderer", dependencies: ["KubbEngine", "KubbPitch"], resources: [.copy("Sounds")]),
    .testTarget(name: "KubbRendererTests", dependencies: ["KubbRenderer"], resources: [.copy("Fixtures")]),
    .target(name: "KubbPitch", dependencies: ["KubbEngine"]),
    .testTarget(
      name: "KubbPitchTests", dependencies: ["KubbPitch"], resources: [.copy("Fixtures")]),
    // kubb-engine's golden matches, played here and compared hash by hash
    // with its corpus from the reference platform (Fixtures/golden/).
    .testTarget(
      name: "KubbEngineTests", dependencies: ["KubbEngine"], resources: [.copy("Fixtures")]),
  ]
)
