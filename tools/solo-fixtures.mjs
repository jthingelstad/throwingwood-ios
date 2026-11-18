// Synthetic simulator/test checkpoints. The only inputs are the open client's
// engine and this fixed setup. Never use saved or recorded games here.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
const web = resolve(process.argv[2] || "../kubb.thingelstad.xyz");
const { Engine } = await import(pathToFileURL(join(web, "src/engine/index.js")));
const dir = join(web, "vendor/engine");
const manifest = JSON.parse(readFileSync(join(dir, "engine.json")));
const sources = Object.fromEntries(Object.keys(manifest.files).map(p => [
  p.slice(0, -4), readFileSync(join(dir, p), "utf8"),
]));
const out = fileURLToPath(new URL("../ThrowingWoodKit/Tests/KubbRendererTests/Fixtures/solo/", import.meta.url));
mkdirSync(out, { recursive: true });
const match = await Engine.create({ sources, client: "ios review" });
const planner = await Engine.create({ sources, client: "ios review" });
const kept = new Set();
for (let seed = 1001; seed < 1010 && kept.size < 5; seed++) {
  match.newMatch({ seed, first: "A", cpu: "B", raising: "hand", surface: "grass",
    opening: "2-4-6", wind: "off", set: "classic",
    teams: Object.fromEntries([["A","You"],["B","Computer"]].map(([key, name]) =>
      [key, {name, players: [{name, level:"club"}]}])),
    start: {year: 2026, month: 11, day: 17, hour: 12, min: 0} });
  for (let i = 0; i < 2000; i++) {
    const need = match.need();
    const name = need.kind === "throw" ? (need.cpu ? "computer" : "aim") : need.kind;
    if (!kept.has(name)) {
      writeFileSync(join(out, name + ".json"), match.snapshot());
      kept.add(name);
    }
    if (need.kind === "over") break;
    let action;
    if (need.kind === "raise") action = {type:"raise"};
    else if (need.kind === "punish") action = {type:"punish", ...need.cursor};
    else {
      const snapshot = JSON.parse(match.snapshot());
      snapshot.opts.cpu = ["A", "B"];
      planner.restore(JSON.stringify(snapshot));
      for (let f = 0; f < 200 && !action; f++) action = planner.frame({dt:0.1}).action;
    }
    if (!action || !match.apply(action).ok) throw Error("synthetic match stopped");
  }
}
if (kept.size !== 5) throw Error("missing synthetic checkpoint");
match.lua.global.close();
planner.lua.global.close();
