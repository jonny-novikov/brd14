// generator.test.ts — the three properties the contract demands of a generator,
// proven with an injected clock: strictly increasing under every clock regime,
// a burst past 4096/ms borrows into the timestamp, a backward step keeps minting.

import { describe, expect, test } from "vitest";
import { EPOCH_MS, Generator, InvalidIdError, decode, fields, isValid, unixMs } from "brd14";

const T0 = 1_769_526_697_641; // E-1

describe("Generator", () => {
  test("strictly increasing with the real clock; node and namespace stamped", () => {
    const g = new Generator(7);
    let prev = -1n;
    for (let i = 0; i < 5000; i++) {
      const id = g.nextBranded("SES");
      expect(isValid(id)).toBe(true);
      const { ns, snow } = decode(id);
      expect(ns).toBe("SES");
      expect(snow > prev).toBe(true);
      expect(fields(snow).node).toBe(7);
      prev = snow;
    }
  });

  // The cell starts at the construction instant's nowPart, and every mint
  // advances it by at least one, so the first mint in the same millisecond as
  // the construction carries seq 1 — as in the Go reference.
  test("next(), nextParts() and nextBranded() share one cell", () => {
    let now = T0;
    const g = new Generator(613, () => now);
    const a = g.next();
    const p = g.nextParts();
    const c = decode(g.nextBranded("USR")).snow;
    expect(fields(a)).toEqual({ ts: T0 - EPOCH_MS, node: 613, seq: 1 });
    expect(p).toEqual({ ts: T0 - EPOCH_MS, node: 613, seq: 2 });
    expect(fields(c)).toEqual({ ts: T0 - EPOCH_MS, node: 613, seq: 3 });
    now += 1;
    expect(fields(g.next())).toEqual({ ts: T0 - EPOCH_MS + 1, node: 613, seq: 0 });
    const out = { ts: -1, node: -1, seq: -1 };
    expect(g.nextParts(out)).toBe(out);
    expect(out).toEqual({ ts: T0 - EPOCH_MS + 1, node: 613, seq: 1 });
  });

  test("a burst past 4096 ids in one millisecond borrows into the timestamp", () => {
    const g = new Generator(1, () => T0);
    let prev = -1n;
    for (let i = 1; i <= 4096 * 3; i++) {
      const s = g.next();
      expect(s > prev).toBe(true);
      const f = fields(s);
      expect(f.ts).toBe(T0 - EPOCH_MS + Math.floor(i / 4096));
      expect(f.seq).toBe(i % 4096);
      prev = s;
    }
    // the borrowed time is ahead of the wall clock, and no id was skipped or repeated
    expect(unixMs(g.next())).toBe(T0 + 3);
  });

  test("a backward clock step keeps minting off the logical clock", () => {
    let now = T0;
    const g = new Generator(2, () => now);
    const a = g.next();
    now = T0 - 10_000;
    const b = g.next();
    const c = g.next();
    expect(b > a && c > b).toBe(true);
    expect(fields(b)).toEqual({ ts: T0 - EPOCH_MS, node: 2, seq: 2 });
    expect(fields(c)).toEqual({ ts: T0 - EPOCH_MS, node: 2, seq: 3 });
    now = T0 + 5;
    const d = g.next();
    expect(fields(d)).toEqual({ ts: T0 - EPOCH_MS + 5, node: 2, seq: 0 });
    // and a clock jump forward is followed immediately
    now = T0 + 1_000_000;
    expect(unixMs(g.next())).toBe(T0 + 1_000_000);
  });

  test("a clock before the epoch is clamped to the epoch", () => {
    const g = new Generator(3, () => EPOCH_MS - 1);
    expect(fields(g.next())).toEqual({ ts: 0, node: 3, seq: 1 });
    expect(fields(g.next())).toEqual({ ts: 0, node: 3, seq: 2 });
  });

  test("the node is masked to 10 bits", () => {
    expect(new Generator(1024).node).toBe(0);
    expect(new Generator(1023 + 2048).node).toBe(1023);
    expect(fields(new Generator(5000, () => T0).next()).node).toBe(5000 & 1023);
  });

  test("nextBranded refuses a malformed namespace without consuming a sequence number", () => {
    const g = new Generator(4, () => T0);
    const fresh = new Generator(4, () => T0);
    expect(() => g.nextBranded("usr")).toThrow(InvalidIdError);
    expect(() => g.nextBranded("US")).toThrow(InvalidIdError);
    expect(g.next()).toBe(fresh.next());
  });

  test("ids from one generator sort as strings in mint order", () => {
    let now = T0;
    const g = new Generator(9, () => now);
    const ids: string[] = [];
    for (let i = 0; i < 10000; i++) {
      if (i % 7 === 0) now += 1;
      if (i % 1000 === 0) now -= 3;
      ids.push(g.nextBranded("ORD"));
    }
    expect([...ids].sort()).toEqual(ids);
    expect(new Set(ids).size).toBe(ids.length);
  });
});
