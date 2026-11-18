// One synthetic scenario per ephemeral server. Called by online-snapshots.py.
import { execFileSync } from "node:child_process";
import { readFileSync, existsSync, rmSync } from "node:fs";
import { resolve, join } from "node:path";
import { pathToFileURL } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const [web, phone, mode, file] = process.argv.slice(2);
const importWeb = (p) => import(pathToFileURL(resolve(web, p)).href);
const { startRoomsServer } = await importWeb("tools/rooms-dev.mjs");
const { Engine } = await importWeb("src/engine/index.js");
const { Room } = await importWeb("src/net/room.js");
const code = "mapkubb2",
  app = "com.throwingwood.app";
const sim = (...args) =>
  execFileSync("xcrun", ["simctl", ...args], { encoding: "utf8" });
const ready = join(
  sim("get_app_container", phone, app, "data").trim(),
  "tmp/online-ready",
);
rmSync(ready, { force: true });
const server = await startRoomsServer({ port: 0 });
const dir = resolve(web, "vendor/engine");
const manifest = JSON.parse(readFileSync(join(dir, "engine.json")));
const sources = Object.fromEntries(
  Object.keys(manifest.files).map((p) => [
    p.slice(0, -4),
    readFileSync(join(dir, p), "utf8"),
  ]),
);
const engine = await Engine.create({ sources, client: "web review" });
const lua = (method, args) => engine.call("room." + method, args).value;
const [major, minor] = manifest.version.split(".").map(Number);
const compatible = `${major}.${minor}`;
const peers = [];
let timer;
async function peer(id = "Review_Maple", version = compatible) {
  const room = new Room({
    url: server.url,
    room: code,
    member: id,
    me: { name: "Maple", level: "club", engine: version },
  });
  peers.push(room);
  await room.ready;
  return room;
}
async function until(check) {
  const end = Date.now() + 20000;
  while (!(await check())) {
    if (Date.now() > end) throw Error("review did not reach " + mode);
    await delay(50);
  }
}
function stallJoins() {
  server.store.getRoom = () => new Promise(() => {});
}
try {
  const needsPeer = [
    "guest",
    "newer",
    "older",
    "handoff",
    "flight",
    "shout",
    "winner",
    "menu",
    "report",
    "replaced",
    "reconnecting",
  ].includes(mode);
  let webRoom;
  if (needsPeer) {
    webRoom = await peer(
      undefined,
      mode === "newer" ? `${major}.${minor+1}` : mode === "older" ? "0.3" : compatible,
    );
    await webRoom.update((d) => lua("lobbyOf", { doc: d }));
  }
  if (mode === "full")
    for (let i = 0; i < 16; i++) await peer("Review_Crowd" + i);
  if (mode === "connecting" || mode === "unreachable") stallJoins();
  execFileSync(
    "xcrun",
    ["simctl", "launch", "--terminate-running-process", phone, app],
    {
      env: {
        ...process.env,
        SIMCTL_CHILD_ONLINE_REVIEW: mode,
        SIMCTL_CHILD_ROOMS_DEV_PORT: String(server.port),
        SIMCTL_CHILD_PITCH_CODE: code,
      },
      stdio: "ignore",
    },
  );
  if (mode === "host") {
    await until(async () => (await server.store.getDoc(code))?.v > 0);
    webRoom = await peer();
  }
  if (webRoom) {
    await until(() => webRoom.members.length === 2);
    const you = webRoom.members.find((m) => m.id !== webRoom.you).id;
    if (mode === "replaced") {
      await peer(you);
    } else if (mode === "reconnecting") {
      const conn = (await server.store.getRoom(code)).members[you].conn;
      server.drop(conn);
      stallJoins();
    } else {
      const watcher = ["flight", "shout", "winner", "menu", "report"].includes(
        mode,
      );
      await webRoom.update((doc) => {
        let d = lua("joinTeam", { doc, id: webRoom.you, side: "A" });
        return watcher ? d : lua("joinTeam", { doc: d, id: you, side: "B" });
      });
      if (watcher || mode === "handoff") {
        const members = webRoom.members,
          host = webRoom.host;
        const lineup = lua("lineup", { doc: webRoom.doc, members });
        const setup = lua("matchOptions", {
          doc: webRoom.doc,
          lineup,
          seed: 1001,
          start: { year: 2026, month: 11, day: 17, hour: 12, min: 0 },
        });
        engine.newMatch(setup);
        await webRoom.update((doc) =>
          lua("startMatch", {
            doc,
            snap: engine.snapshot(),
            hash: engine.hash().hash,
            players: lineup.players,
            cpu: lineup.cpu,
            host,
            setup,
            members,
          }),
        );
        if (mode === "shout")
          timer = setInterval(
            () => webRoom.cast({ t: "shout", w: "TOK!" }),
            3000,
          );
        if (mode === "flight" || mode === "winner") {
          const action =
            mode === "winner" ? { type: "resign", side: "A" } : planThrow();
          engine.apply(action);
          await webRoom.update(
            (doc) =>
              lua("commitAction", {
                doc,
                n: 1,
                seq: 1,
                snap: engine.snapshot(),
                hash: engine.hash().hash,
                action,
                over: mode === "winner",
              }),
            {
              with: lua("rider", {
                n: 1,
                seq: 1,
                action,
                client: "web",
                engine: manifest.version,
              }),
            },
          );
        }
      }
    }
  }
  await until(() => existsSync(ready) && readFileSync(ready, "utf8") === mode);
  await delay(650);
  sim("io", phone, "screenshot", file);
} catch (error) {
  if (process.env.REVIEW_DIAGNOSTIC)
    sim("io", phone, "screenshot", process.env.REVIEW_DIAGNOSTIC);
  throw error;
} finally {
  clearInterval(timer);
  try {
    sim("terminate", phone, app);
  } catch {}
  for (const p of peers) p.close();
  engine.lua.global.close();
  await server.close();
}

function planThrow() {
  const snap = JSON.parse(engine.snapshot());
  const original = engine.snapshot();
  snap.opts.cpu = ["A", "B"];
  engine.restore(JSON.stringify(snap));
  let action;
  for (let i = 0; i < 2000 && !action; i++)
    action = engine.frame({ dt: 0.1 }).action;
  engine.restore(original);
  if (!action) throw Error("review throw");
  return action;
}
