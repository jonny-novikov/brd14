// properties.test.ts — properties over a pinned PRNG: round-trip, V-7
// ordering, agreement between the bigint, parts and bytes APIs, and agreement
// with the naive BigInt oracle in ./naive.ts.

import { describe, expect, test } from "vitest";
import {
  MAX_SNOW,
  check,
  decode,
  decodePartsInto,
  encode,
  encodeInto,
  encodeParts,
  encodePartsInto,
  fields,
  hash32,
  hash32Parts,
  nodeFrom,
  snowFromParts,
  unixMs,
} from "brd14";
import { Rng, encoder } from "./helpers.ts";
import {
  naiveCheck,
  naiveCompose,
  naiveDecode,
  naiveEncode,
  naiveFields,
  naiveHash32,
  naiveNodeFrom,
  naiveUnixMs,
} from "./naive.ts";

const N = 20000;

/** Random values plus the boundaries the arithmetic cares about. */
function corpus(seed: number, n: number): bigint[] {
  const rng = new Rng(seed);
  const out: bigint[] = [0n, 1n, 61n, 62n, 3843n, 3844n, MAX_SNOW - 1n, MAX_SNOW, 1n << 22n, (1n << 41n) - 1n, ((1n << 41n) - 1n) << 22n, 1n << 32n, (1n << 32n) - 1n, 1n << 52n, (1n << 53n) - 1n, 1n << 53n];
  for (let k = 1n; k <= 10n; k++) out.push(62n ** k - 1n, 62n ** k, 62n ** k + 1n);
  for (let i = 0; i < n; i++) out.push(rng.snow());
  // small values and values with a sparse high half, where a split bug would hide
  for (let i = 0; i < 1000; i++) out.push(BigInt(rng.u32()), BigInt(rng.u32() >>> 1) << 32n);
  return out;
}

describe("round-trip", () => {
  test("decode(encode(ns, s)) == (ns, s)", () => {
    const rng = new Rng(1);
    for (const s of corpus(2, N)) {
      const ns = rng.ns();
      const id = encode(ns, s);
      expect(id.length).toBe(14);
      const d = decode(id);
      expect(d.ns).toBe(ns);
      expect(d.snow).toBe(s);
      expect(check(id)).toBe(0);
    }
  });
});

describe("V-7 ordering", () => {
  test("a byte-wise sort of ids reproduces numeric order", () => {
    const values = corpus(3, 5000);
    const sortedValues = [...values].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    const ids = values.map((s) => encode("SES", s));
    const sortedIds = [...ids].sort();
    expect(sortedIds).toEqual(sortedValues.map((s) => encode("SES", s)));
    // and the same through the bytes
    const bytes = values.map((s) => {
      const b = new Uint8Array(14);
      encodeInto(b, 0, "SES", s);
      return b;
    });
    bytes.sort((a, b) => {
      for (let i = 0; i < 14; i++) if (a[i] !== b[i]) return a[i]! - b[i]!;
      return 0;
    });
    expect(bytes.map((b) => decode(b).snow)).toEqual(sortedValues);
  });
});

describe("the APIs agree with each other", () => {
  test("encode == encodeParts(fields) == encodeInto bytes; decode == decodePartsInto", () => {
    const rng = new Rng(4);
    const buf = new Uint8Array(14);
    const buf2 = new Uint8Array(14);
    const out = { ns: "", ts: 0, node: 0, seq: 0 };
    for (const s of corpus(5, N)) {
      const ns = rng.ns();
      const id = encode(ns, s);
      const f = fields(s);
      expect(encodeParts(ns, f.ts, f.node, f.seq)).toBe(id);
      encodeInto(buf, 0, ns, s);
      encodePartsInto(buf2, 0, ns, f.ts, f.node, f.seq);
      expect(buf).toEqual(encoder.encode(id));
      expect(buf2).toEqual(buf);
      decodePartsInto(id, out);
      expect(out).toEqual({ ns, ...f });
      decodePartsInto(buf, out);
      expect(out).toEqual({ ns, ...f });
      expect(snowFromParts(f.ts, f.node, f.seq)).toBe(s);
      expect(unixMs(s)).toBe(f.ts + 1704067200000);
      expect(hash32Parts(Number(s >> 32n), Number(s & 0xffffffffn))).toBe(hash32(s));
    }
  });
});

describe("agreement with the naive BigInt oracle", () => {
  test("encode, decode, fields, unix_ms over the corpus", () => {
    const rng = new Rng(6);
    for (const s of corpus(7, N)) {
      const ns = rng.ns();
      const id = naiveEncode(ns, s);
      expect(encode(ns, s)).toBe(id);
      expect(decode(id)).toEqual(naiveDecode(id));
      expect(fields(s)).toEqual(naiveFields(s));
      expect(unixMs(s)).toBe(naiveUnixMs(s));
      const f = naiveFields(s);
      expect(naiveCompose(f.ts, f.node, f.seq)).toBe(s);
    }
  });
  test("hash32 over the full u64", () => {
    const rng = new Rng(8);
    const ks = [0n, 1n, (1n << 64n) - 1n, 1n << 63n, (1n << 63n) - 1n, 1n << 32n, (1n << 32n) - 1n, 0xffffffff00000000n, 0x00000000ffffffffn, 0xff51afd7ed558ccdn];
    for (let i = 0; i < N; i++) ks.push(rng.u64());
    for (const k of ks) expect(hash32(k)).toBe(naiveHash32(k));
  });
  test("node_from over random hosts and pids", () => {
    const rng = new Rng(9);
    for (let i = 0; i < 3000; i++) {
      const host = rng.bytes(rng.below(40));
      const pid = rng.below(2 ** 31);
      expect(nodeFrom(host, pid)).toBe(naiveNodeFrom(host, pid));
    }
  });
  test("classification of near-valid ids: every position, every alphabet neighbour", () => {
    const rng = new Rng(10);
    const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    for (let i = 0; i < 300; i++) {
      const base = encode(rng.ns(), rng.snow());
      for (let pos = 0; pos < 14; pos++) {
        for (const c of [alphabet[rng.below(62)]!, "!", "z", "0", "A", "a", "~", " ", "é"]) {
          const id = base.slice(0, pos) + c + base.slice(pos + 1);
          expect(check(id)).toBe(naiveCheck(id));
        }
      }
    }
  });
  test("the max-payload neighbourhood", () => {
    for (let d = -200n; d <= 200n; d++) {
      const v = MAX_SNOW + d;
      if (v < 0n) continue;
      // write v in eleven base62 digits directly, past the domain if need be
      let x = v;
      let payload = "";
      const alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
      for (let i = 0; i < 11; i++) {
        payload = alphabet[Number(x % 62n)] + payload;
        x /= 62n;
      }
      expect(x).toBe(0n);
      const id = "RNG" + payload;
      expect(check(id)).toBe(naiveCheck(id));
      expect(check(id)).toBe(v > MAX_SNOW ? 4 : 0);
    }
  });
});
