// batch.test.ts — the batch entry points: sizes around the 2,978 clamp and far
// beyond it (chunking), every input shape, errors in the middle of a batch at
// chunk boundaries, the status forms, and agreement with the single-call API of
// the pure package over mixed valid and hostile batches.

import { describe, expect, test } from "vitest";
import {
  BATCH_MAX,
  BatchInvalidIdError,
  ErrorCode,
  IO_PTR,
  InvalidIdError,
  abi,
  checkMany,
  decode,
  decodeMany,
  decodeManyInto,
  encode,
  encodeMany,
  encodeManyInto,
  memory,
} from "brd14-wasm";
import * as P from "brd14";
import { Rng, caught, encoder, nearlyValidId, randomString } from "./helpers.ts";

const SIZES = [0, 1, 2, 7, 2977, 2978, 2979, 5956, 5957, 10000];

function snowsOf(rng: Rng, n: number): bigint[] {
  return Array.from({ length: n }, () => rng.snow());
}

function concat(ids: readonly string[]): Uint8Array {
  const out = new Uint8Array(14 * ids.length);
  ids.forEach((id, i) => out.set(encoder.encode(id), 14 * i));
  return out;
}

describe("sizes 0, 1, 2978, 2979, 10000: every batch equals the single calls", () => {
  test.each(SIZES)("n = %i", (n) => {
    const rng = new Rng(200 + n);
    const snows = snowsOf(rng, n);
    const want = snows.map((s) => P.encode("BAT", s));

    expect(encodeMany("BAT", snows)).toEqual(want);
    expect(encodeMany("BAT", BigInt64Array.from(snows))).toEqual(want);
    expect(encodeMany("BAT", BigUint64Array.from(snows))).toEqual(want);

    const buf = new Uint8Array(14 * n + 7).fill(0xee);
    expect(encodeManyInto("BAT", snows, buf, 7)).toBe(14 * n);
    expect(buf.subarray(0, 7)).toEqual(new Uint8Array(7).fill(0xee));
    expect(buf.subarray(7)).toEqual(concat(want));

    const back = decodeMany(want);
    expect(back).toBeInstanceOf(BigInt64Array);
    expect(back.length).toBe(n);
    for (let i = 0; i < n; i++) expect(back[i]).toBe(snows[i]);
    const back2 = decodeMany(concat(want));
    for (let i = 0; i < n; i++) expect(back2[i]).toBe(snows[i]);

    expect(checkMany(want)).toEqual(new Uint8Array(n));
    expect(checkMany(concat(want))).toEqual(new Uint8Array(n));

    const out = new BigInt64Array(n + 3).fill(-9n);
    expect(decodeManyInto(want, out, 3)).toBe(-1);
    expect(out[0]).toBe(-9n);
    for (let i = 0; i < n; i++) expect(out[3 + i]).toBe(snows[i]);
  });
});

