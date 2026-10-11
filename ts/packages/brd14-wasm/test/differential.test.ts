// differential.test.ts — the wasm package against the pure package, call for
// call, over a pinned PRNG: valid ids, hostile strings and bytes, out-of-range
// bigints, multi-fault precedence, the full u64 domain of hash32. Every result
// and every error class must be identical; `outcome` renders both to one string.

import { describe, expect, test } from "vitest";
import * as W from "brd14-wasm";
import * as P from "brd14";
import { RANGE_EDGES, Rng, encoder, nearlyValidId, outcome, randomString } from "./helpers.ts";

const N = 20000;

describe("valid inputs", () => {
  test("encode, decode (string and bytes), check, isValid, hash32 agree on random valid ids", () => {
    const rng = new Rng(101);
    for (let i = 0; i < N; i++) {
      const ns = rng.ns();
      const snow = rng.snow();
      const id = W.encode(ns, snow);
      expect(id).toBe(P.encode(ns, snow));
      expect(outcome(() => W.decode(id))).toBe(outcome(() => P.decode(id)));
      const bytes = encoder.encode(id);
      expect(W.decode(bytes).snow).toBe(P.decode(bytes).snow);
      expect(W.check(id)).toBe(0);
      expect(W.isValid(bytes)).toBe(true);
      expect(W.hash32(snow)).toBe(P.hash32(snow));
    }
  });
  test("the range guard's edges, both sides", () => {
    const edges = [0n, 1n, 61n, 62n, 3843n, 3844n, 1n << 22n, (1n << 41n) - 1n, ((1n << 41n) - 1n) << 22n, 1n << 32n, (1n << 32n) - 1n, 1n << 52n, 1n << 53n];
    for (let k = 1n; k <= 10n; k++) edges.push(62n ** k - 1n, 62n ** k, 62n ** k + 1n);
    for (let d = -64n; d <= 64n; d++) edges.push(P.MAX_SNOW + d);
    for (const s of edges) {
      expect(outcome(() => W.encode("RNG", s))).toBe(outcome(() => P.encode("RNG", s)));
      expect(W.hash32(s)).toBe(P.hash32(s));
    }
    // ids just above the maximum payload, spelled out digit by digit
    for (let d = 0n; d <= 64n; d++) {
      let v = P.MAX_SNOW + d;
      let payload = "";
      for (let i = 0; i < 11; i++) {
        payload = P.ALPHABET[Number(v % 62n)] + payload;
        v /= 62n;
      }
      if (v !== 0n) continue;
      const id = "RNG" + payload;
      expect(outcome(() => W.decode(id))).toBe(outcome(() => P.decode(id)));
    }
  });
});

describe("hostile inputs", () => {
  test("random strings of length 0..20 from four character classes", () => {
    const rng = new Rng(102);
    for (let i = 0; i < N; i++) {
      const s = randomString(rng);
      expect(outcome(() => W.decode(s))).toBe(outcome(() => P.decode(s)));
      expect(W.check(s)).toBe(P.check(s));
      expect(W.isValid(s)).toBe(P.isValid(s));
    }
  });
  test("nearly valid 14-character strings", () => {
    const rng = new Rng(103);
    for (let i = 0; i < N; i++) {
      const s = nearlyValidId(rng, P.encode);
      expect(outcome(() => W.decode(s))).toBe(outcome(() => P.decode(s)));
      expect(W.check(encoder.encode(s))).toBe(P.check(encoder.encode(s)));
    }
  });
  test("random bytes of length 0..20, and every single-byte mutation of two ids at every position", () => {
    const rng = new Rng(104);
    for (let i = 0; i < N; i++) {
      const b = rng.bytes(rng.below(21));
      expect(outcome(() => W.decode(b))).toBe(outcome(() => P.decode(b)));
      expect(W.check(b)).toBe(P.check(b));
    }
    for (const seed of ["USR0KHTOWnGLuC", "ZZZAzL8n0Y58m7"]) {
      const base = encoder.encode(seed);
      for (let pos = 0; pos < 14; pos++) {
        for (let byte = 0; byte < 256; byte++) {
          const b = Uint8Array.from(base);
          b[pos] = byte;
          expect(W.check(b)).toBe(P.check(b));
          if (byte < 128) expect(W.check(String.fromCharCode(...b))).toBe(P.check(String.fromCharCode(...b)));
        }
      }
    }
  });
  test("byte inputs around the IO size: 65535, 65536 (through the module) and 65537 (without it)", () => {
    for (const len of [65535, 65536, 65537, 100000]) {
      const b = new Uint8Array(len).fill(0x41);
      expect(W.check(b)).toBe(P.check(b));
      expect(W.check(b)).toBe(P.ErrorCode.LENGTH);
      expect(outcome(() => W.decode(b))).toBe("ERR 1");
    }
    expect(W.memory.buffer.byteLength).toBe(3 * 65536);
  });
  test("every length 0..40 of a repeated valid id, as string and bytes", () => {
    const rep = "USR0KHTOWnGLuC".repeat(3);
    for (let n = 0; n <= 40; n++) {
      const s = rep.substring(0, n);
      expect(outcome(() => W.decode(s))).toBe(outcome(() => P.decode(s)));
      expect(outcome(() => W.decode(encoder.encode(s)))).toBe(outcome(() => P.decode(encoder.encode(s))));
    }
  });
});

