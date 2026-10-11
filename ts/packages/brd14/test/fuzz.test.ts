// fuzz.test.ts — totality: decode over random strings and bytes throws
// InvalidIdError and nothing else; check() never throws and agrees with the
// naive byte classifier; a string is classified exactly as its UTF-8 bytes.

import { describe, expect, test } from "vitest";
import { InvalidIdError, check, decode, decodePartsInto, isValid } from "brd14";
import { Rng, encoder } from "./helpers.ts";
import { naiveCheck } from "./naive.ts";

const ALPHABET_PLUS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!@#$%^&*()-_=+[]{};:'\",.<>/?`~ \t\né€😀";

function randomString(rng: Rng): string {
  const len = rng.below(21);
  const kind = rng.below(4);
  let s = "";
  for (let i = 0; i < len; i++) {
    switch (kind) {
      case 0:
        s += ALPHABET_PLUS[rng.below(ALPHABET_PLUS.length)];
        break;
      case 1:
        s += String.fromCharCode(rng.below(128));
        break;
      case 2:
        s += String.fromCharCode(rng.below(256));
        break;
      default:
        s += String.fromCharCode(rng.below(65536)); // lone surrogates included
    }
  }
  return s;
}

function onlyInvalidIdError(fn: () => unknown): boolean {
  try {
    fn();
    return true;
  } catch (e) {
    return e instanceof InvalidIdError;
  }
}

describe("totality", () => {
  test("random strings: InvalidIdError or success, check() in 0..4, consistent", () => {
    const rng = new Rng(11);
    const out = { ns: "", ts: 0, node: 0, seq: 0 };
    for (let i = 0; i < 30000; i++) {
      const s = randomString(rng);
      const code = check(s);
      expect(code >= 0 && code <= 4).toBe(true);
      expect(onlyInvalidIdError(() => decode(s))).toBe(true);
      expect(onlyInvalidIdError(() => decodePartsInto(s, out))).toBe(true);
      expect(isValid(s)).toBe(code === 0);
      expect(code).toBe(naiveCheck(s));
      expect(code).toBe(check(encoder.encode(s)));
    }
  });
  test("random bytes of length 0..20: the same, plus every single-byte mutation of a valid id", () => {
    const rng = new Rng(12);
    for (let i = 0; i < 30000; i++) {
      const b = rng.bytes(rng.below(21));
      const code = check(b);
      expect(onlyInvalidIdError(() => decode(b))).toBe(true);
      expect(code).toBe(naiveCheck(b));
    }
    const seed = encoder.encode("USR0KHTOWnGLuC");
    for (let pos = 0; pos < 14; pos++) {
      for (let byte = 0; byte < 256; byte++) {
        const b = Uint8Array.from(seed);
        b[pos] = byte;
        expect(check(b)).toBe(naiveCheck(b));
        expect(onlyInvalidIdError(() => decode(b))).toBe(true);
      }
    }
  });
  test("14-byte strings with lowercase namespaces and random payload bytes (multi-fault precedence)", () => {
    const rng = new Rng(13);
    for (let i = 0; i < 5000; i++) {
      const ns = rng.ns().toLowerCase();
      const b = new Uint8Array(14);
      b.set(encoder.encode(ns), 0);
      b.set(rng.bytes(11), 3);
      expect(check(b)).toBe(2);
      expect(check(b)).toBe(naiveCheck(b));
    }
  });
  test("non-string, non-bytes inputs are not a contract error", () => {
    // Totality is over byte strings; a wrong type is a programming fault and may throw anything.
    expect(() => check(undefined as unknown as string)).toThrow();
  });
});