describe("errors in the middle of a batch", () => {
  const n = 7000;
  const rng = new Rng(300);
  const good = snowsOf(rng, n);
  const goodIds = good.map((s) => P.encode("ERR", s));

  test.each([0, 1, 2977, 2978, 2979, 5955, 5956, 5957, 6999])("encodeMany / encodeManyInto refuse RANGE at index %i, having written what precedes it", (at) => {
    for (const bad of [1n << 63n, -1n, (1n << 64n) + 1n]) {
      const snows = [...good];
      snows[at] = bad;
      const e = caught(() => encodeMany("ERR", snows)) as BatchInvalidIdError;
      expect(e).toBeInstanceOf(BatchInvalidIdError);
      expect(e).toBeInstanceOf(InvalidIdError);
      expect(e.name).toBe("InvalidIdError");
      expect(e.code).toBe(ErrorCode.RANGE);
      expect(e.className).toBe("RANGE");
      expect(e.index).toBe(at);
      expect(e.message).toBe(`brd14: invalid id (RANGE): batch item ${at}`);

      const buf = new Uint8Array(14 * n);
      const e2 = caught(() => encodeManyInto("ERR", snows, buf)) as BatchInvalidIdError;
      expect(e2.index).toBe(at);
      expect(buf.subarray(0, 14 * at)).toEqual(concat(goodIds.slice(0, at)));
      expect(buf.subarray(14 * at).every((b) => b === 0)).toBe(true);
    }
    // a BigInt64Array can only be out of range by being negative
    const typed = BigInt64Array.from(good);
    typed[at] = -5n;
    expect((caught(() => encodeMany("ERR", typed)) as BatchInvalidIdError).index).toBe(at);
  });

  test("the namespace is checked first, even for an empty batch, and before a bad snowflake", () => {
    for (const ns of ["usr", "US", "USRA", "", "USÉ"]) {
      for (const snows of [[], [1n], [1n << 63n], good]) {
        const e = caught(() => encodeMany(ns, snows)) as InvalidIdError;
        expect(e).toBeInstanceOf(InvalidIdError);
        expect(e.code).toBe(ErrorCode.NAMESPACE);
        expect(e instanceof BatchInvalidIdError).toBe(false);
        expect((caught(() => encodeManyInto(ns, snows, new Uint8Array(14 * snows.length))) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
      }
    }
  });

  test.each([0, 1, 2977, 2978, 2979, 5956, 6999])("decodeMany refuses at index %i with the class of that id; the status forms report it", (at) => {
    const faults: [string, number][] = [
      ["err" + goodIds[at]!.slice(3), ErrorCode.NAMESPACE],
      ["ERRzzzzzzzzzzz", ErrorCode.RANGE],
      ["ERR0KHTOWnGLu!", ErrorCode.CHARSET],
      ["ERR0KHTOWnGLu", ErrorCode.LENGTH],
      ["", ErrorCode.LENGTH],
      ["ERR0KHTOWnGLuCC", ErrorCode.LENGTH],
      ["ERR0KHTOWnGLué", ErrorCode.LENGTH], // 14 chars, 15 bytes
      ["ERR0KHTOWnGLé", ErrorCode.CHARSET], // 13 chars, 14 bytes
      ["ERé0KHTOWnGLu", ErrorCode.NAMESPACE],
    ];
    for (const [badId, code] of faults) {
      const ids = [...goodIds];
      ids[at] = badId;
      expect(P.check(badId)).toBe(code);
      const e = caught(() => decodeMany(ids)) as BatchInvalidIdError;
      expect(e).toBeInstanceOf(BatchInvalidIdError);
      expect(e.code).toBe(code);
      expect(e.index).toBe(at);

      const out = new BigInt64Array(n);
      expect(decodeManyInto(ids, out)).toBe(at);
      expect(out[at]).toBe(BigInt(-code));
      for (let i = 0; i < n; i++) if (i !== at) expect(out[i]).toBe(good[i]);

      const codes = checkMany(ids);
      expect(codes[at]).toBe(code);
      expect(codes.filter((c) => c !== 0).length).toBe(1);
    }
    // the same through bytes, for the faults that are 14 bytes long
    const bytes = concat(goodIds);
    bytes[14 * at] = 0x65; // 'e': NAMESPACE
    const e = caught(() => decodeMany(bytes)) as BatchInvalidIdError;
    expect(e.code).toBe(ErrorCode.NAMESPACE);
    expect(e.index).toBe(at);
    expect(checkMany(bytes)[at]).toBe(ErrorCode.NAMESPACE);
  });

  test("the first of several bad ids is the one reported", () => {
    const ids = [...goodIds];
    ids[10] = "ERRzzzzzzzzzzz";
    ids[3000] = "nope";
    ids[6000] = "err00000000000";
    expect((caught(() => decodeMany(ids)) as BatchInvalidIdError).index).toBe(10);
    const out = new BigInt64Array(n);
    expect(decodeManyInto(ids, out)).toBe(10);
    expect([out[10], out[3000], out[6000]]).toEqual([-4n, -1n, -2n]);
    const codes = checkMany(ids);
    expect([codes[10], codes[3000], codes[6000]]).toEqual([4, 1, 2]);
    ids[10] = goodIds[10]!;
    expect((caught(() => decodeMany(ids)) as BatchInvalidIdError).index).toBe(3000);
    expect(decodeManyInto(ids, out)).toBe(3000);
  });
});

describe("mixed batches agree with the pure package's single calls", () => {
  test("10,000 random strings, valid and hostile, through checkMany and decodeManyInto", () => {
    const rng = new Rng(400);
    const ids: string[] = [];
    for (let i = 0; i < 10000; i++) ids.push(rng.below(3) === 0 ? randomString(rng) : nearlyValidId(rng, P.encode));
    const codes = checkMany(ids);
    const out = new BigInt64Array(ids.length);
    const first = decodeManyInto(ids, out);
    let wantFirst = -1;
    for (let i = 0; i < ids.length; i++) {
      const c = P.check(ids[i]!);
      expect(codes[i]).toBe(c);
      expect(out[i]).toBe(c === 0 ? P.decode(ids[i]!).snow : BigInt(-c));
      if (c !== 0 && wantFirst < 0) wantFirst = i;
    }
    expect(first).toBe(wantFirst);
  });
  test("10,000 random namespaces × snowflakes through encodeMany, one namespace per batch", () => {
    const rng = new Rng(401);
    for (let round = 0; round < 50; round++) {
      const ns = rng.below(4) === 0 ? randomString(rng, 5) : rng.ns();
      const snows = Array.from({ length: 200 }, () => (rng.below(8) === 0 ? rng.u64() : rng.snow()));
      let want: string | string[];
      try {
        want = snows.map((s) => P.encode(ns, s));
      } catch (e) {
        want = `ERR ${(e as InvalidIdError).code}`;
      }
      let got: string | string[];
      try {
        got = encodeMany(ns, snows);
      } catch (e) {
        got = `ERR ${(e as InvalidIdError).code}`;
      }
      expect(got).toEqual(want);
    }
  });
});

describe("programming faults and the module after batches", () => {
  test("a byte batch must be whole ids; the out buffers must be large enough", () => {
    expect(() => decodeMany(new Uint8Array(27))).toThrow(RangeError);
    expect(() => checkMany(new Uint8Array(1))).toThrow(RangeError);
    expect(() => decodeManyInto(new Uint8Array(15), new BigInt64Array(2))).toThrow(RangeError);
    expect(() => decodeManyInto(["ERR00000000000", "ERR00000000001"], new BigInt64Array(1))).toThrow(RangeError);
    expect(() => decodeManyInto(["ERR00000000000"], new BigInt64Array(1), 1)).toThrow(RangeError);
    expect(() => encodeManyInto("ERR", [1n, 2n], new Uint8Array(27))).toThrow(RangeError);
    expect(() => encodeManyInto("ERR", [1n], new Uint8Array(14), 1)).toThrow(RangeError);
    expect(() => encodeManyInto("ERR", [1n], new Uint8Array(14), -1)).toThrow(RangeError);
    // the buffer check comes before the namespace check: a RangeError, not NAMESPACE
    expect(() => encodeManyInto("err", [1n], new Uint8Array(0))).toThrow(RangeError);
  });
  test("the raw exports clamp n to [0, 2978]; the loader never asks for more", () => {
    expect(BATCH_MAX).toBe(2978);
    expect(((14 * 2978 + 7) & ~7) + 8 * 2978).toBeLessThanOrEqual(65536);
    expect(((14 * 2979 + 7) & ~7) + 8 * 2979).toBeGreaterThan(65536);
    expect(abi.decode_many(2979)).toBe(2978);
    expect(abi.decode_many(1 << 30)).toBe(2978);
    expect(abi.decode_many(-1)).toBe(0);
    new BigInt64Array(memory.buffer, IO_PTR, BATCH_MAX).fill(0n); // 2978 in-range inputs
    expect(abi.encode_many(0x525355, 100000)).toBe(2978); // "USR" packed
    expect(abi.encode_many(0x525355, -7)).toBe(0);
  });
  test("memory never grew and the cached views are still attached", () => {
    expect(memory.buffer.byteLength).toBe(3 * 65536);
    expect(encodeMany("END", [1n])).toEqual(["END00000000001"]);
  });
  test("a buffer refresh (memory.grow(0) on the exported memory) detaches views; the codec re-attaches", () => {
    const stale = new Uint8Array(memory.buffer);
    expect(memory.grow(0)).toBe(3); // succeeds, and per the JS API refreshes memory.buffer
    expect(memory.buffer.byteLength).toBe(3 * 65536);
    // Every entry point must survive it, single and batch, on whichever views were cached.
    expect(encode("USR", 274557032793636864n)).toBe("USR0KHTOWnGLuC");
    memory.grow(0);
    expect(decode("USR0NgWEfAEJfs")).toEqual({ ns: "USR", snow: 320636799581945856n });
    memory.grow(0);
    expect(decodeMany(["USR0KHTOWnGLuC", "USR0NgWEfAEJfs"])).toEqual(new BigInt64Array([274557032793636864n, 320636799581945856n]));
    memory.grow(0);
    expect(Array.from(checkMany(["USR0KHTOWnGLuC", "usr0KHTOWnGLuC"]))).toEqual([0, 2]);
    memory.grow(0);
    expect(encodeMany("END", [1n])).toEqual(["END00000000001"]);
    expect(stale.byteLength === 0 || stale.byteLength === 3 * 65536).toBe(true); // engine-dependent: detached or not
  });
});
