#!/usr/bin/env node
// Shared test vectors for the Swift rooms client, made by the web's own client code
// (src/net/room.js in the kubb.thingelstad.xyz checkout, which this only reads):
// asciiJson of every kind of value (emoji, lone surrogates, controls, numbers), its
// size as JavaScript counts it, number formatting, frames and chunking, putting parts
// back together, and what a string holds once read (as the engine is handed it).
//
//   node tools/room-vectors.mjs [--web ../kubb.thingelstad.xyz]
//
// writes ThrowingWoodKit/Tests/KubbRoomsTests/Fixtures/vectors.json. Deterministic: the
// same web code gives the same file (the part ids come from a seeded generator put in
// place of crypto.getRandomValues while toFrames runs).
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
const room = await import(pathToFileURL(join(web, "src/net/room.js")).href);
const { asciiJson, toFrames, Room } = room;
let webCommit = "unknown";
try {
  webCommit = execFileSync("git", ["-C", web, "rev-parse", "HEAD"], {
    encoding: "utf8",
  }).trim();
} catch {}

// ---------- a seeded generator (mulberry32) ----------
function rng(seed) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// ---------- values, described so Swift can build the same one ----------
// { type: "null" | "bool" | "number" | "string" | "array" | "object", ... }
// numbers by their bits (no decimal text to misread), strings by UTF-16 code units.
const bitsOf = (x) => {
  const v = new DataView(new ArrayBuffer(8));
  v.setFloat64(0, x);
  return "0x" + v.getBigUint64(0).toString(16).padStart(16, "0");
};
const units = (s) =>
  Array.from({ length: s.length }, (_, i) => s.charCodeAt(i));
function describe(v) {
  if (v === null) return { type: "null" };
  if (typeof v === "boolean") return { type: "bool", value: v };
  if (typeof v === "number") return { type: "number", bits: bitsOf(v) };
  if (typeof v === "string") return { type: "string", units: units(v) };
  if (Array.isArray(v)) return { type: "array", items: v.map(describe) };
  return {
    type: "object",
    members: Object.entries(v).map(([k, x]) => [units(k), describe(x)]),
  };
}

const S = String.fromCharCode;
const strings = [
  "",
  "plain ascii",
  'quote " backslash \\ slash /',
  "controls \b\f\n\r\t" + S(0) + S(1) + S(0x1f),
  "tilde ~ and DEL " + S(0x7f),
  "latin é ß ü",
  "U+0080 " + S(0x80) + " U+00FF " + S(0xff),
  "line separators " + S(0x2028) + S(0x2029),
  "BOM " + S(0xfeff) + " U+FFFF " + S(0xffff),
  "emoji 🎯 pair 🪵",
  "flag 🇸🇪 family 👨‍👩‍👧",
  "lone high " + S(0xd83c) + " end",
  "lone low " + S(0xdfaf) + " end",
  "reversed pair " + S(0xdfaf) + S(0xd83c),
  "high at end " + S(0xd800),
  S(0xdc00) + " low at start",
  "two highs " + S(0xd800) + S(0xd801) + S(0xdc01),
  "Åsa Öberg",
  "Ελληνικά 日本語 العربية",
  "Player 1234567🎯", // a 16-unit name with an emoji at the cut
];
const numbers = [
  0,
  -0,
  1,
  -1,
  3,
  0.5,
  0.1,
  0.1 + 0.2,
  1 / 3,
  2 / 3,
  100,
  1e6,
  123456789,
  2 ** 31,
  2 ** 53,
  2 ** 53 + 2,
  -(2 ** 53),
  1e20,
  1e21,
  1.5e21,
  1e22,
  1e-6,
  1e-7,
  1.5e-7,
  0.000001234,
  0.0000001234,
  5e-324,
  2.2250738585072014e-308,
  1.7976931348623157e308,
  123e-20,
  4.35,
  0.016666666666666666,
  1 / 60,
  -15,
  -180,
  179.99999999999997,
  1234567890123456800000,
  12345678901234567,
  0.1 * 3,
  9007199254740993,
  1e300 * 10,
  Math.PI,
  Math.E,
  -0.0001,
  25.5,
];
const r = rng(20261117);
for (let i = 0; i < 200; i++) {
  const e = Math.floor(r() * 60) - 30;
  numbers.push((r() - 0.5) * 10 ** e);
}
for (let i = 0; i < 50; i++)
  numbers.push(Math.round((r() - 0.5) * 3600 * 1000) / 1000);

