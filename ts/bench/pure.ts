// pure.ts — the bench for packages/brd14 (bench/README.md protocol).
//
//   taskset -c 2 node ts/bench/pure.ts     → bench/results/ts-pure-node-<v>.json
//   taskset -c 2 bun  ts/bench/pure.ts     → bench/results/ts-pure-bun-<v>.json
//
// Required ops: encode, decode, hash32, mint. Variant ops: encode_parts,
// encode_into, decode_parts, decode_bytes, hash32_parts, valid. Baselines:
// naive_encode, naive_decode, naive_hash32 — the same contract written on
// BigInt (packages/brd14/test/naive.ts), so the speedup of the hi/lo design is
// measured in-language, in the same process.

import { Generator, decode, decodePartsInto, encode, encodeInto, encodeParts, hash32, hash32Parts, isValid } from "brd14";
import { naiveDecode, naiveEncode, naiveHash32 } from "../packages/brd14/test/naive.ts";
import { do_not_optimize } from "mitata";
import { CORPUS_ROWS, feed, loadCorpus, measure, printTable, writeReport, type Op } from "./report.ts";

const C = loadCorpus();
const N = CORPUS_ROWS;
const buf = new Uint8Array(14);
const out = { ns: "", ts: 0, node: 0, seq: 0 };
const gen = new Generator(42);

const ops: Op[] = [
  {
    name: "encode",
    pass: () => {
      for (let i = 0; i < N; i++) feed(encode(C.ns[i]!, C.snow[i]!).charCodeAt(13));
    },
  },
  {
    name: "encode_parts",
    pass: () => {
      for (let i = 0; i < N; i++) feed(encodeParts(C.ns[i]!, C.ts[i]!, C.node[i]!, C.seq[i]!).charCodeAt(13));
    },
  },
  {
    name: "encode_into",
    pass: () => {
      for (let i = 0; i < N; i++) {
        encodeInto(buf, 0, C.ns[i]!, C.snow[i]!);
        feed(buf[13]!);
      }
    },
  },
  {
    name: "decode",
    pass: () => {
      for (let i = 0; i < N; i++) {
        const r = decode(C.id[i]!);
        do_not_optimize(r.snow);
        feed(r.ns.charCodeAt(0));
      }
    },
  },
  {
    name: "decode_parts",
    pass: () => {
      for (let i = 0; i < N; i++) feed(decodePartsInto(C.id[i]!, out).seq);
    },
  },
  {
    name: "decode_bytes",
    pass: () => {
      for (let i = 0; i < N; i++) {
        const r = decode(C.idBytes[i]!);
        do_not_optimize(r.snow);
        feed(r.ns.charCodeAt(0));
      }
    },
  },
  {
    name: "valid",
    pass: () => {
      for (let i = 0; i < N; i++) feed(isValid(C.id[i]!) ? 1 : 0);
    },
  },
  {
    name: "hash32",
    pass: () => {
      for (let i = 0; i < N; i++) feed(hash32(C.snow[i]!));
    },
  },
  {
    name: "hash32_parts",
    pass: () => {
      for (let i = 0; i < N; i++) feed(hash32Parts(C.hi[i]!, C.lo[i]!));
    },
  },
  {
    name: "mint",
    pass: () => {
      for (let i = 0; i < N; i++) feed(gen.nextBranded("USR").charCodeAt(13));
    },
  },
  {
    name: "naive_encode",
    pass: () => {
      for (let i = 0; i < N; i++) feed(naiveEncode(C.ns[i]!, C.snow[i]!).charCodeAt(13));
    },
  },
  {
    name: "naive_decode",
    pass: () => {
      for (let i = 0; i < N; i++) {
        const r = naiveDecode(C.id[i]!);
        do_not_optimize(r.snow);
        feed(r.ns.charCodeAt(0));
      }
    },
  },
  {
    name: "naive_hash32",
    pass: () => {
      for (let i = 0; i < N; i++) feed(naiveHash32(C.snow[i]!));
    },
  },
];

// Every op must agree with the corpus before it is timed.
for (let i = 0; i < N; i++) {
  if (encode(C.ns[i]!, C.snow[i]!) !== C.id[i] || naiveEncode(C.ns[i]!, C.snow[i]!) !== C.id[i]) throw new Error("encode disagrees with the corpus");
  if (decode(C.id[i]!).snow !== C.snow[i] || naiveDecode(C.id[i]!).snow !== C.snow[i]) throw new Error("decode disagrees with the corpus");
  if (hash32(C.snow[i]!) !== C.hash32[i] || naiveHash32(C.snow[i]!) !== C.hash32[i]) throw new Error("hash32 disagrees with the corpus");
}

const results = await measure(ops, process.argv.includes("--quiet"));
printTable(results, {
  encode: "naive_encode",
  encode_parts: "naive_encode",
  encode_into: "naive_encode",
  decode: "naive_decode",
  decode_parts: "naive_decode",
  decode_bytes: "naive_decode",
  hash32: "naive_hash32",
  hash32_parts: "naive_hash32",
});
const path = writeReport("ts", "pure", results);
console.log(`\nwrote ${path}`);
