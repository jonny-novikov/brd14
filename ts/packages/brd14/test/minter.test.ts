// minter.test.ts — the policy seam: gate-first on the raw namespace, the
// refusal reaches the caller unchanged, a nil gate is no policy but still
// validation, denyAll is not an InvalidIdError.

import { describe, expect, test } from "vitest";
import { Generator, InvalidIdError, Minter, NamespaceRefusedError, allowAll, decode, denyAll, fields, isValid, type Gate } from "brd14";
import { caught } from "./helpers.ts";

const census: Record<string, string> = { USR: "active", SES: "active", LOG: "retired" };

class CensusError extends Error {
  readonly ns: string;
  readonly status: string | undefined;

  constructor(ns: string, status: string | undefined) {
    super(`census: ${JSON.stringify(ns)} is ${status ?? "unknown"}`);
    this.name = "CensusError";
    this.ns = ns;
    this.status = status;
  }
}

const censusGate: Gate = (ns) => {
  if (census[ns] !== "active") throw new CensusError(ns, census[ns]);
};

describe("Minter", () => {
  test("a nil gate admits any well-formed namespace and still enforces the shape", () => {
    const m = new Minter(new Generator(7));
    const id = m.mint("ZZZ");
    expect(isValid(id)).toBe(true);
    expect(decode(id).ns).toBe("ZZZ");
    expect(fields(decode(id).snow).node).toBe(7);
    expect(caught(() => m.mint("zz1"))).toBeInstanceOf(InvalidIdError);
    expect((caught(() => m.mint("zz1")) as InvalidIdError).code).toBe(2);
  });

  test("allowAll matches the nil gate; null is the nil gate too", () => {
    for (const m of [new Minter(new Generator(3), allowAll), new Minter(new Generator(3), null)]) {
      expect(isValid(m.mint("ANY"))).toBe(true);
      expect(caught(() => m.mint("any"))).toBeInstanceOf(InvalidIdError);
    }
  });

  test("denyAll refuses everything with a NamespaceRefusedError, which is not an InvalidIdError", () => {
    const m = new Minter(new Generator(1), denyAll);
    for (const ns of ["USR", "ZZZ", "usr", "", "TOOLONG"]) {
      const e = caught(() => m.mint(ns));
      expect(e).toBeInstanceOf(NamespaceRefusedError);
      expect(e).not.toBeInstanceOf(InvalidIdError);
      expect((e as NamespaceRefusedError).ns).toBe(ns);
      expect((e as Error).name).toBe("NamespaceRefusedError");
    }
  });

  test("the gate's refusal reaches the caller unchanged — the same object", () => {
    const sentinel = { reason: "not a brand", ns: "" };
    const m = new Minter(new Generator(1), (ns) => {
      sentinel.ns = ns;
      throw sentinel;
    });
    const e = caught(() => m.mint("USR"));
    expect(e).toBe(sentinel);
    expect(sentinel.ns).toBe("USR");
    expect(caught(() => m.mintSnowflake("USR"))).toBe(sentinel);
    // a primitive thrown by a gate is passed through as well
    const m2 = new Minter(new Generator(1), () => {
      throw "nope";
    });
    expect(caught(() => m2.mint("USR"))).toBe("nope");
  });

  test("gate-first: the gate sees the raw namespace before the shape check", () => {
    const seen: string[] = [];
    const m = new Minter(new Generator(1), (ns) => {
      seen.push(ns);
      censusGate(ns);
    });
    // malformed AND not in the census: the census refusal wins, quoting the raw input
    const e = caught(() => m.mint("log")) as CensusError;
    expect(e).toBeInstanceOf(CensusError);
    expect(e.ns).toBe("log");
    expect(seen).toEqual(["log"]);
    // retired in the census: refused with the census's own detail
    const r = caught(() => m.mint("LOG")) as CensusError;
    expect(r.status).toBe("retired");
    // admitted: minted
    expect(decode(m.mint("USR")).ns).toBe("USR");
    expect(seen).toEqual(["log", "LOG", "USR"]);
  });

  test("an admitted but malformed namespace is the codec's InvalidIdError", () => {
    const open = new Minter(new Generator(1), allowAll);
    const e = caught(() => open.mint("us")) as InvalidIdError;
    expect(e).toBeInstanceOf(InvalidIdError);
    expect(e.code).toBe(2);
  });

  test("mintSnowflake agrees with the id and is monotonic", () => {
    const m = new Minter(new Generator(613), censusGate);
    let prev = -1n;
    for (let i = 0; i < 3000; i++) {
      const { id, snow } = m.mintSnowflake("SES");
      expect(decode(id).snow).toBe(snow);
      expect(fields(snow).node).toBe(613);
      expect(snow > prev).toBe(true);
      prev = snow;
    }
  });

  test("the generator is the ungated path and is the one given", () => {
    const g = new Generator(11);
    const m = new Minter(g, denyAll);
    expect(m.generator).toBe(g);
    expect(caught(() => m.mint("USR"))).toBeInstanceOf(NamespaceRefusedError);
    expect(isValid(m.generator.nextBranded("USR"))).toBe(true);
  });

  test("a Minter without a Generator is a construction fault", () => {
    expect(caught(() => new Minter(undefined as unknown as Generator))).toBeInstanceOf(TypeError);
    expect(caught(() => new Minter({} as Generator, allowAll))).toBeInstanceOf(TypeError);
  });
});
