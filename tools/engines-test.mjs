#!/usr/bin/env node
// Local-only cross-play between builds that carry different engines (docs/ONLINE.md
// "Engines in one room"): this checkout's RoomsProbe against another build's RoomsProbe
// (an older TestFlight build's code, checked out and built under /tmp), both driving the
// real RoomsClient and PitchController against the web's rooms-dev on an ephemeral
// 127.0.0.1 port. Imports the web checkout read-only and writes only
// build/engines-results.json here. Never points anything at the live rooms service.
//
//   swift build --package-path ThrowingWoodKit --product RoomsProbe
//   (cd <old checkout>/ThrowingWoodKit && swift build --product RoomsProbe)
//   node tools/engines-test.mjs --web <web checkout> --old <old checkout>
//
// Scenarios: this build hosts and the old one joins; the old one hosts and this one
// joins; two of this build. Each plays a few throws, among them a person's short baton
// (its stance moved under 2 m of its target: kubb-engine 0.8.0's short throw), and after
// every action both sides' engine hashes must equal the room's. When the two builds
// share no engine, START must be refused plainly and nothing written.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { spawn, execFileSync } from "node:child_process";
import { createInterface } from "node:readline";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const opt = (name) => {
  const i = process.argv.indexOf(name);
  return i > 0 ? process.argv[i + 1] : undefined;
};
const web = resolve(opt("--web") ?? join(root, "..", "kubb.thingelstad.xyz"));
const old = opt("--old");
assert.ok(old, "--old <checkout of the older build>");
const { startRoomsServer } = await import(pathToFileURL(join(web, "tools/rooms-dev.mjs")).href);

const binOf = (pkg) =>
  execFileSync("swift", ["build", "--package-path", pkg, "--show-bin-path"], {
    encoding: "utf8",
  }).trim();
const probes = {
  new: join(binOf(join(root, "ThrowingWoodKit")), "RoomsProbe"),
  old: join(binOf(join(resolve(old), "ThrowingWoodKit")), "RoomsProbe"),
};
const engineOf = (dir) =>
  JSON.parse(readFileSync(join(dir, "ThrowingWoodKit/Sources/KubbEngine/Engine/engine.json")))
    .version;
const mm = (v) => v.split(".").slice(0, 2).join(".");
const versions = { new: engineOf(root), old: engineOf(resolve(old)) };

// One probe process: JSON lines in, JSON lines out, one request at a time.
function probe(which) {
  const child = spawn(probes[which], [], { stdio: ["pipe", "pipe", "inherit"] });
  const answers = [],
    waiting = [];
  createInterface({ input: child.stdout }).on("line", (line) => {
    const a = JSON.parse(line);
    const next = waiting.shift();
    if (next) next(a);
    else answers.push(a);
  });
  let chain = Promise.resolve();
  const raw = (cmd) => {
    const run = chain.then(() => {
      child.stdin.write(JSON.stringify(cmd) + "\n");
      return Promise.race([
        new Promise((r) => (answers.length ? r(answers.shift()) : waiting.push(r))),
        new Promise((_, no) => setTimeout(() => no(new Error(`${which} ${cmd.op} timed out`)), 60000).unref()),
      ]);
    });
    chain = run.catch(() => {});
    return run;
  };
  const call = async (cmd) => {
    const a = await raw(cmd);
    assert.equal(a.ok, true, `${which} ${cmd.op}: ${a.error}`);
    return a.value;
  };
  return { which, child, raw, call };
}
const until = async (fn, label) => {
  for (let i = 0; i < 2000; i++) {
    if (await fn()) return;
    await new Promise((r) => setTimeout(r, 5));
  }
  throw new Error("timed out: " + label);
};

const server = await startRoomsServer({ port: 0 });
const url = server.url;
assert.match(url, /^ws:\/\/127\.0\.0\.1:/);
const procs = { new: probe("new"), old: probe("old"), new2: probe("new") };
procs.new2.which = "new";
const planner = procs.new;
const carriedHere = (await (async () => {
  // what this build carries, from a throwaway pitch's state
  const p = procs.new;
  await p.call({ op: "connect", url, room: "zzzzzzzzzz", member: "Carried_Check", key: "c" });
  const s = await p.call({ op: "state", key: "c" });
  await p.call({ op: "leave", key: "c" });
  return s.carried;
})());

