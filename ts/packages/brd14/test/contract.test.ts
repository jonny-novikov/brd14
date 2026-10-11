// contract.test.ts — the frozen literals of docs/contract.md § Vectors, the
// precedence rules, and the error shape. Runs under `vitest run` on Node and
// `bun test` on Bun from the same source.

import { describe, expect, test } from "vitest";
import {
  ErrorClass,
  ErrorCode,
  InvalidIdError,
  MAX_PAYLOAD,
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
  isNamespace,
  isValid,
  minFor,
  nodeFrom,
  snowFromParts,
  unixMs,
} from "brd14";
import { caught, encoder } from "./helpers.ts";

const REF = 274557032793636864n;

describe("vectors V-1..V-7", () => {
  test("V-1 encode/decode USR0KHTOWnGLuC", () => {
    expect(encode("USR", REF)).toBe("USR0KHTOWnGLuC");
    expect(decode("USR0KHTOWnGLuC")).toEqual({ ns: "USR", snow: REF });
  });
  test("V-2 decode USR0NgWEfAEJfs", () => {
    expect(decode("USR0NgWEfAEJfs")).toEqual({ ns: "USR", snow: 320636799581945856n });
  });
  test("V-3 zero pads to eleven digits", () => {
    expect(encode("ABC", 0n)).toBe("ABC00000000000");
  });
  test("V-4 the maximum payload", () => {
    expect(encode("ABC", MAX_SNOW).slice(3)).toBe(MAX_PAYLOAD);
    expect(decode("ABC" + MAX_PAYLOAD).snow).toBe(MAX_SNOW);
  });
  test.each([
    ["USRzzzzzzzzzzz", ErrorCode.RANGE],
    ["usr0KHTOWnGLuC", ErrorCode.NAMESPACE],
    ["USR0KHTOWnGLu", ErrorCode.LENGTH],
    ["USR0KHTOWnGLuCC", ErrorCode.LENGTH],
    ["USRAzL8n0Y58m8", ErrorCode.RANGE],
    ["USR0KHTOWnGLu!", ErrorCode.CHARSET],
  ])("V-5 refuses %s with %i", (id, code) => {
    expect(check(id)).toBe(code);
    expect(isValid(id)).toBe(false);
    const e = caught(() => decode(id));
    expect(e).toBeInstanceOf(InvalidIdError);
    expect((e as InvalidIdError).code).toBe(code);
  });
  test("V-6 hash32", () => {
    expect(hash32(REF)).toBe(234878118);
  });
  test("V-7 byte order is numeric order, every alphabet index in the low digit", () => {
    const snows = [...Array.from({ length: 62 }, (_, i) => BigInt(i)), 62n, 3843n, 3844n, 1n << 22n, MAX_SNOW];
    const ids = snows.map((s) => encode("SES", s));
    expect([...ids].sort()).toEqual(ids);
    expect(new Set(ids.slice(0, 62).map((id) => id[13])).size).toBe(62);
  });
});

describe("epoch and node vectors", () => {
  test("E-1 / E-2 unix_ms", () => {
    expect(unixMs(REF)).toBe(1769526697641);
    expect(unixMs(320636799581945856n)).toBe(1780512970164);
    expect(new Date(unixMs(REF)).toISOString()).toBe("2026-01-27T15:11:37.641Z");
  });
  test.each([
    ["hosta", 100, 585],
    ["hosta", 101, 182],
    ["hosta", 4242, 290],
    ["", 100, 156],
    ["", 101, 559],
  ])("N-1 node_from(%j, %i) = %i", (host, pid, node) => {
    expect(nodeFrom(host, pid)).toBe(node);
    expect(nodeFrom(encoder.encode(host), pid)).toBe(node);
  });
  test("the arithmetic range guard is the same boundary (QA, RB)", () => {
    expect(MAX_SNOW / 56800235584n).toBe(162382637n);
    expect(MAX_SNOW % 56800235584n).toBe(503620799n);
  });
});