const values = [
  ...strings,
  ...numbers.filter(Number.isFinite),
  null,
  true,
  false,
  [],
  {},
  [1, "a", null, [true, { b: 2 }]],
  {
    t: "join",
    room: "abcdefghjk",
    member: "Member_Id-01",
    me: { name: "Åsa 🎯" },
  },
  { z: 1, a: 2, m: { y: [], x: {} }, "": "empty key", é: "non-ascii key" },
  { 1: "integer-like keys", 10: "come first", b: 1, a: 0 },
  { snap: JSON.stringify({ a: 3.5, b: "Å" }), hash: "0a1b2c3d" },
];

const ascii = values.map((v) => {
  const text = asciiJson(v);
  return { value: describe(v), text, length: text.length };
});

// asciiJson of NaN and the infinities: null, as JSON.stringify writes them.
const specialNumbers = [NaN, Infinity, -Infinity].map((x) => ({
  bits: bitsOf(x),
  text: asciiJson(x),
}));

// Number::toString through JSON.stringify for every number above.
const numberText = numbers.map((x) => ({
  bits: bitsOf(x),
  text: JSON.stringify(x),
}));

// Raw JSON (as JSON.stringify writes it, non-ASCII left in) made ASCII without parsing,
// against asciiJson of the value. Only for text with no lone surrogate: JSON.stringify
// escapes those itself.
const asciify = values
  .filter(
    (v) =>
      !/[\ud800-\udfff]/.test(JSON.stringify(v)) ||
      /\p{Extended_Pictographic}/u.test(JSON.stringify(v)),
  )
  .filter(
    (v) =>
      !/(?:[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff])/.test(
        JSON.stringify(v),
      ),
  )
  .map((v) => ({ raw: JSON.stringify(v), text: asciiJson(v) }));

// What a string holds once JSON.parse has read it and TextEncoder has made it UTF-8
// (wasmoon hands the engine a string that way): a lone surrogate is U+FFFD.
const enc = new TextEncoder();
const hex = (bytes) => Buffer.from(bytes).toString("hex");
const readStrings = strings.map((s) => {
  const text = asciiJson(s);
  return { text, utf8: hex(enc.encode(JSON.parse(text))) };
});

// ---------- frames ----------
// toFrames with the part ids from a seeded generator in place of crypto's.
function seededFrames(text, frame, seed) {
  const real = globalThis.crypto.getRandomValues.bind(globalThis.crypto);
  const g = rng(seed);
  globalThis.crypto.getRandomValues = (a) => {
    for (let i = 0; i < a.length; i++) a[i] = Math.floor(g() * 256);
    return a;
  };
  try {
    return toFrames(text, frame);
  } finally {
    globalThis.crypto.getRandomValues = real;
  }
}
const alphabet =
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 {}[]:,"\\~.';
function textOf(n, g) {
  let s = "";
  for (let i = 0; i < n; i++) s += alphabet[Math.floor(g() * alphabet.length)];
  return s;
}
const fg = rng(7);
const frameCases = [];
const shapes = [
  [0, 100],
  [1, 100],
  [100, 100],
  [101, 100],
  [60, 100],
  [61, 100],
  [120, 100],
  [121, 100],
  [599, 100],
  [600, 100],
  [601, 100],
  [29_999, 30_000],
  [30_000, 30_000],
  [30_001, 30_000],
  [59_920, 30_000],
  [59_921, 30_000],
  [262_144, 30_000],
  [300 * 1024, 30_000],
  [5000, 1000],
];
for (const [len, frame] of shapes) {
  // a whole message starts with "{" (the reader takes a "~" for a part)
  const text = len ? "{" + textOf(len - 1, fg) : "";
  const frames = seededFrames(text, frame, len * 31 + frame);
  frameCases.push({
    length: len,
    frame,
    text,
    id: frames.length > 1 ? frames[0].slice(1, frames[0].indexOf(".")) : null,
    frames,
  });
}

