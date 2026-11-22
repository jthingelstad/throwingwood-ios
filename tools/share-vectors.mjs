#!/usr/bin/env node
// Shared test vectors for sharing a match against the computer, made by the web's own
// code (src/net/share.js and tools/reel/solo.mjs in a kubb.thingelstad.xyz checkout,
// which this only reads): a short seeded match a person played against the computer,
// the web's `share` message for it under a few names, what the name rules say of many
// names, the field's first value, the clipped name, the card's words, and the card's
// states for walks of events (the web's pure reducer).
//
//   node tools/share-vectors.mjs [--web ../kubb.thingelstad.xyz]
//
// writes ThrowingWoodKit/Tests/KubbPitchTests/Fixtures/share-vectors.json. Deterministic:
// the match is seeded and the web's engine plays it the same way every time. Only
// invented names ("Riverside", the web's fixture team, and the names below).
import { writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, "..");
const arg = process.argv.indexOf("--web");
const web = resolve(
  arg > 0
    ? process.argv[arg + 1]
    : (process.env.KUBB_WEB ?? join(root, "..", "kubb.thingelstad.xyz")),
);
const fromWeb = (p) => import(pathToFileURL(join(web, p)).href);
const share = await fromWeb("src/net/share.js");
const { Engine } = await fromWeb("src/engine/index.js");
const { useRoomEngine, LOG_BUDGET } = await fromWeb("src/net/lobby.js");
const { bundleLua, engineVersion } = await fromWeb("tools/lua-bundle.mjs");
const { playSolo, soloSetup } = await fromWeb("tools/reel/solo.mjs");
const { asciiJson } = await fromWeb("src/net/pitch-client.js");
let webCommit = "unknown";
try {
  webCommit = execFileSync("git", ["-C", web, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim();
} catch {}

const sources = bundleLua();
const engine = await Engine.create({ sources });
useRoomEngine(engine);
const played = await playSolo(soloSetup(2), sources);
useRoomEngine(engine);
const trail = {
  kind: "match",
  start: played.start,
  actions: played.log.map((e) => e.a),
  hashes: [],
  now: "",
};
const need = { kind: "over", winner: { winner: played.end.winner } };

const messages = ["Lakeside", "Ünïcödé 🪵"].map((name) => {
  const made = share.shareMessage({ engine, trail, need, name });
  if (!made.message) throw new Error(`no message for ${name}: ${made.why}`);
  return { name, g: made.message.g, bytes: made.bytes };
});

const names = [
  "Ann", "Riverside", "a".repeat(16), "Ünïcödé 🪵", "", "   ", " Ann", "Ann ", "You",
  "YOU", "yOu", " you", "a".repeat(17), "🪵".repeat(16), "🪵".repeat(17), "é".repeat(8),
  "é".repeat(9), "\tAnn", "Ann\n", "Y o u", "Yous",
].map((name) => ({ name, problem: share.nameProblem(name) }));

const withName = (n) => {
  const s = JSON.parse(played.start);
  s.opts.teams.A.name = n;
  return JSON.stringify(s);
};
const fromMatch = [
  played.start, withName("You"), withName("you"), withName(" Pine "), withName(""),
  withName("a".repeat(20)), "not json",
].map((start) => ({ start, name: share.nameFromMatch(start) }));

const clips = ["🪵".repeat(20), "abcdefghijklmnopqrs", "Ann", "é".repeat(10)].map(
  (text) => ({ text, clipped: share.clipName(text) }),
);

// Walks of the card's states, with what the card shows after each event.
const send = { type: "send" };
const answer = (a) => ({ type: "answer", answer: a });
const error = (code) => ({ type: "error", code });
const open = { type: "open" };
const walks = [
  [send],
  [send, answer({ t: "shared", code: "abcdefgh23", v: 1 })],
  ...["engine", "does-not-replay", "busy", "too-long", "unavailable", "something-new"].map(
    (why) => [send, answer({ t: "shared", code: null, v: 0, why }), open],
  ),
  [send, answer({ t: "shared", code: null, v: 0 })],
  [send, error("too-many"), open],
  [send, error("too-big"), open],
  [send, error("bad-message"), open],
  [send, error("failed"), send, error("failed"), send, open],
  [send, error("failed"), send, answer({ t: "shared", code: "abcdefgh23", v: 1 })],
  [send, error("timeout"), send, error("closed"), send, error("unavailable"), send],
  [send, error("odd-code")],
  [{ type: "refuse", why: "too-long" }, open, send],
  [send, send, open, { type: "refuse", why: "busy" }],
].map((events) => {
  let s = share.shareStart();
  const views = events.map((e) => {
    s = share.shareStep(s, e);
    return share.shareView(s);
  });
  return { events, views };
});

const out = {
  made: "node tools/share-vectors.mjs",
  webCommit,
  webEngine: engineVersion(),
  limits: share.SHARE_LIMITS,
  url: share.SHARE_URL,
  logBudget: LOG_BUDGET,
  words: share.SHARE_WORDS,
  match: {
    start: played.start,
    actions: trail.actions,
    winner: played.end.winner,
    throws: played.end.throws,
  },
  messages,
  names,
  fromMatch,
  clips,
  walks,
  asciiCheck: asciiJson({ t: "share", id: 1, g: messages[1].g }).length,
};
const file = join(root, "ThrowingWoodKit/Tests/KubbPitchTests/Fixtures/share-vectors.json");
writeFileSync(file, JSON.stringify(out, null, 1) + "\n");
console.log(
  `share vectors: ${trail.actions.length} actions, ${played.end.throws} throws, ` +
    `${messages.map((m) => m.bytes).join(" and ")} bytes -> ${file}`,
);
engine.lua.global.close();
