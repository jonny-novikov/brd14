// contract.test.ts — the frozen literals of docs/contract.md § Vectors through
// the wasm package, the precedence rules, the error shape, and the pieces shared
// with the pure package (Generator, Minter, the readers). Runs under `vitest run`
// on Node and `bun test` on Bun from the same source.

import { describe, expect, test } from "vitest";
import {
  ErrorClass,
  ErrorCode,
  Generator,
  InvalidIdError,
  MAX_PAYLOAD,
  MAX_SNOW,
  Minter,
  NamespaceRefusedError,
  check,
  decode,
  denyAll,
  encode,
  fields,
  hash32,
  isValid,
  nodeFrom,
  unixMs,
} from "brd14-wasm";
import * as pure from "brd14";
import { caught, encoder } from "./helpers.ts";

const REF = 274557032793636864n;

describe("vectors V-1..V-7", () => {
  test("V-1 encode/decode USR0KHTOWnGLuC", () => {
    expect(encode("USR", REF)).toBe("USR0KHTOWnGLuC");
    const d = decode("USR0KHTOWnGLuC");
    expect(d.ns).toBe("USR");
    expect(d.snow).toBe(REF);
  });
  test("V-2 decode USR0NgWEfAEJfs, as a string and as bytes", () => {
    expect(decode("USR0NgWEfAEJfs").snow).toBe(320636799581945856n);
    expect(decode(encoder.encode("USR0NgWEfAEJfs")).snow).toBe(320636799581945856n);
    expect(decode(encoder.encode("USR0NgWEfAEJfs")).ns).toBe("USR");
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
    expect(check(encoder.encode(id))).toBe(code);
    expect(isValid(id)).toBe(false);
    const e = caught(() => decode(id));
    expect(e).toBeInstanceOf(InvalidIdError);
    expect((e as InvalidIdError).code).toBe(code);
    expect((e as InvalidIdError).className).toBe(ErrorClass[code]);
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

describe("precedence", () => {
  test("encode: NAMESPACE before RANGE", () => {
    expect((caught(() => encode("usr", 1n << 63n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
    expect((caught(() => encode("US", -1n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
    expect((caught(() => encode("USR", 1n << 63n)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
    expect((caught(() => encode("USR", -1n)) as InvalidIdError).code).toBe(ErrorCode.RANGE);
  });
  test("decode: LENGTH, NAMESPACE, CHARSET, RANGE", () => {
    expect(check("usr!!!!!!!!!!")).toBe(ErrorCode.LENGTH);
    expect(check("usrzzzzzzzzzz!")).toBe(ErrorCode.NAMESPACE);
    expect(check("USRzzzzzzzzzz!")).toBe(ErrorCode.CHARSET);
    expect(check("USRzzzzzzzzzzz")).toBe(ErrorCode.RANGE);
  });
  test("strings are classified on their UTF-8 bytes", () => {
    expect(check("USR0KHTOWnGLué")).toBe(ErrorCode.LENGTH); // 14 chars, 15 bytes
    expect(check("USR0KHTOWnGLé")).toBe(ErrorCode.CHARSET); // 13 chars, 14 bytes
    expect(check("USé0KHTOWnGLu")).toBe(ErrorCode.NAMESPACE);
    expect(check("USR0KHTOWnGL\ud800")).toBe(ErrorCode.LENGTH); // a lone surrogate is 3 bytes
    expect((caught(() => encode("USÉ", 1n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE);
    expect((caught(() => encode("UÉ", 1n)) as InvalidIdError).code).toBe(ErrorCode.NAMESPACE); // 2 chars, 3 bytes
  });
});

describe("error shape", () => {
  test("InvalidIdError is the pure package's class", () => {
    const e = caught(() => decode("nope")) as InvalidIdError;
    expect(e).toBeInstanceOf(pure.InvalidIdError);
    expect(e.name).toBe("InvalidIdError");
    expect(e.code).toBe(1);
    expect(e.className).toBe("LENGTH");
    expect(e.message).toBe("brd14: invalid id (LENGTH)");
    expect(InvalidIdError).toBe(pure.InvalidIdError);
    expect(ErrorCode).toBe(pure.ErrorCode);
  });
  test("a wrong type is a programming fault, not a contract error", () => {
    expect(() => encode("USR", 5 as unknown as bigint)).toThrow(TypeError);
    expect(() => hash32(5 as unknown as bigint)).toThrow(TypeError);
    expect(() => check(undefined as unknown as string)).toThrow();
  });
});

describe("shared with the pure package", () => {
  test("a Generator feeds encode; a Minter over it needs no change", () => {
    let now = 1_750_000_000_000;
    const g = new Generator(7, () => now);
    const ids: string[] = [];
    for (let i = 0; i < 5000; i++) {
      const snow = g.next();
      const id = encode("USR", snow);
      expect(decode(id).snow).toBe(snow);
      expect(pure.decode(id).snow).toBe(snow);
      expect(fields(snow).node).toBe(7);
      ids.push(id);
      if (i % 1000 === 0) now -= 10; // a backward step changes nothing below
    }
    expect([...ids].sort()).toEqual(ids);
    const m = new Minter(g);
    const minted = m.mint("ORD");
    expect(decode(minted).ns).toBe("ORD");
    expect(decode(minted).snow > decode(ids[ids.length - 1]!).snow).toBe(true); // the logical clock kept going
    expect(unixMs(decode(minted).snow)).toBeGreaterThanOrEqual(1_750_000_000_000);
    const refused = caught(() => new Minter(g, denyAll).mint("ORD"));
    expect(refused).toBeInstanceOf(NamespaceRefusedError);
    expect(refused).not.toBeInstanceOf(InvalidIdError);
  });
  test("E-1 / E-2 / N-1 through the re-exported readers", () => {
    expect(unixMs(REF)).toBe(1769526697641);
    expect(unixMs(320636799581945856n)).toBe(1780512970164);
    expect(nodeFrom("hosta", 100)).toBe(585);
    expect(nodeFrom("", 101)).toBe(559);
  });
});