describe("hostile namespaces and out-of-range values", () => {
  test("random namespaces of length 0..5 from every character class, random u64 values", () => {
    const rng = new Rng(105);
    for (let i = 0; i < N; i++) {
      const ns = randomString(rng, 6);
      const snow = rng.below(2) ? rng.u64() : rng.snow();
      expect(outcome(() => W.encode(ns, snow))).toBe(outcome(() => P.encode(ns, snow)));
    }
  });
  test("namespaces whose UTF-8 is three bytes but not A-Z, and multi-unit characters", () => {
    for (const ns of ["UÉ", "ÉU", "ßS", "U€", "€", "U😀", "😀", "US\ud800", "\udc00SR", "USR\u0000", "\u0000SR", "US", "USRA", "", "usr", "Usr", "USr", "US1", "U-R"]) {
      for (const snow of [0n, 1n, P.MAX_SNOW, 1n << 63n, -1n]) {
        expect(outcome(() => W.encode(ns, snow))).toBe(outcome(() => P.encode(ns, snow)));
      }
    }
  });
  test("bigints on both sides of 2^63 and 2^64, negative and huge: RANGE, and NAMESPACE first", () => {
    for (const snow of RANGE_EDGES) {
      expect(outcome(() => W.encode("USR", snow))).toBe(outcome(() => P.encode("USR", snow)));
      expect(outcome(() => W.encode("usr", snow))).toBe(outcome(() => P.encode("usr", snow)));
      expect(outcome(() => W.encode("USRX", snow))).toBe(outcome(() => P.encode("USRX", snow)));
      expect(outcome(() => W.encode("usr", snow))).toBe("ERR 2");
    }
    expect(outcome(() => W.encode("USR", (1n << 64n) + 5n))).toBe("ERR 4"); // would wrap into range without the −1 mapping
    expect(outcome(() => W.encode("USR", -(1n << 64n)))).toBe("ERR 4"); // would wrap to 0
    const rng = new Rng(106);
    for (let i = 0; i < 5000; i++) {
      const snow = (1n << 63n) + rng.u64();
      expect(outcome(() => W.encode("USR", snow))).toBe("ERR 4");
      expect(outcome(() => W.encode("USR", -snow))).toBe("ERR 4");
    }
  });
});

describe("multi-fault precedence", () => {
  test("lowercase namespace with random payload bytes is NAMESPACE, never CHARSET or RANGE", () => {
    const rng = new Rng(107);
    for (let i = 0; i < 5000; i++) {
      const b = new Uint8Array(14);
      b.set(encoder.encode(rng.ns().toLowerCase()), 0);
      b.set(rng.bytes(11), 3);
      expect(W.check(b)).toBe(2);
      expect(W.check(b)).toBe(P.check(b));
    }
  });
  test("off-alphabet above the maximum is CHARSET; wrong length wins over everything", () => {
    expect(W.check("USRzzzzzzzzzz!")).toBe(3);
    expect(W.check("USRzzzzzzzzzz!!")).toBe(1);
    expect(W.check("usrzzzzzzzzzz!!")).toBe(1);
    expect(W.check(new Uint8Array(0))).toBe(1);
  });
});

describe("hash32 over the full u64", () => {
  test("random u64, negative and ≥ 2^64 inputs wrap identically", () => {
    const rng = new Rng(108);
    for (let i = 0; i < N; i++) {
      const k = rng.u64();
      expect(W.hash32(k)).toBe(P.hash32(k));
      expect(W.hash32(-k)).toBe(P.hash32(-k));
      expect(W.hash32(k + (1n << 64n))).toBe(P.hash32(k + (1n << 64n)));
    }
    for (const k of RANGE_EDGES) expect(W.hash32(k)).toBe(P.hash32(k));
    expect(W.hash32((1n << 64n) - 1n)).toBe(2225773772);
    expect(W.hash32(0n)).toBe(0);
  });
});
