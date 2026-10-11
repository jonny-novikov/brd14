// helpers.ts — shared by the test files of brd14-wasm. The vectors directory,
// the TSV reader, the pinned PRNG and the small codecs are the pure package's
// (../../brd14/test/helpers.ts); this file adds what the differential tests
// need: a canonical rendering of "what a call did" so that the wasm package and
// the pure package can be compared with one `toBe`.

import { InvalidIdError } from "brd14";
import { Rng } from "../../brd14/test/helpers.ts";

export { ALPHABET, Rng, VECTORS_DIR, VECTORS_PRESENT, VECTORS_REQUIRED, caught, encoder, readTsv, unhex, utf8 } from "../../brd14/test/helpers.ts";

/**
 * "OK <rendered value>" or "ERR <code>". An `InvalidIdError` is the only exception a
 * codec call may raise for a string or byte input; anything else is a bug and propagates.
 */
export function outcome(fn: () => unknown): string {
  try {
    return `OK ${render(fn())}`;
  } catch (e) {
    if (e instanceof InvalidIdError) return `ERR ${e.code}`;
    throw e;
  }
}

function render(v: unknown): string {
  if (typeof v === "bigint") return `${v}n`;
  if (typeof v === "object" && v !== null && "ns" in v && "snow" in v) {
    const d = v as { ns: string; snow: bigint };
    return `${d.ns} ${d.snow}n`;
  }
  return String(v);
}

const HOSTILE = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!@#$%^&*()-_=+[]{};:'\",.<>/?`~ \t\né€😀";

/** A random string of length 0..20 from one of four character classes (lone surrogates included). */
export function randomString(rng: Rng, maxLen = 21): string {
  const len = rng.below(maxLen);
  const kind = rng.below(4);
  let s = "";
  for (let i = 0; i < len; i++) {
    switch (kind) {
      case 0:
        s += HOSTILE[rng.below(HOSTILE.length)];
        break;
      case 1:
        s += String.fromCharCode(rng.below(128));
        break;
      case 2:
        s += String.fromCharCode(rng.below(256));
        break;
      default:
        s += String.fromCharCode(rng.below(65536));
    }
  }
  return s;
}

/** A random 14-character string that is mostly, but not always, a valid id. */
export function nearlyValidId(rng: Rng, encode: (ns: string, snow: bigint) => string): string {
  const id = encode(rng.ns(), rng.snow());
  switch (rng.below(6)) {
    case 0:
      return id;
    case 1: {
      // one byte replaced anywhere
      const pos = rng.below(14);
      return id.substring(0, pos) + String.fromCharCode(rng.below(256)) + id.substring(pos + 1);
    }
    case 2:
      return id.toLowerCase();
    case 3:
      return id.substring(0, 13); // 13 bytes: LENGTH
    case 4:
      return id.substring(0, 13) + "é"; // 14 chars, 15 bytes: LENGTH
    default:
      return id.substring(0, 3) + "zzzzzzzzzzz"; // RANGE
  }
}

/** The bigints the range guard cares about, on both sides of 2^63 and 2^64. */
export const RANGE_EDGES: readonly bigint[] = [
  0n,
  1n,
  (1n << 63n) - 2n,
  (1n << 63n) - 1n,
  1n << 63n,
  (1n << 63n) + 1n,
  (1n << 64n) - 1n,
  1n << 64n,
  (1n << 64n) + 5n,
  1n << 65n,
  (1n << 70n) + 3n,
  -1n,
  -2n,
  -(1n << 63n),
  -(1n << 63n) - 1n,
  -(1n << 64n),
];