const results = { engines: versions, carried: carriedHere, scenarios: [] };
let roomN = 0;
const code = () => "engnsxyz" + "bcdefghjkm"[roomN++ % 10] + "pq";

// Move a baton's stance to d metres short of its target, along the line it was thrown.
function shortBaton(action, d) {
  const { stance: s, target: t } = action;
  const dx = s.x - t.x,
    dy = s.y - t.y,
    len = Math.hypot(dx, dy);
  return { ...action, stance: { ...s, x: t.x + (dx / len) * d, y: t.y + (dy / len) * d, set: true } };
}

async function scenario(label, hostP, guestP, { expect, throws = 8, nearAt = [1, 3] }) {
  const room = code();
  const h = "h" + roomN,
    g = "g" + roomN;
  const screen = (p) => p.which === "new";
  await hostP.call({ op: "connect", url, room, key: h, member: `Host_${label}_x`.slice(0, 40), create: true, screen: screen(hostP) });
  await guestP.call({ op: "connect", url, room, key: g, member: `Guest_${label}_x`.slice(0, 40), create: false, screen: screen(guestP) });
  await hostP.call({ op: "team", key: h, side: "A" });
  await guestP.call({ op: "team", key: g, side: "B" });
  const st = (p, k) => p.call({ op: "state", key: k });
  // the lobby settles: both see both seated, and every announcement has come back
  await until(async () => {
    const [a, b] = [await st(hostP, h), await st(guestP, g)];
    const seated = (s) => (JSON.parse(JSON.stringify(s.doc))?.teams?.B ?? []).length === 1;
    const announced = (s, other) =>
      !s.announced || JSON.stringify(other.members.find((m) => m.id === s.you)?.me?.engine) === JSON.stringify(s.announced.engine);
    return seated(a) && seated(b) && announced(a, b) && announced(b, a) && announced(a, a) && announced(b, b);
  }, label + " lobby");
  const out = { label, host: hostP.which, guest: guestP.which, expect };
  const lobby = [await st(hostP, h), await st(guestP, g)];
  out.lobby = lobby.map((s) => ({ engineLine: s.engineLine, canStart: s.canStart, card: s.card, me: s.members.find((m) => m.id === s.you)?.me }));
  const before = lobby[0].v;
  let started = false;
  for (let i = 0; i < 3 && !started; i++) {
    started = await hostP.call({ op: "start", key: h, seed: 4242 + roomN, at: { year: 2026, month: 11, day: 20, hour: 12, min: 0 } });
    if (!started) await new Promise((r) => setTimeout(r, 200));
  }
  if (expect === null) {
    const [a, b] = [await st(hostP, h), await st(guestP, g)];
    out.refused = !started;
    out.hostState = a.state;
    out.hostNote = a.note;
    out.mismatch = a.mismatch;
    out.written = a.v !== before && JSON.parse(JSON.stringify(a.doc))?.started === true;
    out.guestCard = b.card;
    out.guestLine = b.engineLine;
    assert.equal(started, false, label + ": START with no shared engine");
    assert.equal(out.written, false, label + ": nothing written");
    results.scenarios.push(out);
    for (const [p, k] of [[hostP, h], [guestP, g]]) await p.call({ op: "leave", key: k });
    return out;
  }
  assert.equal(started, true, label + ": START");
  await until(async () => (await st(guestP, g)).state === "match", label + " guest in match");
  const sides = [
    [hostP, h],
    [guestP, g],
  ];
  const doc0 = (await st(hostP, h)).doc;
  out.matchEngine = doc0.match.engine;
  assert.equal(doc0.match.engine, expect, label + ": match.engine");
  out.engines = [];
  for (const [p, k] of sides) {
    const s = await st(p, k);
    out.engines.push({ probe: p.which, engine: s.engine, loaded: s.loaded, board: s.boardEngine });
    if (s.engine) assert.equal(mm(s.engine), expect, label + ": " + p.which + " plays on the match's engine");
  }
  out.actions = [];
  let thrown = 0;
  for (let step = 0; thrown < throws && step < 60; step++) {
    let actor;
    for (const [p, k] of sides) {
      if (screen(p)) await p.call({ op: "skip", key: k });
      const s = await st(p, k);
      if (s.mayAct) actor = [p, k, s];
    }
    if (!actor) {
      await new Promise((r) => setTimeout(r, 20));
      continue;
    }
    const [p, k, s] = actor;
    if (s.need.kind === "over") break;
    let action,
      near = false,
      diverges;
    if (s.need.kind === "throw") {
      action = await planner.call({ op: "plan", snap: s.doc.match.snap, minor: expect });
      if (action.how === "baton" && nearAt.includes(thrown)) {
        action = shortBaton(action, 1.25);
        near = true;
        const both = carriedHere.filter((x) => ["0.7", "0.8"].includes(x));
        if (both.length === 2)
          diverges = await planner.call({ op: "applyOn", snap: s.doc.match.snap, action, minors: both });
      }
      thrown++;
      const ok = await p.call({ op: screen(p) ? "act" : "take", key: k, action });
      assert.ok(ok !== false, label + ": action taken");
    } else {
      const r = await p.call({ op: "computer", key: k });
      action = r.action;
      assert.equal(r.ok, true);
    }
    const seq = s.seq + 1;
    let hashes;
    await until(async () => {
      const all = [];
      for (const [q, kk] of sides) {
        if (screen(q)) await q.call({ op: "skip", key: kk });
        all.push(await st(q, kk));
      }
      if (!all.every((x) => x.seq >= seq && x.doc.match.seq >= seq)) return false;
      hashes = all.map((x) => ({ probe: x === all[0] ? sides[0][0].which : sides[1][0].which, hash: x.hash, display: x.displayHash, room: x.doc.match.hash, corrections: x.corrections, displayCorrections: x.displayCorrections }));
      return true;
    }, label + " action " + seq);
    const room = hashes[0].room;
    const agree = hashes.every((x) => x.hash === room && (x.display == null || x.display === room) && x.corrections === 0 && x.displayCorrections === 0);
    out.actions.push({ seq, type: action.type, how: action.how ?? null, near, by: p.which, room, agree, diverges, hashes });
    assert.ok(agree, `${label}: hashes after action ${seq}: ${JSON.stringify(hashes)}`);
  }
  out.near = out.actions.filter((a) => a.near).length;
  out.allAgree = out.actions.every((a) => a.agree);
  assert.ok(out.near > 0, label + ": at least one short baton");
  results.scenarios.push(out);
  for (const [p, k] of sides) await p.call({ op: "leave", key: k });
  return out;
}

const shared = carriedHere.includes(mm(versions.old)) ? mm(versions.old) : null;
const summary = [];
try {
  for (const [label, hostP, guestP, expect] of [
    ["new-hosts-old-joins", procs.new, procs.old, shared],
    ["old-hosts-new-joins", procs.old, procs.new, shared],
    ["new-and-new", procs.new, procs.new2, carriedHere[0]],
  ]) {
    const o = await scenario(label, hostP, guestP, { expect });
    summary.push(
      expect === null
        ? `${label}: refused=${o.refused} written=${o.written} host note="${o.hostNote}" guest card=${o.guestCard} guest line="${o.guestLine ?? ""}"`
        : `${label}: match on ${o.matchEngine}, ${o.actions.length} actions, ${o.near} short batons, all agree=${o.allAgree}`,
    );
  }
} finally {
  mkdirSync(join(root, "build"), { recursive: true });
  writeFileSync(join(root, "build/engines-results.json"), JSON.stringify(results, null, 2) + "\n");
  for (const p of Object.values(procs)) p.child.stdin.end();
  await server.close?.();
}
console.log(summary.join("\n"));
process.exit(0);
