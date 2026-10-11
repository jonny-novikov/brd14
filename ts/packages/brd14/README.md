# brd14

A 14-byte branded identity — **time-ordered**, **coordination-free**, carrying its own type — in
pure TypeScript with exact 64-bit arithmetic and no BigInt on the hot path.

```
USR0KHTOWnGLuC
└┬┘└─────┬────┘
 │       └─ 11 chars of base62 over a ts(41)|node(10)|seq(12) snowflake, epoch 2024-01-01Z
 └───────── a 3-letter uppercase namespace — the brand IS the type
```

Runs on Node ≥ 24 and Bun ≥ 1.4. No dependencies.

```ts
import { Generator, Minter, decode, encode, fields, isValid, unixMs } from "brd14";
import { defaultNode } from "brd14/node";

const g = new Generator(defaultNode());
const id = g.nextBranded("USR");          // "USR0KHTOWnGLuC" — no BigInt touched
const { ns, snow } = decode(id);          // "USR", 274557032793636864n
unixMs(snow);                             // the mint instant
fields(snow);                             // { ts, node, seq }
isValid(id);                              // total, never throws

// policy is yours: the gate runs first, on the raw namespace, and its throw is passed through
const m = new Minter(g, (ns) => {
  if (!census.has(ns)) throw new Error(`refusing to mint ${ns}: not in the census`);
});
m.mint("USR");
```

Every refusal is an `InvalidIdError` with `.code` ∈ `ErrorCode` (`LENGTH`, `NAMESPACE`, `CHARSET`,
`RANGE`), precedence namespace-first. Zero-BigInt variants: `encodeParts`, `encodeInto`,
`decodePartsInto`, `hash32Parts`, `Generator.nextParts`.

The contract, the design and the measurements live in the repository:
`docs/contract.md`, `docs/typescript.md`.

MIT.
