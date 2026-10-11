// vectors.test.ts — the frozen corpus in <repo>/vectors/ through the wasm
// package, single calls and batches. Skipped when the directory is absent (a
// published tarball); a failure when it is absent but BRD14_REQUIRE_VECTORS=1.

import { describe, expect, test } from "vitest";
import {
  BatchInvalidIdError,
  ErrorClass,
  ErrorCode,
  InvalidIdError,
  check,
  checkMany,
  decode,
  decodeMany,
  decodeManyInto,
  encode,
  encodeMany,
  encodeManyInto,
  hash32,
  isValid,
  nodeFrom,
} from "brd14-wasm";
import { VECTORS_PRESENT, VECTORS_REQUIRED, caught, encoder, readTsv, unhex, utf8 } from "./helpers.ts";

const classOf = (name: string): number => ErrorClass.indexOf(name as (typeof ErrorClass)[number]);

test("vectors/ is present when BRD14_REQUIRE_VECTORS=1", () => {
  if (VECTORS_REQUIRED) expect(VECTORS_PRESENT).toBe(true);
});

(VECTORS_PRESENT ? describe : describe.skip)("vectors/", () => {
  describe("valid.tsv", () => {
    const rows = readTsv("valid.tsv") as [string, string, string, string, ...string[]][];
    test("has the bench corpus and the boundaries", () => {
      expect(rows.length).toBeGreaterThanOrEqual(4096);
    });
    test("every row: encode, decode (string and bytes), check, isValid, hash32", () => {
      for (const [ns, snowS, id, hashS] of rows) {
        const snow = BigInt(snowS);
        const bytes = encoder.encode(id);
        expect(encode(ns, snow)).toBe(id);
        const d = decode(id);
        expect(d.ns).toBe(ns);
        expect(d.snow).toBe(snow);
        expect(decode(bytes).snow).toBe(snow);
        expect(check(id)).toBe(0);
        expect(isValid(bytes)).toBe(true);
        expect(hash32(snow)).toBe(Number(hashS));
      }
    });
    test("the whole corpus as batches: encodeMany, encodeManyInto, decodeMany, checkMany", () => {
      const snows = BigInt64Array.from(rows.map((r) => BigInt(r[1])));
      const ids = rows.map((r) => r[2]);
      const payloads = encodeMany("ZZZ", snows);
      expect(payloads.length).toBe(rows.length);
      for (let i = 0; i < rows.length; i++) expect(payloads[i]).toBe("ZZZ" + ids[i]!.slice(3));
      const buf = new Uint8Array(14 * rows.length);
      expect(encodeManyInto("ZZZ", [...snows], buf)).toBe(buf.length);
      expect(new TextDecoder().decode(buf.subarray(0, 14))).toBe("ZZZ" + ids[0]!.slice(3));
      const back = decodeMany(ids);
      expect(back.length).toBe(rows.length);
      for (let i = 0; i < rows.length; i++) expect(back[i]).toBe(snows[i]);
      const concat = new Uint8Array(14 * rows.length);
      ids.forEach((id, i) => concat.set(encoder.encode(id), 14 * i));
      const back2 = decodeMany(concat);
      for (let i = 0; i < rows.length; i++) expect(back2[i]).toBe(snows[i]);
      expect(checkMany(ids).every((c) => c === 0)).toBe(true);
      const out = new BigInt64Array(rows.length);
      expect(decodeManyInto(concat, out)).toBe(-1);
      for (let i = 0; i < rows.length; i++) expect(out[i]).toBe(snows[i]);
    });
  });

  describe("invalid.tsv", () => {
    const rows = readTsv("invalid.tsv") as [string, string][];
    test("has rows of every class", () => {
      expect(new Set(rows.map((r) => r[1]))).toEqual(new Set(["LENGTH", "NAMESPACE", "CHARSET", "RANGE"]));
    });
    test("every row: decode refuses the bytes, and the string when it is UTF-8, with the class", () => {
      for (const [hex, cls] of rows) {
        const bytes = unhex(hex);
        const code = classOf(cls);
        expect(check(bytes)).toBe(code);
        expect(isValid(bytes)).toBe(false);
        const e = caught(() => decode(bytes));
        expect(e).toBeInstanceOf(InvalidIdError);
        expect((e as InvalidIdError).code).toBe(code);
        const s = utf8(bytes);
        if (s !== undefined) {
          expect(check(s)).toBe(code);
          expect((caught(() => decode(s)) as InvalidIdError).code).toBe(code);
        }
      }
    });
    test("the UTF-8 rows as one batch: checkMany and decodeManyInto report every class", () => {
      const strings = rows.map(([hex]) => utf8(unhex(hex))).filter((s): s is string => s !== undefined);
      const codes = rows.map(([hex, cls]) => (utf8(unhex(hex)) === undefined ? -1 : classOf(cls))).filter((c) => c >= 0);
      expect(strings.length).toBeGreaterThanOrEqual(100);
      expect([...checkMany(strings)]).toEqual(codes);
      const out = new BigInt64Array(strings.length);
      expect(decodeManyInto(strings, out)).toBe(0);
      for (let i = 0; i < strings.length; i++) expect(out[i]).toBe(BigInt(-codes[i]!));
      const e = caught(() => decodeMany(strings)) as BatchInvalidIdError;
      expect(e).toBeInstanceOf(BatchInvalidIdError);
      expect(e.index).toBe(0);
      expect(e.code).toBe(codes[0]);
    });
  });

  describe("encode_invalid.tsv", () => {
    const rows = readTsv("encode_invalid.tsv") as [string, string, string][];
    test("every row: encode and encodeMany refuse with the class", () => {
      for (const [nsHex, snowS, cls] of rows) {
        const nsBytes = unhex(nsHex);
        const ns = String.fromCharCode(...nsBytes); // Latin-1: a byte ≥ 128 is a non-A-Z char either way
        const snow = BigInt(snowS);
        const code = classOf(cls);
        expect((caught(() => encode(ns, snow)) as InvalidIdError).code).toBe(code);
        const e = caught(() => encodeMany(ns, [snow])) as InvalidIdError;
        expect(e.code).toBe(code);
        if (code === ErrorCode.RANGE) expect((e as BatchInvalidIdError).index).toBe(0);
        expect((caught(() => encodeManyInto(ns, [snow], new Uint8Array(14))) as InvalidIdError).code).toBe(code);
      }
    });
  });

  describe("node.tsv", () => {
    const rows = readTsv("node.tsv") as [string, string, string][];
    test("every row: the re-exported nodeFrom over the host bytes", () => {
      for (const [hostHex, pidS, nodeS] of rows) {
        expect(nodeFrom(unhex(hostHex), Number(pidS))).toBe(Number(nodeS));
      }
    });
  });
});
