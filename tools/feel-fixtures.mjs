// Record invented practice throws under the web VM using this app's pinned Lua.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { pathToFileURL, fileURLToPath } from "node:url";
const root = fileURLToPath(new URL("../", import.meta.url));
const web = resolve(process.argv[2] ?? "../kubb.thingelstad.xyz");
const { Engine } = await import(pathToFileURL(join(web, "src/engine/index.js")));
const dir = join(root, "ThrowingWoodKit/Sources/KubbEngine/Engine");
const manifest = JSON.parse(readFileSync(join(dir, "engine.json")));
const sources = Object.fromEntries(Object.keys(manifest.files).map(p => [
  p.slice(0, -4), readFileSync(join(dir, p), "utf8"),
]));
const engine = await Engine.create({ sources });
const output = join(root, "ThrowingWoodKit/Tests/KubbRendererTests/Fixtures/feel");
mkdirSync(output, { recursive: true });
await engine.lua.doString(`
  function recordFeel(name, surface)
    local s = tw.web.session.new {mode = "practice", surface = surface}
    local t, json = tw.web.throw, tw.web.json
    if name == "multi" then
      for _, it in ipairs(s.ts.items) do
        if it.id == "b2" then it.x, it.y = 0, 8.10 end
      end
    end
    if name == "miss" then s:setTarget(0.62, 5.0)
    elseif name == "king" then s:setTarget(0, 4, true) end
    local swing = {}
    for k, v in pairs(t.CLEAN) do swing[k] = v end
    s.ts.nerves = false
    swing.back, swing.releaseAngle = s.ts.sol.back, s.ts.sol.release
    local launch, how = t.playerLaunch(s.ts, swing)
    local action = json.decode(json.encode(s:throwAction(launch, how, {})))
    local recording = s:apply(action).recording
    return json.encode({action = action, timeline = recording.timeline, duration = recording.duration,
      projectile = recording.projectile, down = recording.result.down})
  end
`);
const record = engine.lua.global.get("recordFeel");
for (const [kind, surface] of [["clean", "grass"], ["multi", "grass"], ["king", "grass"],
  ...["grass", "sand", "snow"].map(s => ["miss", s])]) {
  const data = JSON.parse(record(kind, surface));
  if (kind === "multi" && data.down < 2) throw Error("expected a double");
  if (kind === "miss" && data.timeline.contacts.length) throw Error("expected clear ground");
  writeFileSync(join(output, (kind === "miss" ? "miss-" + surface : kind) + ".json"), JSON.stringify(data, null, 2) + "\n");
}
engine.lua.global.close();
