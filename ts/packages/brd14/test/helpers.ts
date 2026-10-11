// helpers.ts — shared by the test files: the vectors directory, TSV parsing, a
// pinned PRNG, and small codecs. Not a test file itself.

import { existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** `<repo>/vectors/`, absent in a published tarball. */
export const VECTORS_DIR = fileURLToPath(new URL("../../../../vectors/", import.meta.url));
export const VECTORS_PRESENT = existsSync(VECTORS_DIR);
export const VECTORS_REQUIRED = process.env["BRD14_REQUIRE_VECTORS"] === "1";

/** Data rows of a vectors TSV: comment lines dropped, columns split on TAB. */
export function readTsv(name: string): string[][] {
  return readFileSync(VECTORS_DIR + name, "utf8")
    .split("\n")
    .filter((l) => l.length > 0 && !l.startsWith("#"))
    .map((l) => l.split("\t"));
}

/** Hex as the vectors write it: lowercase, "-" for empty. */
export function unhex(s: string): Uint8Array {
  if (s === "-") return new Uint8Array(0);
  const out = new Uint8Array(s.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = Number.parseInt(s.substr(2 * i, 2), 16);
  return out;
}

const decoder = new TextDecoder("utf-8", { fatal: true });

/** The string form of valid UTF-8 bytes, or undefined. */
export function utf8(b: Uint8Array): string | undefined {
  try {
    return decoder.decode(b);
  } catch {
    return undefined;
  }
}

export const encoder = new TextEncoder();

/** The one error a codec call may throw, captured; `undefined` when it returned. */
export function caught(fn: () => unknown): unknown {
  try {
    fn();
    return undefined;
  } catch (e) {
    return e;
  }
}

/** sfc32 — a small, fast, well-distributed 32-bit PRNG with a pinned seed. */
export class Rng {
  #a: number;
  #b: number;
  #c: number;
  #d: number;

  constructor(seed: number) {
    this.#a = 0x9e3779b9;
    this.#b = 0x243f6a88;
    this.#c = 0xb7e15162;
    this.#d = seed | 0;
    for (let i = 0; i < 16; i++) this.u32();
  }

  /** Uniform in [0, 2^32). */
  u32(): number {
    const t = (((this.#a + this.#b) | 0) + this.#d) | 0;
    this.#d = (this.#d + 1) | 0;
    this.#a = this.#b ^ (this.#b >>> 9);
    this.#b = (this.#c + (this.#c << 3)) | 0;
    this.#c = (this.#c << 21) | (this.#c >>> 11);
    this.#c = (this.#c + t) | 0;
    return t >>> 0;
  }

  /** Uniform in [0, n) for n ≤ 2^32 (modulo bias is irrelevant for property tests). */
  below(n: number): number {
    return this.u32() % n;
  }

  /** Uniform in [0, 2^63). */
  snow(): bigint {
    return (BigInt(this.u32() >>> 1) << 32n) | BigInt(this.u32());
  }

  /** Uniform in [0, 2^64). */
  u64(): bigint {
    return (BigInt(this.u32()) << 32n) | BigInt(this.u32());
  }

  ns(): string {
    return String.fromCharCode(65 + this.below(26), 65 + this.below(26), 65 + this.below(26));
  }

  bytes(n: number): Uint8Array {
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) out[i] = this.below(256);
    return out;
  }
}

export const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
