// The positions the App Store preview is filmed from (tools/store-previews/*.json):
// three matches against the computer as the app starts them, each in its scene, played
// on from a fixed seed by the engine's own computer player on both sides until the
// moment wanted, and kept as the snapshot the app keeps of a match (solo-match.json).
// The only inputs are this app's vendored engine, the web client's engine host and
// these fixed seeds. Never a saved or recorded game.
//
//   node tools/preview-positions.mjs [<web checkout>]
//
// The web checkout (read only) gives the host, src/engine/index.js, and wasmoon; the
// Lua is this repository's own, the engine the app is built with.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
const web = resolve(process.argv[2] || "../kubb.thingelstad.xyz");
const { Engine } = await import(pathToFileURL(join(web, "src/engine/index.js")));
const dir = fileURLToPath(new URL("../ThrowingWoodKit/Sources/KubbEngine/Engine/", import.meta.url));
const manifest = JSON.parse(readFileSync(join(dir, "engine.json")));
const sources = Object.fromEntries(Object.keys(manifest.files).map(p => [
  p.slice(0, -4), readFileSync(join(dir, p), "utf8"),
]));
const out = fileURLToPath(new URL("store-previews/", import.meta.url));
mkdirSync(out, { recursive: true });
const engine = () => Engine.create({ sources, client: "ios " + manifest.version, location: "throwingwood.com" });
const match = await engine(), planner = await engine();

// name: the scene, the seed, and the throw of side A's to stop at.
const wanted = {
  // the opening throw: two batons at the base kubbs, 8 m
  park: { scene: "day", seed: 1, at: need => need.turn === 1 },
  // six field kubbs in a knot to clear, 5 m, six batons in hand
  techno: { scene: "neon", seed: 10, at: need => need.turn === 15 && need.setup.kind === "baton" && need.setup.n === 1 },
  // every kubb down and batons left: at the king
  camping: { scene: "night", seed: 4, at: need => need.setup.kingShot },
};
for (const [name, { scene, seed, at }] of Object.entries(wanted)) {
  // SoloPitch.startSolo's own `new`: the scene decides the ground and the set
  match.newMatch({
    seed, first: "A", cpu: "B", scene, computer: "club", opening: "2-4-6", raising: "auto", wind: "off",
    teams: {
      A: { name: "Brave Birch", players: [{ name: "Brave Birch" }] },
      B: { name: "Computer", players: [{ name: "Computer" }] },
    },
    start: { year: 2026, month: 11, day: 22, hour: 9, min: 41 },
  });
  let kept = false;
  for (let i = 0; i < 3000 && !kept; i++) {
    const need = match.need();
    if (need.kind === "over") break;
    if (need.kind === "throw" && need.side === "A" && at(need)) {
      const dial = match.view().dial;
      writeFileSync(join(out, name + ".json"), match.snapshot());
      // the swing a throw here wants: the middle of each band, in the dial's degrees
      console.log(name, `turn ${need.turn}, ${need.setup.label}:`,
        `back ${((dial.powerLo + dial.powerHi) / 2).toFixed(1)}, stop ${((dial.releaseLo + dial.releaseHi) / 2).toFixed(1)}`);
      kept = true;
      break;
    }
    let action;
    if (need.kind === "raise") action = { type: "raise" };
    else if (need.kind === "punish") action = { type: "punish", ...need.cursor };
    else {
      // the computer plays this throw, whoever's it is
      const snapshot = JSON.parse(match.snapshot());
      snapshot.opts.cpu = ["A", "B"];
      planner.restore(JSON.stringify(snapshot));
      for (let f = 0; f < 400 && !action; f++) action = planner.frame({ dt: 0.1 }).action;
    }
    if (!action || !match.apply(action).ok) throw Error(`${name}: the synthetic match stopped`);
  }
  if (!kept) throw Error(`${name}: seed ${seed} never reached its position`);
}
match.lua.global.close();
planner.lua.global.close();
