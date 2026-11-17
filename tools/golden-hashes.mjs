// Writes ThrowingWoodKit/Tests/KubbEngineTests/Fixtures/golden-hashes.json:
// what the web's own engine (wasmoon: Lua 5.4 and musl's libm compiled to
// WebAssembly) gives for the driver's seeded matches, the recorded replay and
// the maths probe. KubbEngineTests plays the same driver natively and must
// get every hash identical.
//
//   node tools/golden-hashes.mjs
//
// The engine is this repo's vendored copy (Sources/KubbEngine/Engine), so the
// hashes are for exactly the Lua the app ships. wasmoon comes from the web
// checkout's node_modules (read only; `npm ci` there first). KUBB_WEB names
// that checkout; the default is the one beside this repo.
import fs from "node:fs";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const web = path.resolve(process.env.KUBB_WEB ?? path.join(root, "..", "kubb.thingelstad.xyz"));
const engineDir = path.join(root, "ThrowingWoodKit/Sources/KubbEngine/Engine");
const fixtures = path.join(root, "ThrowingWoodKit/Tests/KubbEngineTests/Fixtures");

const require = createRequire(path.join(web, "package.json"));
const wasmoonPath = require.resolve("wasmoon");
const wasmoonVersion = JSON.parse(
  fs.readFileSync(path.join(path.dirname(wasmoonPath), "..", "package.json"), "utf8"),
).version;
const { LuaFactory } = await import(pathToFileURL(wasmoonPath).href);

// The engine's modules, keyed as the web's bundle keys them.
const sources = {};
for (const dir of ["core", "web"])
  for (const f of fs.readdirSync(path.join(engineDir, dir)).filter((f) => f.endsWith(".lua")).sort())
    sources[`${dir}/${f.slice(0, -4)}`] = fs.readFileSync(path.join(engineDir, dir, f), "utf8");
sources["test/drive"] = fs.readFileSync(path.join(fixtures, "drive.lua"), "utf8");
const manifest = JSON.parse(fs.readFileSync(path.join(engineDir, "engine.json"), "utf8"));

// The web's boot (src/engine/index.js), then the driver.
const BOOT = `
local imported = {}
function import(name)
  name = name:gsub("%.lua$", "")
  if imported[name] then return nil end
  imported[name] = true
  local s = __kubbSource(name)
  if not s then error("import: no module " .. name, 2) end
  return assert(load(s, "@" .. name))()
end
import "web/api"
import "test/drive"
`;

async function engine() {
  const lua = await new LuaFactory().createEngine();
  lua.global.set("__kubbSource", (name) => (Object.hasOwn(sources, name) ? sources[name] : null));
  await lua.doString(BOOT);
  return lua;
}

const lua = await engine();
const version = await lua.doString("return _VERSION");
const run = (fn, arg) => JSON.parse(lua.global.get(fn)(JSON.stringify(arg)));

// Twelve matches: every surface with every wind, both teams first, one to
// three players a side, both openings.
const SURFACES = ["grass", "sand", "snow"];
const WINDS = ["off", "light", "strong"];
const matches = [];
for (let i = 0; i < 12; i++) {
  const players = (i % 3) + 1;
  const team = (name) => ({
    name,
    players: Array.from({ length: players }, (_, k) => ({ name: `${name} ${k + 1}` })),
  });
  const opts = {
    seed: 1000 + 37 * i,
    surface: SURFACES[i % 3],
    wind: WINDS[Math.floor(i / 3) % 3],
    first: i % 2 === 0 ? "A" : "B",
    opening: i % 4 === 3 ? "six" : "2-4-6",
    teams: { A: team("North"), B: team("South") },
    start: { year: 2026, month: 11, day: 17, hour: 12, min: 0 },
    maxTurns: 8,
  };
  const t = performance.now();
  const r = run("driveMatch", opts);
  const ms = performance.now() - t;
  const throws = r.actions.filter((a) => a[0] === "throw").length;
  console.log(`match ${i + 1}: ${r.actions.length} actions (${throws} throws), ${(ms / 1000).toFixed(1)} s`);
  matches.push({ opts, start: r.start, actions: r.actions });
}

// The web's recorded match, played again.
const replayName = "replay-north-south.json";
const replayText = fs.readFileSync(path.join(web, "tests/fixtures", replayName), "utf8");
fs.writeFileSync(path.join(fixtures, replayName), replayText);
const replayOut = run("driveReplay", JSON.parse(replayText));
console.log(`replay: ${replayOut.hashes.length} actions, differs from its recording: ${replayOut.differs}`);

// Arguments where Apple's libm and musl's differ in the last bit (found by
// comparing them on a Mac): the engine must give musl's answer.
const probe = [
  ["sin", "0x401c3109cc6e044a"], ["sin", "0x4020cb95554ff503"],
  ["cos", "0x40100f1d5b921536"], ["cos", "0x40028fb4c919b20f"],
  ["tan", "0xbfe0e20d2ae4dc35"], ["tan", "0xbff5203985c2892a"],
  ["atan", "0xbfd67c8bd67dc3a2", "0x3fcdf2e1af4b8e08"], ["atan", "0x3fd271f336b1a79e", "0xbf9361926b77aae0"],
  ["asin", "0x3fe2ba7ac11778c0"], ["asin", "0x3fe6f8621d50bc66"],
  ["acos", "0x3fd3f0ec65c76e94"], ["acos", "0xbfad44de732c0980"],
  ["exp", "0xc00d99c7946a6a22"], ["exp", "0x3fefa1c832fbd52c"],
  ["log", "0x40441263da2dd37e"], ["log", "0x401392bdd1e0ead1"],
  ["log2", "0x4049bee6a6bf82cf"], ["log2", "0x3ff0a26a867ed7c4"],
  ["log10", "0x4055a5e84b89572f"], ["log10", "0x4056856525ab9de6"],
  ["pow", "0x3ff0701b319947e3", "0xbfeb923b02dcbb7c"], ["pow", "0x400aeabbab81728b", "0xc00415abc38d62e3"],
];
const probeOut = run("mathProbe", probe);

const golden = {
  about:
    "Written by tools/golden-hashes.mjs from the web's WebAssembly engine. Never edit by hand; run the tool again after vendoring a new engine.",
  wasmoon: wasmoonVersion,
  lua: version,
  engine: { source: manifest.source, commit: manifest.commit },
  matches,
  replay: { file: replayName, start: replayOut.start, hashes: replayOut.hashes, differs: replayOut.differs },
  math: probe.map((c, i) => ({ fn: c[0], args: c.slice(1), bits: probeOut[i] })),
};
fs.writeFileSync(path.join(fixtures, "golden-hashes.json"), JSON.stringify(golden, null, 1) + "\n");
const actions = matches.reduce((n, m) => n + m.actions.length, 0);
console.log(`golden-hashes.json: ${matches.length} matches, ${actions} actions, wasmoon ${wasmoonVersion}, ${version}`);
