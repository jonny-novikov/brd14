// check.mjs — verify a built brd14_wasm.wasm against the WebAssembly ABI of docs/contract.md
// through its raw exports only (no loader, no TypeScript):
//
//   node crates/brd14-wasm/check.mjs [--bench] [module.wasm ...]
//
// For each module: the import list is empty, the exports are exactly the ABI (+ memory)
// with the right arities, memory is fixed (grow fails, byteLength never changes), the
// contract vectors V-1..V-6 pass, and — when the repository's vectors/ is present — every
// row of valid.tsv, invalid.tsv and encode_invalid.tsv passes too (skipped when absent,
// a failure when absent and BRD14_REQUIRE_VECTORS=1). --bench adds a quick speed check.
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { performance } from "node:perf_hooks";

const here = dirname(fileURLToPath(import.meta.url));
const rustRoot = resolve(here, "../..");
const repoRoot = resolve(rustRoot, "../..");
const args = process.argv.slice(2);
const bench = args.includes("--bench");
const paths = args.filter((a) => a !== "--bench");
if (paths.length === 0) paths.push(join(rustRoot, "target/wasm32-unknown-unknown/release/brd14_wasm.wasm"));

const ABI = { io_ptr: 0, encode: 2, decode: 1, hash32: 1, encode_many: 2, decode_many: 1 };
const MAX_SNOW = (1n << 63n) - 1n;
const CLASS = { 1: "LENGTH", 2: "NAMESPACE", 3: "CHARSET", 4: "RANGE" };
const enc = new TextEncoder();
const dec = new TextDecoder();

let failures = 0;
function check(cond, what) {
  if (!cond) {
    failures++;
    console.error(`  FAIL ${what}`);
  }
}

const pack = (ns) => (ns.length === 3 ? ns[0] | (ns[1] << 8) | (ns[2] << 16) : 0);
const unhex = (s) => (s === "-" ? new Uint8Array(0) : Uint8Array.from(s.match(/../g).map((h) => parseInt(h, 16))));

function rows(name) {
  const dir = process.env.BRD14_VECTORS_DIR ?? join(repoRoot, "vectors");
  if (!existsSync(dir)) {
    if (process.env.BRD14_REQUIRE_VECTORS === "1") throw new Error(`vectors/ not found at ${dir} and BRD14_REQUIRE_VECTORS=1`);
    return null;
  }
  return readFileSync(join(dir, name), "utf8")
    .split("\n")
    .filter((l) => l && !l.startsWith("#"))
    .map((l) => l.split("\t"));
}

