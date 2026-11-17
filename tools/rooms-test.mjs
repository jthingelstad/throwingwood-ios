#!/usr/bin/env node
// Local-only conformance and cross-play. Imports the web checkout read-only; the
// server is imported rather than launched as a CLI, so it writes no files anywhere.
// Usage: node tools/rooms-test.mjs [--web <checkout>]
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
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
const dir = join(root, "ThrowingWoodKit/Sources/KubbEngine/Engine");
const manifest = JSON.parse(readFileSync(join(dir, "engine.json")));
const sources = Object.fromEntries(
  Object.keys(manifest.files).map((p) => [
    p.slice(0, -4),
    readFileSync(join(dir, p), "utf8"),
  ]),
);
const bin = execFileSync(
  "swift",
  ["build", "--package-path", join(root, "ThrowingWoodKit"), "--show-bin-path"],
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
const report = {
  webCommit: execFileSync("git", ["-C", web, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim(),
  engine: manifest.version,
  stack:
    "web src/engine/index.js + wasmoon 1.16.0 + src/net/room.js; Swift RoomsClient + PitchController + native Lua/musl",
  conformance: [],
  matches: [],
};
let now = Date.now();
let failReport = false;
const server = await startRoomsServer({
  port: 0,
  now: () => now,
  report: async () => {
    if (failReport) throw new Error("injected");
  },
  recordGame: async () => {
    if (failReport) throw new Error("injected");
  },
});
const rooms = [];
const engines = [];
const room = async (code, id, engine = "0.3.0") => {
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
const connect = (key, code, member) =>
  rpc({ op: "connect", key, room: code, member, url: server.url });
const stamp = { year: 2026, month: 11, day: 17, hour: 12, min: 0 };
const note = (s) => {
  report.conformance.push(s);
  console.log("conformance: " + s);
};
try {
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
            mode: "pitch",
            happened: "test",
            should: "",
            client: "ios",
            engine: "0.3.0",
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
            engine: "0.3.0",
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

  // Native controller refuses a mixed-version START through engine room.startCheck.
  await connect("mismatch", "efghjkmnpq", "Native_Mismatch");
  const old = await room("efghjkmnpq", "Web_Older", "0.2.0");
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
  note("different engine major.minor refuses START without writing a match");

  // The real controller waits for host grace, claims and takes over the CPU.
  await connect("handoverHost", "jkmnpqrstu", "Native_Host");
  await connect("handoverGuest", "jkmnpqrstu", "Native_Successor");
  await rpc({ op: "team", key: "handoverHost", side: "A" });
  assert.equal(
    await rpc({ op: "start", key: "handoverHost", seed: 99, at: stamp }),
    true,
  );
  await until(
    async () => (await state("handoverGuest")).state === "match",
    "handover start",
  );
  await rpc({ op: "close", key: "handoverHost" });
  await until(
    async () =>
      (await state("handoverGuest")).members.some(
        (m) => m.id === "Native_Host" && !m.connected,
      ),
    "handover disconnect",
  );
  const clockNow = Date.now();
  await rpc({ op: "tick", key: "handoverGuest", now: clockNow });
  assert.equal((await state("handoverGuest")).host, "Native_Host");
  now += 16001;
  await rpc({ op: "tick", key: "handoverGuest", now: clockNow + 16001 });
  await until(
    async () => (await state("handoverGuest")).host === "Native_Successor",
    "controller claim",
  );
  assert.equal((await state("handoverGuest")).control.cpu, true);
  for (let i = 0; i < 10; i++) {
    if ((await state("handoverGuest")).need.cpu) break;
    assert.equal(
      (await rpc({ op: "computer", key: "handoverGuest" })).ok,
      true,
    );
  }
  const beforeCPU = await state("handoverGuest");
  assert.equal(beforeCPU.need.cpu, true);
  for (let i = 0; i < 200; i++) {
    await rpc({ op: "frame", key: "handoverGuest", input: { dt: 0.1 } });
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
    const nativeID = await connect(key, code, "Native_Match_" + index);
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
    browser.on("doc", ({ doc, with: w, mine }) => {
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
    await rpc({
      op: "reduce",
      key,
      name: "setOptions",
      fields: {
        options: {
          surface,
          wind: ["off", "light", "strong"][index],
          raising: "hand",
          opening: "six",
        },
      },
    });
    assert.equal(
      await rpc({ op: "start", key, seed: 1001 + index, at: stamp }),
      true,
    );
    await until(() => started, "web start");
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
      const native = await state(key);
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
      hashAgreement: actions,
      corrections: 0,
      adoptions: 0,
      replayKept: true,
      replayVerified: actions,
      finish: engine.need().how,
    };
    report.matches.push(result);
    console.log("cross-play: " + JSON.stringify(result));
    await rpc({ op: "close", key });
    browser.close();
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
