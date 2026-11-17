// Run from the iOS worktree. All engine sessions below are synthetic.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";

const web = resolve(process.argv[2] ?? "../kubb.thingelstad.xyz");
const fixtures = "ThrowingWoodKit/Tests/KubbRendererTests/Fixtures";
const dir = "ThrowingWoodKit/Sources/KubbEngine/Engine";
const { files } = JSON.parse(readFileSync(join(dir, "engine.json")));
const sources = Object.fromEntries(
  Object.keys(files).map((p) => [
    p.slice(0, -4),
    readFileSync(join(dir, p), "utf8"),
  ]),
);
const { Engine } = await import(
  pathToFileURL(join(web, "src/engine/index.js"))
);
const { chromium } = await import(
  pathToFileURL(join(web, "node_modules/playwright/index.mjs"))
);
const engine = await Engine.create({ sources });
const browser = await chromium.launch({ channel: "chrome" });
try {
  const page = await browser.newPage();
  // A virtual origin serves only the renderer modules. No server or web build.
  await page.route("**/*", (route) => {
    const path = new URL(route.request().url()).pathname;
    if (path === "/")
      return route.fulfill({
        contentType: "text/html",
        body: "<canvas></canvas>",
      });
    if (!/^\/src\/render\/[a-z]+\.js$/.test(path)) return route.abort();
    return route.fulfill({
      path: join(web, path),
      contentType: "application/javascript",
    });
  });
  await page.goto("http://127.0.0.1/");
  mkdirSync("build/review", { recursive: true });
  async function picture(name, scene, camera) {
    const fixture = { width: 640, height: 384, scene, camera };
    writeFileSync(
      join(fixtures, name + ".json"),
      JSON.stringify(fixture) + "\n",
    );
    const png = await page.evaluate(
      async ({ width, height, camera, scene }) => {
        const { drawWorld } = await import("/src/render/world.js");
        const canvas = document.querySelector("canvas");
        canvas.width = width;
        canvas.height = height;
        drawWorld(
          canvas.getContext("2d"),
          { width, height, dpr: 1 },
          camera,
          scene,
        );
        return canvas.toDataURL().split(",")[1];
      },
      fixture,
    );
    writeFileSync(
      "build/review/" + name + "-web.png",
      Buffer.from(png, "base64"),
    );
  }
  for (const [surface, set] of [
    ["grass", "classic"],
    ["sand", "usa"],
    ["snow", "minnesota"],
  ]) {
    const v = engine.newPractice({ surface, set });
    await picture(surface, { surface, set, items: v.items }, v.camera);
  }
  const v = engine.newPractice({ surface: "grass", set: "sweden" });
  let plan;
  for (let i = 0; i < 100; i++) plan = engine.frame({ plan: true });
  const a = plan.aim;
  await picture(
    "plan",
    {
      surface: v.surface,
      set: v.set,
      items: v.items,
      marker: a.marker,
      thrower: a.thrower,
      arc: a.arc.map((q) => [q.x, q.y, q.z]),
    },
    plan.camera,
  );
  engine.newMatch({ seed: 7, cpu: "both", surface: "sand", set: "wisconsin" });
  // The second baton in play, after the first action has settled.
  for (let n = 0; n < 2; n++) {
    let rec;
    for (let i = 0; i < 2000 && !rec; i++)
      rec = engine.frame({ dt: 1 / 60 }).recording;
    if (!rec) throw Error("scripted match did not release");
    if (n === 1) {
      const s = engine.showAt(rec.timeline.firstHit?.t ?? rec.landing.T);
      await picture(
        "mid-match",
        { surface: "sand", set: "wisconsin", items: s.items },
        s.camera,
      );
    } else engine.view();
  }
} finally {
  await browser.close();
  engine.lua.global.close();
}