// ---------- putting parts back together ----------
// Room's own reader, fed frames through a stand-in socket.
function reader() {
  class FakeSocket {
    constructor() {
      this.readyState = 0;
      FakeSocket.last = this;
    }
    send() {}
    close() {}
  }
  const got = [];
  const r = new Room({
    url: "ws://127.0.0.1:1",
    room: "abcdefghjk",
    member: "Member_Id-01",
    WebSocket: FakeSocket,
  });
  r._message = (msg) => got.push(JSON.stringify(msg));
  const ws = FakeSocket.last;
  return {
    feed(frames) {
      for (const f of frames) ws.onmessage({ data: f });
      return got.splice(0);
    },
    close() {
      r.close();
    },
  };
}
const joinCases = [];
const jg = rng(11);
const shuffle = (a) => {
  const b = [...a];
  for (let i = b.length - 1; i > 0; i--) {
    const j = Math.floor(jg() * (i + 1));
    [b[i], b[j]] = [b[j], b[i]];
  }
  return b;
};
const msgText = (n) =>
  asciiJson({
    t: "doc",
    v: n,
    by: "Member_Id-01",
    doc: { blob: textOf(n, jg), name: "Åsa 🎯" },
  });
{
  const rd = reader();
  const add = (name, frames) =>
    joinCases.push({ name, frames, messages: rd.feed(frames) });
  const one = seededFrames(msgText(250), 100, 1);
  add("in order", one);
  add("reversed", [...one].reverse());
  add("shuffled", shuffle(seededFrames(msgText(400), 100, 2)));
  const a = seededFrames(msgText(300), 100, 3);
  const b = seededFrames(msgText(320), 100, 4);
  const mixed = [];
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    if (b[i]) mixed.push(b[i]);
    if (a[i]) mixed.push(a[i]);
  }
  add("two messages interleaved", mixed);
  add("a whole message between parts", [
    ...one.slice(0, 2),
    asciiJson({ t: "pong", now: 1 }),
    ...one.slice(2),
  ]);
  add("not a part: dropped", [
    "~ABC.0.2~upper-case id",
    "~abc.x.2~not a number",
    "~abcdefghijklmnopq.0.2~id too long",
    "~abc.0.2 no closing tilde",
    "~abc.1234.2~four digits",
  ]);
  add("not JSON: dropped", ["{not json", asciiJson({ t: "pong", now: 2 })]);
  add("a part twice", [one[0], ...one]);
  rd.close();
}

const out = {
  about:
    "Made by tools/room-vectors.mjs from the web's src/net/room.js (asciiJson, toFrames, Room's part reader). Values are described by type; numbers by their IEEE-754 bits, strings by UTF-16 code units.",
  webCommit,
  ascii,
  specialNumbers,
  numberText,
  asciify,
  readStrings,
  frames: frameCases,
  join: joinCases,
};
const file = join(
  root,
  "ThrowingWoodKit/Tests/KubbRoomsTests/Fixtures/vectors.json",
);
writeFileSync(file, JSON.stringify(out, null, 1) + "\n");
console.log(
  `vectors: ${ascii.length} asciiJson, ${specialNumbers.length + numberText.length} numbers, ${asciify.length} asciify, ${readStrings.length} read strings, ${frameCases.length} split, ${joinCases.length} join cases -> ${file.slice(root.length + 1)}`,
);
