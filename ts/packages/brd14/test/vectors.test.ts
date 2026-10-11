// vectors.test.ts — the frozen corpus in <repo>/vectors/. Skipped when the
// directory is absent (a published tarball); a failure when it is absent but
// BRD14_REQUIRE_VECTORS=1 (the root Makefile, CI).

import { describe, expect, test } from "vitest";
import {
  ErrorClass,
  ErrorCode,
  InvalidIdError,
  check,
  decode,
  decodePartsInto,
  encode,
  encodeInto,
  encodeParts,
  fields,
  hash32,
  hash32Parts,
  isValid,
  nodeFrom,
  snowFromParts,
  unixMs,
} from "brd14";
import { VECTORS_PRESENT, VECTORS_REQUIRED, caught, encoder, readTsv, unhex, utf8 } from "./helpers.ts";

const classOf = (name: string): number => ErrorClass.indexOf(name as (typeof ErrorClass)[number]);

test("vectors/ is present when BRD14_REQUIRE_VECTORS=1", () => {
  if (VECTORS_REQUIRED) expect(VECTORS_PRESENT).toBe(true);
});

(VECTORS_PRESENT ? describe : describe.skip)("vectors/", () => {
  describe("valid.tsv", () => {
    const rows = readTsv("valid.tsv");
    test("has the bench corpus and the boundaries", () => {
      expect(rows.length).toBeGreaterThanOrEqual(4096);
    });
    test("every row: encode, decode, hash32, unix_ms, fields, the parts and byte APIs", () => {
      const out = { ns: "", ts: 0, node: 0, seq: 0 };
      const buf = new Uint8Array(14);
      for (const [ns, snowS, id, hashS, msS, tsS, nodeS, seqS] of rows as [string, ...string[]][]) {
        const snow = BigInt(snowS!);
        const ts = Number(tsS);
        const node = Number(nodeS);
        const seq = Number(seqS);
        expect(encode(ns, snow)).toBe(id);
        expect(encodeParts(ns, ts, node, seq)).toBe(id);
        encodeInto(buf, 0, ns, snow);
        expect(new TextDecoder().decode(buf)).toBe(id);
        const d = decode(id!);
        expect(d.ns).toBe(ns);
        expect(d.snow).toBe(snow);
        expect(decode(buf).snow).toBe(snow);
        decodePartsInto(id!, out);
        expect([out.ns, out.ts, out.node, out.seq]).toEqual([ns, ts, node, seq]);
        expect(check(id!)).toBe(0);
        expect(isValid(buf)).toBe(true);
        expect(hash32(snow)).toBe(Number(hashS));
        expect(hash32Parts(Number(snow >> 32n), Number(snow & 0xffffffffn))).toBe(Number(hashS));
        expect(unixMs(snow)).toBe(Number(msS));
        expect(fields(snow)).toEqual({ ts, node, seq });
        expect(snowFromParts(ts, node, seq)).toBe(snow);
      }
    });
  });

  describe("invalid.tsv", () => {
    const rows = readTsv("invalid.tsv");
    test("has rows of every class", () => {
      expect(new Set(rows.map((r) => r[1]))).toEqual(new Set(["LENGTH", "NAMESPACE", "CHARSET", "RANGE"]));
    });
    test("every row: decode refuses the bytes, and the string when it is UTF-8, with the class", () => {
      for (const [hex, cls] of rows as [string, string][]) {
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
          expect(caught(() => decodePartsInto(s, { ns: "", ts: 0, node: 0, seq: 0 }))).toBeInstanceOf(InvalidIdError);
        }
      }
    });
  });

  describe("encode_invalid.tsv", () => {
    const rows = readTsv("encode_invalid.tsv");
    test("every row: encode refuses with the class", () => {
      for (const [nsHex, snowS, cls] of rows as [string, string, string][]) {
        const nsBytes = unhex(nsHex);
        const ns = String.fromCharCode(...nsBytes); // Latin-1: a byte ≥ 128 is a non-A-Z char either way
        const snow = BigInt(snowS);
        const code = classOf(cls);
        expect((caught(() => encode(ns, snow)) as InvalidIdError).code).toBe(code);
        expect((caught(() => encodeInto(new Uint8Array(14), 0, ns, snow)) as InvalidIdError).code).toBe(code);
        if (code === ErrorCode.NAMESPACE) {
          expect((caught(() => encodeParts(ns, 0, 0, 0)) as InvalidIdError).code).toBe(code);
        }
      }
    });
  });

  describe("node.tsv", () => {
    const rows = readTsv("node.tsv");
    test("every row: node_from over the host bytes (and the string when UTF-8)", () => {
      for (const [hostHex, pidS, nodeS] of rows as [string, string, string][]) {
        const host = unhex(hostHex);
        const pid = Number(pidS);
        expect(nodeFrom(host, pid)).toBe(Number(nodeS));
        const s = utf8(host);
        if (s !== undefined) {
          expect(nodeFrom(s, pid)).toBe(Number(nodeS));
          expect(encoder.encode(s)).toEqual(host);
        }
      }
    });
  });
});
