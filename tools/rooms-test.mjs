#!/usr/bin/env node
// Local-only conformance and cross-play. Imports the web checkout read-only; the
// server is imported rather than launched as a CLI, so it writes no files anywhere.
// Usage: node tools/rooms-test.mjs [--web <checkout>]
import assert from "node:assert/strict";
import { existsSync, readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawn, execFileSync } from "node:child_process";
import { createInterface } from "node:readline";
const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const arg = process.argv.indexOf("--web");
const web = resolve(
  arg > 0
    ? process.argv[arg + 1]
    : (process.env.KUBB_WEB ?? join(root, "..", "kubb.thingelstad.xyz")),
);
const fromWeb = (p) => import(pathToFileURL(join(web, p)).href);
const { startRoomsServer } = await fromWeb("tools/rooms-dev.mjs");
const { Room, asciiJson, toFrames } = await fromWeb("src/net/room.js");
const { Engine } = await fromWeb("src/engine/index.js");
assert.equal(
  JSON.parse(readFileSync(join(web, "node_modules/wasmoon/package.json")))
    .version,
  "1.16.0",
);
const dir = join(web, "vendor/engine");
const manifest = JSON.parse(readFileSync(join(dir, "engine.json")));
const sources = Object.fromEntries(
  Object.keys(manifest.files).map((p) => [
    p.slice(0, -4),
    readFileSync(join(dir, p), "utf8"),
  ]),
);
const bin = execFileSync(
  "swift",
  [
    "build",
    "--package-path",
    join(root, "ThrowingWoodKit"),
    ...(process.argv.includes("--release") ? ["-c", "release"] : []),
    "--show-bin-path",
  ],
  { encoding: "utf8" },
).trim();
const child = spawn(join(bin, "RoomsProbe"), [], {
  cwd: root,
  stdio: ["pipe", "pipe", "inherit"],
});
const answers = [],
  waiting = [];
