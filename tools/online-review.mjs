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
async function peer(id = "Review_Maple", version = compatible, name = "Maple", pitch = code) {
  const room = new Room({
    url: server.url,
    room: pitch,
    member: id,
    me: { name, level: "club", engine: version },
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
// An observer (docs/ONLINE.md "Observers"): a pitch of two invented players the app
// watches, in a match (observe, observemoved) or between matches (watchcard), with the
// scene the review asks for; noGame is an empty pitch; opengames lists two open pitches.
async function observed() {
  const host = await peer();
  const other = await peer("Review_Rowan", compatible, "Rowan");
  await host.update((d) => lua("lobbyOf", { doc: d }));
  await host.update((doc) => {
    let d = lua("joinTeam", { doc, id: host.you, side: "A" });
    d = lua("joinTeam", { doc: d, id: other.you, side: "B" });
    const look = process.env.SIMCTL_CHILD_REVIEW_SCENE;
    return look ? lua("setOptions", { doc: d, options: { scene: look } }) : d;
  });
  await until(() => other.doc && host.members.length === 2);
  if (mode === "watchcard") return;
  const members = lua("speakAs", { members: host.members, engine: manifest.version });
  const lineup = lua("lineup", { doc: host.doc, members });
  const setup = lua("matchOptions", {
    doc: host.doc,
    lineup,
    seed: 1001,
    start: { year: 2026, month: 11, day: 17, hour: 12, min: 0 },
  });
  engine.newMatch(setup);
  await host.update((doc) =>
    lua("startMatch", {
      doc,
      snap: engine.snapshot(),
      hash: engine.hash().hash,
      players: lineup.players,
      cpu: lineup.cpu,
      host: host.host,
      setup,
      members,
    }),
  );
}
async function openGames() {
  const made = [
    ["mapkubb3", "Review_Alder", "Alder", { players: 3, seats: 12, state: "playing" }],
    ["mapkubb4", "Review_Hazel", "Hazel", { players: 1, seats: 12, state: "waiting" }],
  ];
  for (const [pitch, id, name, open] of made) {
    const room = await peer(id, compatible, name, pitch);
    await room.update((d) => lua("lobbyOf", { doc: d }));
    room.setOpen(open);
  }
  await until(async () => (await server.store.listOpen({ since: 0, limit: 10, now: Math.floor(Date.now() / 1000) })).length === 2);
}
try {
  const observes = ["observe", "observemoved", "watchcard"].includes(mode);
  if (observes) await observed();
  if (mode === "opengames") await openGames();
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
    "feedback",
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
    // a device that has learned the throw: no coach line in these pictures
    // a host scene kept from an earlier --scene run must not open the next pitch in it
    ["simctl", "launch", "--terminate-running-process", phone, app, "-pitch.throwsMade", "9", "-pitch.hostScene", ""],
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
      const watcher = ["flight", "shout", "winner", "menu", "report", "feedback"].includes(
        mode,
      );
      await webRoom.update((doc) => {
        let d = lua("joinTeam", { doc, id: webRoom.you, side: "A" });
        return watcher ? d : lua("joinTeam", { doc: d, id: you, side: "B" });
      });
      if (watcher || mode === "handoff") {
        // as the web's own START does (src/net/pitch.js): each member that carries the
        // engine speaks as it, so an app whose announcement still names its newest is
        // not refused
        const members = lua("speakAs", { members: webRoom.members, engine: manifest.version }),
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