function verify(path) {
  const bytes = readFileSync(path);
  const mod = new WebAssembly.Module(bytes);
  console.log(`${path}\n  size ${bytes.length} bytes`);

  // 1. no imports
  const imports = WebAssembly.Module.imports(mod);
  check(imports.length === 0, `imports must be empty, got ${JSON.stringify(imports)}`);

  // 2. exports are exactly the ABI plus the memory
  const exports = WebAssembly.Module.exports(mod);
  const names = exports.map((e) => e.name).sort();
  const want = [...Object.keys(ABI), "memory"].sort();
  check(JSON.stringify(names) === JSON.stringify(want), `exports ${JSON.stringify(names)} != ${JSON.stringify(want)}`);
  const { exports: x } = new WebAssembly.Instance(mod, {});
  for (const [name, arity] of Object.entries(ABI)) {
    check(typeof x[name] === "function" && x[name].length === arity, `${name} must be a function of ${arity} params`);
  }
  check(x.memory instanceof WebAssembly.Memory, "memory must be exported");

  // 3. fixed memory: grow fails, byteLength never changes, views never detach
  const mem = x.memory;
  const size = mem.buffer.byteLength;
  const view = new Uint8Array(mem.buffer);
  let grew = false;
  try {
    mem.grow(1);
    grew = true;
  } catch {}
  check(!grew && mem.buffer.byteLength === size, `memory must be fixed (byteLength ${size}, grow ${grew ? "succeeded" : "refused"})`);
  const io = x.io_ptr();
  check(io % 16 === 0 && io + 65536 <= size, `IO region [${io}, ${io + 65536}) inside ${size} bytes, 16-aligned`);
  const IO = new Uint8Array(mem.buffer, io, 65536);
  const IO64 = new BigInt64Array(mem.buffer, io, 8192);
  console.log(`  memory ${size} bytes fixed (${size / 65536} pages), io_ptr ${io}`);

  const encode = (ns, snow) => {
    const st = x.encode(pack(ns), snow > MAX_SNOW || snow < 0n ? -1n : snow);
    return st === 0 ? dec.decode(IO.slice(0, 14)) : CLASS[st] ?? `status ${st}`;
  };
  const decode = (id) => {
    IO.set(id.subarray(0, Math.min(id.length, 65536)));
    const r = x.decode(id.length);
    return r >= 0n ? `${dec.decode(IO.slice(0, 3))} ${r}` : CLASS[Number(-r)] ?? `code ${r}`;
  };

  // 4. the contract vectors through the raw exports
  check(encode(enc.encode("USR"), 274557032793636864n) === "USR0KHTOWnGLuC", "V-1 encode");
  check(decode(enc.encode("USR0KHTOWnGLuC")) === "USR 274557032793636864", "V-1 decode");
  check(decode(enc.encode("USR0NgWEfAEJfs")) === "USR 320636799581945856", "V-2");
  check(encode(enc.encode("ABC"), 0n) === "ABC00000000000", "V-3");
  check(encode(enc.encode("ABC"), MAX_SNOW) === "ABCAzL8n0Y58m7", "V-4");
  check(decode(enc.encode("USRzzzzzzzzzzz")) === "RANGE", "V-5 range");
  check(decode(enc.encode("usr0KHTOWnGLuC")) === "NAMESPACE", "V-5 namespace");
  check(decode(enc.encode("USR0KHTOWnGLu")) === "LENGTH", "V-5 13 bytes");
  check(decode(enc.encode("USR0KHTOWnGLuCC")) === "LENGTH", "V-5 15 bytes");
  check(x.hash32(274557032793636864n) >>> 0 === 234878118, "V-6");
  check(encode(enc.encode("usr"), 1n << 63n) === "NAMESPACE", "precedence: NAMESPACE before RANGE");
  check(decode(enc.encode("USRzzzzzzzzzz!")) === "CHARSET", "precedence: CHARSET before RANGE");

  // 5. the frozen corpus, when present
  const valid = rows("valid.tsv");
  if (valid === null) {
    console.log("  SKIP vectors/: not found");
  } else {
    let n = 0;
    for (const [ns, snow, id, h] of valid) {
      const s = BigInt(snow);
      check(encode(enc.encode(ns), s) === id, `valid encode ${ns} ${snow}`);
      check(decode(enc.encode(id)) === `${ns} ${snow}`, `valid decode ${id}`);
      check(x.hash32(BigInt.asIntN(64, s)) >>> 0 === Number(h), `valid hash32 ${snow}`);
      n++;
    }
    for (const [idHex, cls] of rows("invalid.tsv")) {
      check(decode(unhex(idHex)) === cls, `invalid ${idHex} -> ${cls}`);
      n++;
    }
    for (const [nsHex, snow, cls] of rows("encode_invalid.tsv")) {
      const ns = unhex(nsHex);
      // the ABI cannot see a length: like any caller, refuse a non-3-byte ns before encode
      const got = ns.length === 3 ? encode(ns, BigInt(snow)) : "NAMESPACE";
      check(got === cls, `encode_invalid ${nsHex} ${snow} -> ${cls} (got ${got})`);
      n++;
    }
    // the batch exports over the whole valid corpus, in BATCH_MAX chunks
    const BATCH = 2978;
    for (let at = 0; at < valid.length; at += BATCH) {
      const chunk = valid.slice(at, at + BATCH);
      chunk.forEach(([, snow], i) => (IO64[i] = BigInt(snow)));
      const k = chunk.length;
      check(x.encode_many(pack(enc.encode(chunk[0][0])), k) === k, `encode_many ${k}`);
      const out = dec.decode(IO.slice(8 * k, 8 * k + 14 * k));
      chunk.forEach(([, snow], i) => check(out.slice(14 * i + 3, 14 * i + 14) === chunk[i][2].slice(3), `encode_many row ${at + i}`));
      chunk.forEach(([, , id], i) => IO.set(enc.encode(id), 14 * i));
      check(x.decode_many(k) === k, `decode_many ${k}`);
      const off = (14 * k + 7) & ~7;
      const res = new BigInt64Array(mem.buffer, io + off, k);
      chunk.forEach(([, snow], i) => check(res[i] === BigInt(snow), `decode_many row ${at + i}`));
    }
    console.log(`  vectors/: ${n} rows + batches over ${valid.length} ids`);
  }
  check(mem.buffer.byteLength === size && view.byteLength === size, "memory never grew; old views still attached");

  // 6. a quick speed check through the raw exports
  if (bench && valid !== null) {
    const corpus = valid.slice(0, 4096);
    const snows = corpus.map(([, s]) => BigInt(s));
    const ids = corpus.map(([, , id]) => enc.encode(id));
    const nsPacked = corpus.map(([ns]) => pack(enc.encode(ns)));
    const time = (label, ops, fn) => {
      for (let w = 0; w < 3; w++) fn();
      const samples = [];
      for (let s = 0; s < 11; s++) {
        const t0 = performance.now();
        fn();
        samples.push(((performance.now() - t0) * 1e6) / ops);
      }
      samples.sort((a, b) => a - b);
      console.log(`  ${label.padEnd(26)} ${samples[5].toFixed(1).padStart(7)} ns/op (median of 11)`);
    };
    const R = 64;
    let sink = 0;
    time("encode (raw export)", R * 4096, () => {
      for (let r = 0; r < R; r++) for (let i = 0; i < 4096; i++) sink ^= x.encode(nsPacked[i], snows[i]);
    });
    time("decode (raw export)", R * 4096, () => {
      for (let r = 0; r < R; r++)
        for (let i = 0; i < 4096; i++) {
          IO.set(ids[i]);
          sink ^= Number(x.decode(14) & 1n);
        }
    });
    time("hash32 (raw export)", R * 4096, () => {
      for (let r = 0; r < R; r++) for (let i = 0; i < 4096; i++) sink ^= x.hash32(snows[i]);
    });
    const k = 2978;
    snows.slice(0, k).forEach((s, i) => (IO64[i] = s));
    time("encode_many (per id)", R * k, () => {
      for (let r = 0; r < R; r++) sink ^= x.encode_many(nsPacked[0], k);
    });
    ids.slice(0, k).forEach((id, i) => IO.set(id, 14 * i));
    time("decode_many (per id)", R * k, () => {
      for (let r = 0; r < R; r++) sink ^= x.decode_many(k);
    });
    if (sink === 0.5) console.log(sink);
  }
}

for (const p of paths) verify(p);
if (failures) {
  console.error(`check.mjs: ${failures} failure(s)`);
  process.exit(1);
}
console.log("check.mjs: ok");