createInterface({ input: child.stdout }).on("line", (line) => {
  const answer = JSON.parse(line);
  const next = waiting.shift();
  if (next) next(answer);
  else answers.push(answer);
});
let chain = Promise.resolve();
function rpcRaw(cmd) {
  const run = chain.then(async () => {
    child.stdin.write(asciiJson(cmd) + "\n");
    return Promise.race([
      new Promise((r) =>
        answers.length ? r(answers.shift()) : waiting.push(r),
      ),
      new Promise((_, reject) => {
        const t = setTimeout(
          () => reject(new Error("Swift RPC timed out: " + cmd.op)),
          30000,
        );
        t.unref();
      }),
    ]);
  });
  chain = run.catch(() => {});
  return run;
}
async function rpc(cmd) {
  const a = await rpcRaw(cmd);
  assert.equal(a.ok, true, a.error);
  return a.value;
}
async function until(fn, label = "condition") {
  for (let i = 0; i < 1000; i++) {
    if (await fn()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("timed out: " + label);
}
const iosVersion = JSON.parse(
  readFileSync(join(root, "ThrowingWoodKit/Sources/KubbEngine/Engine/engine.json")),
).version;
const [major, minor] = iosVersion.split(".").map(Number);
const compatible = `${major}.${minor}`;
// The version this build plays a major.minor on: the newest, or the older engine it
// carries for it (Engines/<major.minor>/), which may be a later patch than the web's.
const iosVersionFor = (mm) => {
  const mmOf = (v) => v.split(".").slice(0, 2).join(".");
  if (!mm || mmOf(mm) === compatible) return iosVersion;
  const older = join(root, "ThrowingWoodKit/Sources/KubbEngine/Engines", mmOf(mm), "engine.json");
  return existsSync(older) ? JSON.parse(readFileSync(older)).version : manifest.version;
};
const report = {
  webCommit: execFileSync("git", ["-C", web, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim(),
  engine: manifest.version,
  iosEngine: iosVersion,
  stack:
    "web src/engine/index.js + wasmoon 1.16.0 + src/net/room.js; Swift RoomsClient + PitchController + native Lua/musl",
  conformance: [],
  matches: [],
};
let now = Date.now();
let failReport = false,
  latestReport;
const recordedRooms = new Set();
const server = await startRoomsServer({
  port: 0,
  now: () => now,
  record: async (entry) => {
    recordedRooms.add(entry.room);
  },
  report: async (entry) => {
    latestReport = entry;
    if (failReport) throw new Error("injected");
  },
  recordGame: async () => {
    if (failReport) throw new Error("injected");
  },
});
const rooms = [];
const engines = [];
const room = async (code, id, engine = manifest.version) => {
  const r = new Room({
    url: server.url,
    room: code,
    member: id,
    me: { name: id, level: "pro", engine },
  });
  rooms.push(r);
  await r.ready;
  return r;
};
const state = (key) => rpc({ op: "state", key });
const connect = (key, code, member, screen = false, create = true) =>
  rpc({
    op: "connect",
    key,
    room: code,
    member,
    screen,
    create,
    url: server.url,
  });
const stamp = { year: 2026, month: 11, day: 17, hour: 12, min: 0 };
const note = (s) => {
  report.conformance.push(s);
  console.log("conformance: " + s);
};
try {
  // The local game's sender opens its own connection without a pitch or member.
  await rpc({ op: "practiceReport", url: server.url });
  const practice = JSON.parse(latestReport.report);
  assert.equal(practice.mode, "practice");
  assert.equal(practice.engine, iosVersion);
  assert.equal(practice.client, "ios");
  assert.equal(practice.room, undefined);
  assert.deepEqual(practice.selectedPieces.map((p) => p.id).sort(), ["b1", "king"]);
  note("standalone practice report delivers both marked pieces");

  // The actual Swift client receives and sends every ordinary room message.
  await connect("wire", "abcdefghjk", "Native_Wire");
  const peer = await room("abcdefghjk", "Web_Wire");
  await until(async () => (await state("wire")).members.length === 2, "member");
  await rpc({
    op: "setMe",
    key: "wire",
    fields: { name: "Åsa 🎯", level: "club" },
  });
  await until(
    () =>
      peer.members.find((m) => m.id === "Native_Wire")?.me.name === "Åsa 🎯",
    "me",
  );
  const blob = "🎯".repeat(7000); // ASCII escape expansion, many frames
  await rpc({ op: "set", key: "wire", doc: { blob, future: { x: [] } } });
  await until(() => peer.doc?.blob === blob, "chunked Swift set");
  await peer.update((d) => ({ ...d, hello: "web" }), { with: { a: "rider" } });
  await until(async () => (await state("wire")).doc.hello === "web", "doc");
  const seen = [];
  peer.on("cast", (x) => seen.push(x));
  await rpc({
    op: "send",
    key: "wire",
    type: "cast",
    fields: { d: { t: "aim", s: { x: 1 } } },
  });
  await rpc({
    op: "send",
    key: "wire",
    type: "cast",
    fields: { d: { t: "shout", w: "NICE!" } },
  });
  await until(() => seen.length === 2, "casts");
  peer.cast({ t: "shout", w: "TOK!" });
  await rpc({ op: "send", key: "wire", type: "ping" });
  await until(
    async () =>
      (await rpc({ op: "events", key: "wire" })).some((m) => m.t === "pong"),
    "pong",
  );
  assert.equal(
    (
      await rpc({
        op: "request",
        key: "wire",
        type: "report",
        fields: {
          r: {
            kind: "throw",
            mode: "pitch",
            happened: "test",
            should: "",
            client: "ios",
            engine: manifest.version,
          },
        },
      })
    ).t,
    "reported",
  );
  assert.equal(
    (
      await rpc({
        op: "request",
        key: "wire",
        type: "report",
        fields: {
          r: {
            kind: "feedback",
            mode: "pitch",
            text: "test",
            client: "ios",
            engine: manifest.version,
          },
        },
      })
    ).t,
    "reported",
  );
  assert.equal(
    (
      await rpc({
        op: "request",
        key: "wire",
        type: "game",
        fields: {
          g: {
            mode: "watch",
            start: "-",
            actions: [],
            client: "ios",
            engine: manifest.version,
          },
        },
      })
    ).t,
    "recorded",
  );
  note(
    "join/joined, me/member, multi-frame set/ok/doc, bidirectional aim/shout casts, ping/pong, game/recorded, report/reported",
  );
  // Reconnect the Foundation socket through a forced network drop; same member/place.
  const joined = peer.members.find((m) => m.id === "Native_Wire").joined;
  const stored = await server.store.getRoom("abcdefghjk");
  server.drop(stored.members.Native_Wire.conn);
  await until(async () => {
    const c = (await server.store.getRoom("abcdefghjk")).members.Native_Wire
      .conn;
    return c && c !== stored.members.Native_Wire.conn;
  }, "new connection after drop");
  await until(
    async () =>
      (await state("wire")).status === "open" &&
      peer.members.find((m) => m.id === "Native_Wire")?.connected,
    "rejoin",
  );
  assert.equal(peer.members.find((m) => m.id === "Native_Wire").joined, joined);
  // A replacement is terminal, never a reconnect fight.
  await connect("replacement", "abcdefghjk", "Native_Wire");
  await until(
    async () => (await state("wire")).status === "replaced",
    "replaced",
  );
  await rpc({ op: "leave", key: "replacement" });
  await until(() => !peer.members.some((m) => m.id === "Native_Wire"), "left");
  note(
    "network drop/reconnect preserves member and joined time; replaced connection stops; leave/left",
  );

  // A backgrounded, replaced screen must not take the seat back on foreground.
  await connect("superseded", "vxwypqrs", "Replaced_Seat", true);
  const activePeer = await room("vxwypqrs", "Replaced_Seat");
  await until(
    async () => (await state("superseded")).display === "replaced",
    "replacement card",
  );
  await rpc({ op: "background", key: "superseded" });
  await rpc({ op: "foreground", key: "superseded" });
  assert.equal((await state("superseded")).display, "replaced");
  assert.equal(activePeer.status, "open");

  // Full room and every documented server error code over native raw transport.
  // Raw probes deliberately bypass the public client validation to reach refusal paths.
  const wire = async (key, frames, untilType = "error") =>
    rpc({
      op: "wire",
      key,
      frames: frames.map((f) => (typeof f === "string" ? f : asciiJson(f))),
      until: untilType,
    });
  const rawConnect = (key) => rpc({ op: "wireConnect", key, url: server.url });
  const codes = new Set();
  const error = async (key, msg, code) => {
    const m = await wire(key, Array.isArray(msg) ? msg : [msg]);
    assert.equal(m.code, code);
    codes.add(code);
  };
  await rawConnect("raw");
  await error("raw", { t: "set", base: 0, doc: {} }, "not-joined");
  await error(
    "raw",
    { t: "join", room: "bad", member: "Native_Raw" },
    "bad-room",
  );
  await error(
    "raw",
    { t: "join", room: "bcdefghjkm", member: "bad" },
    "bad-member",
  );
  await error("raw", "{not json", "bad-message");
  await error("raw", "~x.1.17~x", "bad-message");
  await wire(
    "raw",
    [{ t: "join", room: "bcdefghjkm", member: "Native_Raw" }],
    "joined",
  );
  await error(
    "raw",
    { t: "join", room: "cdefghjkmn", member: "Native_Raw" },
    "already-joined",
  );
  await error("raw", { t: "cast", d: "x".repeat(2100) }, "too-big");
  await error(
    "raw",
    [...Array(50)].map(() => ({ t: "cast", d: { t: "aim" } })),
    "rate",
  );
  await rawConnect("guest");
  await wire(
    "guest",
    [{ t: "join", room: "bcdefghjkm", member: "Native_Guest" }],
    "joined",
  );
  await error("guest", { t: "claim" }, "host-present");
  await error("guest", { t: "open", open: null }, "not-host");
  // Error frames left over from a burst are drained by wire's requested type/code.
  await rpc({ op: "wireClose", key: "raw" });
  await until(
    async () =>
      !(await server.store.getRoom("bcdefghjkm")).members.Native_Raw.conn,
    "host gone",
  );
  await error("guest", { t: "claim" }, "host-recent");
  await rawConnect("third");
  await wire(
    "third",
    [{ t: "join", room: "bcdefghjkm", member: "Native_Third" }],
    "joined",
  );
  now += 16001;
  await error("third", { t: "claim" }, "not-next");
  await wire("guest", [{ t: "claim" }], "host");
  note(
    "claim/host after 15s grace; host-present/host-recent/not-next/not-host",
  );
  // CAS conflict on raw wire: no includes current doc, Swift reducer retries are unit-tested.
  await wire("guest", [{ t: "set", id: 1, base: 0, doc: { n: 1 } }], "ok");
  assert.equal(
    (await wire("guest", [{ t: "set", id: 2, base: 0, doc: { n: 2 } }], "no"))
      .v,
    1,
  );
  const put = server.store.putRoom;
  server.store.putRoom = async () => false;
  await error("guest", { t: "me", me: {} }, "busy");
  server.store.putRoom = put;
  // Feedback carries one text and never a throw's answers (backend checkReport).
  await error(
    "guest",
    { t: "report", r: { kind: "feedback", mode: "solo", text: "hi", happened: "" } },
    "bad-message",
  );
  await error(
    "guest",
    { t: "report", r: { kind: "feedback", mode: "solo", text: "  " } },
    "bad-message",
  );
  for (let i = 0; i < 3; i++)
    await wire(
      "guest",
      [
        {
          t: "report",
          id: i,
          r: { mode: "practice", happened: "test", should: "" },
        },
      ],
      "reported",
    );
  await error(
    "guest",
    { t: "report", r: { mode: "practice", happened: "test", should: "" } },
    "too-many",
  );
  failReport = true;
  await error(
    "third",
    { t: "report", r: { mode: "practice", happened: "test", should: "" } },
    "failed",
  );
  failReport = false;
  const unavailable = await startRoomsServer({ port: 0 });
  await rpc({ op: "wireConnect", key: "unavailable", url: unavailable.url });
  await error(
    "unavailable",
    { t: "game", g: { mode: "watch", start: "-", actions: [] } },
    "unavailable",
  );
  await rpc({ op: "wireClose", key: "unavailable" });
  await unavailable.close();
  const crowd = [];
  for (let i = 0; i < 16; i++)
    crowd.push(await room("defghjkmnp", "Crowd_" + String(i).padStart(3, "0")));
  await rawConnect("full");
  await error(
    "full",
    { t: "join", room: "defghjkmnp", member: "Native_Full" },
    "full",
  );
  codes.add("replaced");
  assert.deepEqual(
    [...codes].sort(),
    [
      "already-joined",
      "bad-member",
      "bad-message",
      "bad-room",
      "busy",
      "failed",
      "full",
      "host-present",
      "host-recent",
      "not-host",
      "not-joined",
      "not-next",
      "rate",
      "replaced",
      "too-big",
      "too-many",
      "unavailable",
    ].sort(),
  );
  note(
    "17/17 documented server error codes; full room (16 connected); set/no; injected busy/failed/unavailable",
  );

  // Native controller refuses a START with no engine every player carries (room.engineFor).
  await connect("mismatch", "efghjkmnpq", "Native_Mismatch", true);
  const old = await room("efghjkmnpq", "Web_Older", "0.3.0");
  await rpc({ op: "team", key: "mismatch", side: "A" });
  await old.update((d) => {
    d.teams.B = ["Web_Older"];
    return d;
  });
  await until(
    async () => (await state("mismatch")).doc.teams.B.length === 1,
    "mismatch lineup",
  );
  assert.equal(
    await rpc({ op: "start", key: "mismatch", seed: 7, at: stamp }),
    false,
  );
  assert.equal((await state("mismatch")).state, "versionMismatch");
  assert.equal(old.doc.started, false);
  assert.equal(
    (await state("mismatch")).note,
    "Web_Older is on an older version of Throwing Wood. To play together, they need to update the app or reload the page.",
  );
  for (const [version, card] of [
    ["0.3", "older"],
    [`${major}.${minor+1}`, "newer"],
  ]) {
    const code = card === "older" ? "qrstuvwx" : "rstuvwxy";
    const host = await room(code, "Browser_Host", version);
    await host.update(() => ({ teams: { A: [], B: [] } }));
    await connect(card, code, "Native_Seat", true, false);
    await rpc({ op: "team", key: card, side: "B" });
    await until(
      async () => (await state(card)).card === card,
      "version card " + card,
    );
    const watcherRef = await Engine.create({ sources, client: "web test" });
    engines.push(watcherRef);
    const r = (method, args) => watcherRef.call("room." + method, args).value;
    const lineup = r("lineup", { doc: host.doc, members: host.members });
    const setup = r("matchOptions", {
      doc: host.doc,
      lineup,
      seed: 99,
      start: stamp,
    });
    watcherRef.newMatch(setup);
    // Reproduce an already-running pitch with a different version stamp.
    await host.update((doc) => {
      const next = r("startMatch", {
        doc,
        snap: watcherRef.snapshot(),
        hash: watcherRef.hash().hash,
        setup,
        players: lineup.players,
        cpu: lineup.cpu,
        host: host.you,
        // spoken down to this engine: the native seat announces every engine it carries
        members: host.members.map((m) =>
          m.me?.engines ? { ...m, me: { ...m.me, engine: manifest.version } } : m,
        ),
      });
      next.match.engine = version;
      return next;
    });
    await until(
      async () => (await state(card)).display === "match",
      "version in play",
    );
    assert.equal((await state(card)).mayAct, false);
    assert.equal((await state(card)).card, card);
    const action = { type: "resign", side: "A" };
    watcherRef.apply(action);
    await host.update(
      (doc) =>
        r("commitAction", {
          doc,
          n: 1,
          seq: 1,
          action,
          snap: watcherRef.snapshot(),
          hash: watcherRef.hash().hash,
          over: true,
        }),
      {
        with: r("rider", {
          n: 1,
          seq: 1,
          action,
          client: "web",
          engine: version,
        }),
      },
    );
    await until(
      async () => (await state(card)).displayHash === watcherRef.hash().hash,
      "read-only version watch",
    );
    assert.equal((await state(card)).mayAct, false);
    await rpc({ op: "close", key: card });
    host.close();
  }
  note("different engine major.minor refuses START without writing a match");

  // The real controller waits for host grace, claims and takes over the CPU.
  const handoverWeb = await room("jkmnpqrstu", "Web_Host");
  await handoverWeb.update(() => ({ teams: { A: ["Web_Host"], B: [] } }));
  await connect("handoverGuest", "jkmnpqrstu", "Native_Successor", true, false);
  const hEngine = await Engine.create({ sources, client: "web test" });
  engines.push(hEngine);
  const callRoom = (name, args) => hEngine.call("room." + name, args).value;
  const members = handoverWeb.members;
  const lineup = callRoom("lineup", { doc: handoverWeb.doc, members });
  const setup = callRoom("matchOptions", {
    doc: handoverWeb.doc,
    lineup,
    seed: 99,
    start: stamp,
  });
  hEngine.newMatch(setup);
  await handoverWeb.update((doc) =>
    callRoom("startMatch", {
      doc,
      snap: hEngine.snapshot(),
      hash: hEngine.hash().hash,
      players: lineup.players,
      cpu: lineup.cpu,
      host: handoverWeb.host,
      setup,
      members,
    }),
  );
  await until(
    async () => (await state("handoverGuest")).state === "match",
    "handover start",
  );
  handoverWeb.close();
  await until(
    async () =>
      (await state("handoverGuest")).members.some(
        (m) => m.id === "Web_Host" && !m.connected,
      ),
    "handover disconnect",
  );
  const clockNow = Date.now();
  await rpc({ op: "tick", key: "handoverGuest", now: clockNow });
  assert.equal((await state("handoverGuest")).host, "Web_Host");
  now += 16001;
  await rpc({ op: "tick", key: "handoverGuest", now: clockNow + 16001 });
  await until(
    async () => (await state("handoverGuest")).host === "Native_Successor",
    "controller claim",
  );
  assert.equal((await state("handoverGuest")).control.cpu, true);
  for (let i = 0; i < 10; i++) {
    await rpc({ op: "skip", key: "handoverGuest" });
    if ((await state("handoverGuest")).need.cpu) break;
    const before = (await state("handoverGuest")).doc.match.seq;
    if (i === 0)
      assert.equal(await rpc({ op: "dialThrow", key: "handoverGuest" }), true);
    else
      assert.equal(
        (await rpc({ op: "computer", key: "handoverGuest" })).ok,
        true,
      );
    await until(
      async () => (await state("handoverGuest")).doc.match.seq === before + 1,
      "takeover action settled",
    );
  }
  await rpc({ op: "dismiss", key: "handoverGuest" });
  const beforeCPU = await state("handoverGuest");
  assert.equal(beforeCPU.need.cpu, true);
  for (let i = 0; i < 200; i++) {
    await rpc({ op: "displayFrame", key: "handoverGuest" });
    if ((await state("handoverGuest")).seq > beforeCPU.seq) break;
  }
  assert.equal((await state("handoverGuest")).seq, beforeCPU.seq + 1);
  await rpc({ op: "close", key: "handoverGuest" });
  note(
    "PitchController waits host grace, claims host, takes absent human seat and releases the host-owned CPU throw",
  );

  // Three complete naturally-ended matches, each surface and wind, no turn cap.
  for (const [index, surface] of ["grass", "sand", "snow"].entries()) {
    const key = "match" + index,
      code = ["fghjkmnpqr", "ghjkmnpqrs", "hjkmnpqrst"][index];
    const nativeID = await connect(key, code, "Native_Match_" + index, true);
    const browser = await room(code, "Web_Match_" + index);
    const engine = await Engine.create({ sources, client: "web 0.0-test" });
    engines.push(engine);
    const planner = await Engine.create({ sources, client: "web 0.0-test" });
    engines.push(planner);
    const lua = (name, args) => engine.call("room." + name, args).value;
    let local = { n: null, seq: 0 },
      webApplied = 0,
      corrections = 0,
      started = false;
    let previousDoc;
    browser.on("doc", ({ doc, with: w, mine }) => {
      const before = previousDoc;
      previousDoc = doc;
      if (w && !mine) {
        const m = doc.match;
        const expected = lua("commitAction", {
          doc: before,
          n: m.n,
          seq: m.seq,
          snap: m.snap,
          hash: m.hash,
          action: w.a,
          over: m.over,
        });
        assert.deepEqual(
          doc,
          expected,
          "native document equals web reducer output",
        );
        assert.deepEqual(
          w,
          lua("rider", {
            n: m.n,
            seq: m.seq,
            action: w.a,
            // a rider names no device (the default "web") and the engine that played:
            // this build's copy of the match's major.minor
            engine: iosVersionFor(m.engine),
          }),
        );
      }
      const d = lua("decide", { local, doc, with: w, mine });
      if (d.kind === "lobby" || d.kind === "old") return;
      if (d.kind === "start") {
        engine.restore(d.match.snap);
        started = true;
      } else if (d.kind === "apply") {
        assert.notEqual(engine.apply(d.action).ok, false);
        if (engine.hash().hash !== d.match.hash) corrections++;
        webApplied++;
      } else if (d.kind === "adopt") {
        corrections++;
        engine.restore(d.match.snap);
      } else if (d.kind === "same" && engine.hash().hash !== d.match.hash)
        corrections++;
      local = { n: d.match.n, seq: d.match.seq };
    });
    await rpc({ op: "team", key, side: "A" });
    await browser.update((d) =>
      lua("joinTeam", { doc: d, id: browser.you, side: "B" }),
    );
    for (const [name, value] of Object.entries({
      surface,
      wind: ["off", "light", "strong"][index],
      raising: "hand",
      opening: "six",
    })) {
      await rpc({ op: "option", key, name, value });
      await until(
        () => browser.doc.options[name] === value,
        "lobby option to web",
      );
    }
    assert.equal(
      await rpc({ op: "start", key, seed: 1001 + index, at: stamp }),
      true,
    );
    await until(() => started, "web start");
    const initial = browser.doc.match;
    const start = lua("startMatch", {
      doc: { ...browser.doc, started: false, n: 0, match: null },
      snap: initial.snap,
      hash: initial.hash,
      players: initial.players,
      cpu: initial.cpu,
      host: nativeID,
      setup: initial.setup,
      members: browser.members,
    });
    assert.deepEqual(
      browser.doc,
      start,
      "native START document equals web reducer output",
    );
    if (index === 0) {
      await connect("sleepingWatcher", code, "Sleeping_Watcher", true, false);
      assert.equal((await state("sleepingWatcher")).mayAct, false);
      await rpc({ op: "background", key: "sleepingWatcher" });
    }
    const casts = [];
    browser.on("cast", ({ d }) => casts.push(d));
    let inboundAim = false;
    await rpc({ op: "dismiss", key });
    await until(
      () => casts.some((d) => d.t === "aim"),
      "native display casts aim",
    );
    assert.deepEqual(
      Object.keys(casts.find((d) => d.t === "aim").s).sort(),
      Object.keys(engine.aimState()).sort(),
    );
    await rpc({ op: "shout", key });
    await until(() => casts.some((d) => d.t === "shout"), "native shout");
    assert.deepEqual(
      casts.find((d) => d.t === "shout"),
      { t: "shout", w: "NICE!" },
    );
    browser.cast({ t: "shout", w: "TOK!" });
    await until(
      async () => (await state(key)).shouts.some((s) => s.endsWith("TOK!")),
      "web shout shown",
    );
    assert.deepEqual(
      Object.keys(browser.members.find((m) => m.id === nativeID).me).sort(),
      ["engine", "engines", "level", "name"],
    );
    // spoken down to the web's engine (docs/ONLINE.md "Engines in one room")
    assert.equal(
      browser.members.find((m) => m.id === nativeID).me.engine,
      manifest.version.split(".").slice(0, 2).join(".") + "+engines",
    );
    let nativeCommits = 0,
      webCommits = 0,
      actions = 0,
      raises = 0,
      punishments = 0;
    while (engine.need().kind !== "over") {
      if (actions > 2500) throw new Error("match did not finish");
      const need = engine.need();
      const actor = lua("actorsFor", {
        need,
        ctx: {
          players: browser.doc.match.players,
          cpu: browser.doc.match.cpu,
          host: browser.host,
          connected: browser.members
            .filter((m) => m.connected)
            .map((m) => m.id),
        },
      })[0];
      if (actor === nativeID) {
        const result = await rpc({ op: "computer", key });
        assert.equal(result.ok, true, "native seat/action");
        if (result.action.type === "raise") raises++;
        if (result.action.type === "punish") punishments++;
        nativeCommits++;
        await until(() => local.seq === actions + 1, "web applied native");
      } else {
        assert.equal(actor, browser.you);
        if (!inboundAim && need.kind === "throw") {
          browser.cast({ t: "aim", s: engine.aimState() });
          await until(
            async () => (await state(key)).shownAims > 0,
            "web aim shown",
          );
          inboundAim = true;
        }
        let action;
        if (need.kind === "raise") {
          action = { type: "raise" };
          raises++;
        } else if (need.kind === "punish") {
          action = { type: "punish", ...need.cursor };
          punishments++;
        } else {
          const snap = JSON.parse(engine.snapshot());
          snap.opts.cpu = ["A", "B"];
          planner.restore(JSON.stringify(snap));
          for (let f = 0; f < 2000; f++) {
            const out = planner.frame({ dt: 0.1 });
            if (out.action) {
              action = out.action;
              break;
            }
          }
          assert.ok(action);
        }
        assert.notEqual(engine.apply(action).ok, false);
        const seq = local.seq + 1,
          n = local.n,
          hash = engine.hash().hash,
          snap = engine.snapshot();
        local.seq = seq;
        await browser.update(
          (d) =>
            lua("commitAction", {
              doc: d,
              n,
              seq,
              snap,
              hash,
              action,
              over: engine.need().kind === "over",
            }),
          {
            with: lua("rider", {
              n,
              seq,
              action,
              client: "web",
              engine: engine.version,
            }),
          },
        );
        webCommits++;
      }
      actions++;
      await until(
        async () => (await state(key)).seq === actions,
        "native applied web",
      );
      await rpc({ op: "skip", key });
      const native = await state(key);
      assert.equal(
        native.displayHash,
        engine.hash().hash,
        "screen hash " + actions,
      );
      assert.equal(native.displayCorrections, 0);
      if (actions === 2 && index === 0) {
        await rpc({ op: "foreground", key: "sleepingWatcher" });
        const watcher = await state("sleepingWatcher");
        assert.equal(watcher.seq, actions);
        assert.equal(watcher.displayHash, native.hash);
        assert.equal(watcher.mayAct, false);
        await rpc({ op: "close", key: "sleepingWatcher" });
      }
      if (actions === 2) {
        await rpc({ op: "report", key });
        const captured = JSON.parse(latestReport.report);
        assert.equal(captured.mode, "pitch");
        assert.equal(captured.v, browser.v);
        assert.equal(captured.match.seq, 2);
        assert.equal(captured.client, "ios");
        assert.equal(captured.engine, iosVersionFor(browser.doc.match.engine)); // the engine that played
        assert.ok(
          !latestReport.report.includes(nativeID) &&
            !latestReport.report.includes(browser.you),
        );
      }
      if (actions === 3) {
        const joined = browser.members.find((m) => m.id === nativeID).joined;
        await rpc({ op: "background", key });
        await until(
          () => !browser.members.find((m) => m.id === nativeID).connected,
          "background",
        );
        await rpc({ op: "foreground", key });
        assert.equal((await state(key)).displayHash, native.hash);
        assert.equal(
          browser.members.find((m) => m.id === nativeID).joined,
          joined,
        );
      }
      if (actions === 5) {
        server.drop((await server.store.getRoom(code)).members[nativeID].conn);
        await until(
          () => !browser.members.find((m) => m.id === nativeID).connected,
          "dropped",
        );
        await until(
          () => browser.members.find((m) => m.id === nativeID).connected,
          "rejoined",
        );
        await until(
          async () => (await state(key)).display === "match",
          "restored",
        );
      }
      assert.equal(native.error, null);
      assert.equal(
        native.hash,
        engine.hash().hash,
        "hash after action " + actions,
      );
      assert.equal(native.corrections, 0);
      assert.equal(native.adoptions, 0);
      assert.equal(corrections, 0);
    }
    await until(
      async () => Boolean(await server.store.getReplay(code)),
      "keep replay",
    );
    const kept = JSON.parse((await server.store.getReplay(code)).data);
    assert.equal(kept.log.length, actions);
    assert.equal(kept.hash, engine.hash().hash);
    engine.call("replayLoad", kept);
    for (let i = 0; i < actions; i++)
      assert.equal(engine.call("replayStep").replay.differs, false);
    assert.equal(engine.hash().hash, kept.hash);
    const native = await state(key);
    assert.equal(native.applied, webCommits);
    assert.equal(webApplied, nativeCommits);
    assert.ok(nativeCommits > 0 && webCommits > 0);
    const result = {
      surface,
      wind: ["off", "light", "strong"][index],
      seed: 1001 + index,
      actions,
      nativeCommits,
      webCommits,
      raises,
      punishments,
      aimFromNative: casts.filter((d) => d.t === "aim").length,
      aimFromWeb: Number(inboundAim),
      shoutsFromNative: casts.filter((d) => d.t === "shout").length,
      shoutsFromWeb: 1,
      hashAgreement: actions,
      corrections: 0,
      adoptions: 0,
      replayKept: true,
      replayVerified: actions,
      finish: engine.need().how,
    };
    assert.ok(inboundAim);
    assert.ok(recordedRooms.has(code), "rooms-dev recorded the shared match");
    await rpc({ op: "rematch", key });
    await until(
      () => !browser.doc.started,
      "host rematch returns web to lobby",
    );
    assert.deepEqual(browser.doc.teams, { A: [nativeID], B: [browser.you] });
    report.matches.push(result);
    console.log("cross-play: " + JSON.stringify(result));
    await rpc({ op: "close", key });
    browser.close();
  }
  // Sharing a match against the computer (the web's docs/ROOMS.md section 13): the
  // iPhone's message for the web's vector match, the web's own check on a server of its
  // own, the same code again, a sealed join, the kept replay and the reel. The reel
  // renderer is a stand-in that only notes what it was asked: nothing is written.
  {
    const { devShareChecker, devReelEngines } = await fromWeb(
      "tools/reels-dev.mjs",
    );
    const asked = [];
    const shareServer = await startRoomsServer({
      port: 0,
      shareChecker: devShareChecker({ log: () => {} }),
      reelEngines: devReelEngines(),
      reelRenderer: () => async (input) => {
        asked.push(input);
      },
    });
    try {
      const vec = JSON.parse(
        readFileSync(
          join(root, "ThrowingWoodKit/Tests/KubbRoomsTests/Fixtures/share-vectors.json"),
        ),
      );
      const make = (name, engine = vec.webEngine) =>
        rpc({
          op: "shareMake",
          engine,
          start: vec.match.start,
          actions: vec.match.actions,
          winner: vec.match.winner,
          name,
        });
      const made = await make("Lakeside");
      const sent = JSON.parse(made.message);
      assert.equal(sent.g.client, "ios");
      assert.deepEqual(
        { ...sent.g, client: "web" },
        vec.messages[0].g,
        "the iPhone's message is the web's but for client",
      );
      assert.equal(made.bytes, vec.messages[0].bytes);
      assert.deepEqual(await make("Lakeside", "0.6.0"), { refused: "engine" });
      const url = shareServer.url;
      const first = await rpc({ op: "share", url, message: made.message });
      assert.match(first.code, /^[2-9a-hjkmnp-z]{10}$/);
      assert.equal(first.v, 1);
      const again = await rpc({ op: "share", url, message: made.message });
      assert.equal(again.code, first.code, "the same match shared again: the same code");
      const other = await rpc({
        op: "share",
        url,
        message: (await make("Ünïcödé 🪵")).message,
      });
      assert.ok(other.code && other.code !== first.code, "another name: another link");
      // what the server says of a version it does not carry, and of a computer's
      // throw that is not the one the computer makes
      const tamper = (f) => {
        const m = JSON.parse(made.message);
        f(m.g);
        return asciiJson(m);
      };
      const engine = await rpc({
        op: "share",
        url,
        message: tamper((g) => (g.engine = "0.6.0")),
      });
      assert.deepEqual(engine, { code: null, v: 0, why: "engine" });
      const forged = await rpc({
        op: "share",
        url,
        message: tamper((g) => {
          const cpu = g.log.find((e) => e.a.type === "throw" && e.a.scripted);
          cpu.a.launch.speed += 0.5;
        }),
      });
      assert.deepEqual(forged, { code: null, v: 0, why: "does-not-replay" });
      // a sealed pitch: the iPhone's join is refused `sealed` and the screen says so
      const key = "sealed";
      const joined = await rpcRaw({
        op: "connect",
        key,
        url,
        room: first.code,
        screen: true,
        create: false,
      });
      assert.equal(joined.ok, false, "a sealed pitch is never joined");
      await until(
        async () => (await state(key)).display === "sealed",
        "the screen shows a sealed pitch",
      );
      await rpc({ op: "close", key });
      const card = await rpc({ op: "sealedCard", url, room: first.code });
      assert.equal(card.need, "over", "the kept replay restores to its winner card");
      const reel = await rpc({ op: "reel", url, room: first.code });
      assert.match(reel, /^rendering/, "the reel is asked for the shared code");
      assert.ok(asked.some((r) => r.room === first.code));
      report.share = {
        bytes: made.bytes,
        actions: vec.match.actions.length,
        client: sent.g.client,
        codes: "same code again; another name another code",
        refusals: ["engine (here)", "engine (server)", "does-not-replay (server)"],
        sealed: "join refused sealed; kept replay restores to over",
        reel: reel,
      };
      console.log("share: " + JSON.stringify(report.share));
    } finally {
      await shareServer.close();
    }
  }
  mkdirSync(join(root, "build"), { recursive: true });
  writeFileSync(
    join(root, "build/rooms-results.json"),
    JSON.stringify(report, null, 2) + "\n",
  );
  console.log("PASS: conformance and cross-play");
} finally {
  for (const r of rooms) r.close();
  for (const e of engines) e.lua.global.close();
  child.stdin.end();
  await new Promise((resolve) => {
    if (child.exitCode !== null) return resolve();
    child.once("exit", resolve);
    setTimeout(() => {
      child.kill();
      resolve();
    }, 2000).unref();
  });
  await server.close();
}