describe("precedence", () => {
  test("encode: NAMESPACE before RANGE, any length other than 3 is NAMESPACE", () => {
    expect((caught(() => encode("usr", 1n << 63n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
    expect((caught(() => encode("US", 0n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
    expect((caught(() => encode("USRX", 0n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
    expect((caught(() => encode("", 0n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
    expect((caught(() => encode("USR", 1n << 63n)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
    expect((caught(() => encode("USR", -1n)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
    expect((caught(() => encode("USR", (1n << 64n) - 1n)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
  });
  test("decode: LENGTH, NAMESPACE, CHARSET, RANGE", () => {
    expect(check("usr0KHTOWnGL!!")).toBe(ErrorCode.NAMESPACE);
    expect(check("USRzzzzzzzzzz!")).toBe(ErrorCode.CHARSET);
    expect(check("usrzzzzzzzzzz!!")).toBe(ErrorCode.LENGTH);
    expect(check("")).toBe(ErrorCode.LENGTH);
    expect(check(new Uint8Array(0))).toBe(ErrorCode.LENGTH);
  });
  test("strings are classified on their UTF-8 bytes", () => {
    // 14 chars, 15 bytes → LENGTH, exactly as the byte API sees it.
    expect(check("USR0KHTOWnGLué")).toBe(ErrorCode.LENGTH);
    // 13 chars, 14 bytes: the 2-byte char lands in the payload → CHARSET.
    expect(check("USR0KHTOWnGLé")).toBe(ErrorCode.CHARSET);
    // 13 chars, 14 bytes: the 2-byte char lands in the namespace → NAMESPACE.
    expect(check("USé0KHTOWnGLu")).toBe(ErrorCode.NAMESPACE);
    // 12 chars, 14 bytes (one 3-byte char) → CHARSET.
    expect(check("USR0KHTOWnG€")).toBe(ErrorCode.CHARSET);
    // a lone surrogate encodes as U+FFFD, three bytes.
    expect(check("USR0KHTOWnG\ud800")).toBe(ErrorCode.CHARSET);
    expect(check("USR0KHTOWnGL\ud800")).toBe(ErrorCode.LENGTH);
    for (const s of ["USR0KHTOWnGLué", "USR0KHTOWnGLé", "USR0KHTOWnG€"]) {
      expect(check(s)).toBe(check(encoder.encode(s)));
    }
  });
});

describe("error shape", () => {
  test("InvalidIdError carries the class code and name", () => {
    const e = caught(() => decode("USR0KHTOWnGLu")) as InvalidIdError;
    expect(e).toBeInstanceOf(Error);
    expect(e).toBeInstanceOf(InvalidIdError);
    expect(e.name).toBe("InvalidIdError");
    expect(e.code).toBe(1);
    expect(e.className).toBe("LENGTH");
    expect(e.message).toContain("LENGTH");
  });
  test("ErrorCode is a frozen const object, ErrorClass its names", () => {
    expect(Object.isFrozen(ErrorCode)).toBe(true);
    expect(ErrorCode).toEqual({ OK: 0, LENGTH: 1, NAMESPACE: 2, CHARSET: 3, RANGE: 4 });
    expect([...ErrorClass]).toEqual(["OK", "LENGTH", "NAMESPACE", "CHARSET", "RANGE"]);
  });
});

describe("the parts and bytes APIs", () => {
  const f = fields(REF);
  test("fields of the reference snowflake", () => {
    // REF = 65459497641 << 22 exactly: node and seq are zero, which is why minFor(E-1) == REF below.
    expect(f).toEqual({ ts: 65459497641, node: 0, seq: 0 });
    expect(unixMs(REF)).toBe(f.ts + 1704067200000);
    expect(fields(320636799581945856n)).toEqual({ ts: 76445770164, node: 0, seq: 0 });
    expect(fields(REF + (613n << 12n) + 4095n)).toEqual({ ts: 65459497641, node: 613, seq: 4095 });
  });
  test("encodeParts agrees with encode", () => {
    expect(encodeParts("USR", f.ts, f.node, f.seq)).toBe("USR0KHTOWnGLuC");
    expect(snowFromParts(f.ts, f.node, f.seq)).toBe(REF);
  });
  test("encodeParts refuses a field outside its width with RANGE", () => {
    for (const [ts, node, seq] of [
      [-1, 0, 0],
      [2 ** 41, 0, 0],
      [1.5, 0, 0],
      [0, 1024, 0],
      [0, -1, 0],
      [0, 0, 4096],
      [0, 0, 0.5],
      [Number.NaN, 0, 0],
    ] as const) {
      expect((caught(() => encodeParts("USR", ts, node, seq)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
    }
    expect(encodeParts("USR", 2 ** 41 - 1, 1023, 4095)).toBe("USR" + MAX_PAYLOAD);
  });
  test("decodePartsInto fills the given object and returns it", () => {
    const out = { ns: "", ts: -1, node: -1, seq: -1, extra: true };
    expect(decodePartsInto("USR0KHTOWnGLuC", out)).toBe(out);
    expect(out).toEqual({ ns: "USR", ts: f.ts, node: f.node, seq: f.seq, extra: true });
    expect(decodePartsInto(encoder.encode("USR0KHTOWnGLuC"), { ns: "", ts: 0, node: 0, seq: 0 })).toEqual({
      ns: "USR",
      ...f,
    });
  });
  test("encodeInto writes 14 bytes at the offset", () => {
    const buf = new Uint8Array(20).fill(0x2e);
    encodeInto(buf, 3, "USR", REF);
    expect(new TextDecoder().decode(buf)).toBe("...USR0KHTOWnGLuC...");
    encodePartsInto(buf, 0, "ABC", 0, 0, 0);
    expect(new TextDecoder().decode(buf.subarray(0, 14))).toBe("ABC00000000000");
    expect(caught(() => encodeInto(new Uint8Array(13), 0, "USR", REF))).toBeInstanceOf(RangeError);
    expect(caught(() => encodeInto(new Uint8Array(20), 7, "USR", REF))).toBeInstanceOf(RangeError);
    expect((caught(() => encodeInto(buf, 0, "usr", REF)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
  });
  test("decode accepts bytes", () => {
    expect(decode(encoder.encode("USR0NgWEfAEJfs"))).toEqual({ ns: "USR", snow: 320636799581945856n });
  });
  test("hash32Parts is hash32 on the halves", () => {
    expect(hash32Parts(Number(REF >> 32n), Number(REF & 0xffffffffn))).toBe(234878118);
    expect(hash32(0n)).toBe(hash32Parts(0, 0));
    expect(hash32(-1n)).toBe(hash32((1n << 64n) - 1n));
    expect(hash32(1n << 64n)).toBe(hash32(0n));
  });
  test("minFor is the half-open lower bound", () => {
    expect(minFor(1769526697641)).toBe(65459497641n << 22n);
    expect(minFor(1769526697641) <= REF).toBe(true);
    expect(minFor(1769526697642) > REF).toBe(true);
    expect(minFor(1704067200000)).toBe(0n);
    expect((caught(() => minFor(1704067199999)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
  });
  test("domain reads refuse values outside [0, 2^63)", () => {
    for (const bad of [-1n, 1n << 63n]) {
      expect((caught(() => unixMs(bad)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
      expect((caught(() => fields(bad)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
    }
  });
  test("isNamespace", () => {
    expect(isNamespace("USR")).toBe(true);
    expect(isNamespace("usr")).toBe(false);
    expect(isNamespace("US")).toBe(false);
    expect(isNamespace("USRX")).toBe(false);
    expect(isNamespace("USİ")).toBe(false);
  });
  test("nodeFrom rejects a bad pid", () => {
    expect(caught(() => nodeFrom("h", -1))).toBeInstanceOf(RangeError);
    expect(caught(() => nodeFrom("h", 1.5))).toBeInstanceOf(RangeError);
  });
});
