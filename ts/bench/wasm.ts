// wasm.ts — the bench for packages/brd14-wasm (bench/README.md protocol).
//
//   env -u BUN_OPTIONS -u NODE_OPTIONS taskset -c 2 node ts/bench/wasm.ts → bench/results/ts-wasm-node-<v>.json
//   env -u BUN_OPTIONS -u NODE_OPTIONS taskset -c 2 bun  ts/bench/wasm.ts → bench/results/ts-wasm-bun-<v>.json
//
// Required ops: encode, decode, hash32 (one ABI crossing per id). Variant ops:
// encode_many, encode_many_into, decode_many — one crossing per 2,978-id chunk,
// reported per id (measure() divides a corpus pass by 4096). pure_encode and
// pure_decode run the pure package in the same process, so the wasm-vs-pure
// ratio is measured under identical conditions rather than across files.
//
// Batch ops use one namespace for the whole corpus ("USR"), because a batch call
// takes one namespace; the per-id ops use each row's own.

import { decode, decodeMany, encode, encodeMany, encodeManyInto, hash32 } from "brd14-wasm";
import { decode as pureDecode, encode as pureEncode } from "brd14";
import { do_not_optimize } from "mitata";
import { CORPUS_ROWS, feed, loadCorpus, measure, printTable, writeReport, type Op } from "./report.ts";

const C = loadCorpus();
const N = CORPUS_ROWS;
const snows = BigInt64Array.from(C.snow);
const usrIds = Array.from(C.snow, (s) => pureEncode("USR", s));
const usrBytes = new Uint8Array(N * 14);
for (let i = 0; i < N; i++) for (let j = 0; j < 14; j++) usrBytes[i * 14 + j] = usrIds[i]!.charCodeAt(j);
const out = new Uint8Array(N * 14);

const ops: Op[] = [
  { name: "encode", pass: () => { for (let i = 0; i < N; i++) feed(encode(C.ns[i]!, C.snow[i]!).charCodeAt(13)); } },
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
  { name: "hash32", pass: () => { for (let i = 0; i < N; i++) feed(hash32(C.snow[i]!)); } },
  { name: "encode_many", pass: () => { const ids = encodeMany("USR", snows); feed(ids[N - 1]!.charCodeAt(13)); } },
  { name: "encode_many_into", pass: () => { feed(encodeManyInto("USR", snows, out)); feed(out[N * 14 - 1]!); } },
  { name: "decode_many", pass: () => { const v = decodeMany(usrBytes); do_not_optimize(v); feed(Number(v[N - 1]! & 0xffn)); } },
  { name: "pure_encode", pass: () => { for (let i = 0; i < N; i++) feed(pureEncode(C.ns[i]!, C.snow[i]!).charCodeAt(13)); } },
  {
    name: "pure_decode",
    pass: () => {
      for (let i = 0; i < N; i++) {
        const r = pureDecode(C.id[i]!);
        do_not_optimize(r.snow);
        feed(r.ns.charCodeAt(0));
      }
    },
  },
];

// Every op must agree with the corpus before it is timed.
for (let i = 0; i < N; i++) {
  if (encode(C.ns[i]!, C.snow[i]!) !== C.id[i]) throw new Error("encode disagrees with the corpus");
  if (decode(C.id[i]!).snow !== C.snow[i]) throw new Error("decode disagrees with the corpus");
  if (hash32(C.snow[i]!) !== C.hash32[i]) throw new Error("hash32 disagrees with the corpus");
}
const many = encodeMany("USR", snows);
const back = decodeMany(usrBytes);
for (let i = 0; i < N; i++) {
  if (many[i] !== usrIds[i] || back[i] !== C.snow[i]) throw new Error("batch ops disagree with the corpus");
}

const results = await measure(ops, process.argv.includes("--quiet"));
// "vs naive" column: here the baseline is the pure package, measured in this process.
printTable(results, { encode: "pure_encode", encode_many: "pure_encode", encode_many_into: "pure_encode", decode: "pure_decode", decode_many: "pure_decode" });
const path = writeReport("ts", "wasm", results);
console.log(`\nwrote ${path}`);
