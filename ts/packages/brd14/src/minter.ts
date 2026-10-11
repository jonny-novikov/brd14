// minter.ts — the policy seam.
//
// The codec knows what a namespace looks like, nothing about what one means.
// A Gate is the consumer's policy: it throws to refuse. The gate runs FIRST,
// on the raw namespace, and whatever it throws reaches the caller unchanged
// (the same object, not wrapped). Only an admitted namespace reaches the
// codec, whose shape check still applies: a nil gate is "no policy", never
// "no validation".

import { encodeParts, snowFromParts, type Parts } from "./codec.ts";
import { NamespaceRefusedError } from "./errors.ts";
import { Generator } from "./generator.ts";

/** A namespace policy: return to admit, throw to refuse. */
export type Gate = (ns: string) => void;

/** The explicit spelling of the absent gate: every namespace passes policy. */
export const allowAll: Gate = () => {};

/** Refuses every namespace with a `NamespaceRefusedError`. The safe initial value for a minter wired later. */
export const denyAll: Gate = (ns) => {
  throw new NamespaceRefusedError(ns);
};

export interface Minted {
  id: string;
  snow: bigint;
}

export class Minter {
  readonly #g: Generator;
  readonly #gate: Gate | undefined;
  readonly #parts: Parts = { ts: 0, node: 0, seq: 0 };

  /**
   * @param generator the generator to gate — shared with callers that mint bare snowflakes
   * @param gate      the policy; `undefined`/`null` admits every well-formed namespace
   */
  constructor(generator: Generator, gate?: Gate | null) {
    if (!(generator instanceof Generator)) throw new TypeError("brd14: Minter needs a Generator");
    this.#g = generator;
    this.#gate = gate ?? undefined;
  }

  /** Gates `ns`, then brands the next snowflake. */
  mint(ns: string): string {
    if (this.#gate !== undefined) this.#gate(ns);
    return this.#g.nextBranded(ns);
  }

  /** `mint`, also returning the snowflake behind the id. */
  mintSnowflake(ns: string): Minted {
    if (this.#gate !== undefined) this.#gate(ns);
    const p = this.#g.nextParts(this.#parts);
    const id = encodeParts(ns, p.ts, p.node, p.seq);
    return { id, snow: snowFromParts(p.ts, p.node, p.seq) };
  }

  /** The underlying generator: the ungated path, named so every bypass reads as one. */
  get generator(): Generator {
    return this.#g;
  }
}
