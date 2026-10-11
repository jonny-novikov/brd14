// generator.ts — the monotonic snowflake generator.
//
// One cell holds `ts·4096 + seq` as a Number (ts < 2^41, so the cell is below
// 2^53 and every step is exact). Each mint advances it to
// max(nowPart, last + 1): a burst past 4096 ids in one millisecond borrows into
// the timestamp, and a backward clock step keeps minting off the logical clock.
// JavaScript is single-threaded per realm, so the read-modify-write needs no CAS.

import { EPOCH_MS, encodeParts, snowFromParts, isNamespace, type Parts } from "./codec.ts";
import { ErrorCode, InvalidIdError } from "./errors.ts";

/** A clock: the current time in Unix milliseconds. */
export type Clock = () => number;

export class Generator {
  /** The 10-bit node id this generator stamps. */
  readonly node: number;
  readonly #now: Clock;
  #cell: number;

  /**
   * @param node the node id, masked to 0..1023
   * @param now  the clock; injectable for tests (defaults to Date.now)
   */
  constructor(node: number, now: Clock = Date.now) {
    this.node = node & 1023;
    this.#now = now;
    this.#cell = this.#nowPart();
  }

  #nowPart(): number {
    const ms = Math.floor(this.#now() - EPOCH_MS);
    return (ms > 0 ? ms : 0) * 4096;
  }

  /** Advances the cell and returns it: `ts·4096 + seq`. */
  #advance(): number {
    const cand = this.#nowPart();
    const next = this.#cell + 1;
    return (this.#cell = cand > next ? cand : next);
  }

  /** The next snowflake as a bigint (one BigInt allocation, the result). */
  next(): bigint {
    const c = this.#advance();
    const ts = Math.floor(c / 4096);
    return snowFromParts(ts, this.node, c - ts * 4096);
  }

  /** The next snowflake as fields, written into `out` (or a fresh object). No BigInt. */
  nextParts<T extends Parts>(out: T = { ts: 0, node: 0, seq: 0 } as unknown as T): T {
    const c = this.#advance();
    const ts = Math.floor(c / 4096);
    out.ts = ts;
    out.node = this.node;
    out.seq = c - ts * 4096;
    return out;
  }

  /** The next snowflake, branded under `ns`, through the zero-BigInt `encodeParts` path. */
  nextBranded(ns: string): string {
    if (!isNamespace(ns)) throw new InvalidIdError(ErrorCode.NAMESPACE);
    const c = this.#advance();
    const ts = Math.floor(c / 4096);
    return encodeParts(ns, ts, this.node, c - ts * 4096);
  }
}
