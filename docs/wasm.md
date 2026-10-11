# TypeScript over WebAssembly — `brd14-wasm`

The Rust `no_std` core ([`native/rust/crates/brd14-wasm`](../native/rust/crates/brd14-wasm/))
compiled to wasm32, embedded in a TypeScript package that runs the same code path on Node 24 and
Bun 1.4. The ABI is normative and lives in
[contract.md](contract.md#the-webassembly-abi-nativerustcratesbrd14-wasm).

## Status

**Complete.** The parity shims `ts-wasm-node` and `ts-wasm-bun` each pass 27,637 requests with 0
mismatches. `make -C ts test` passes 154/154 tests on vitest (Node) and on `bun test` (Bun); that
total covers both packages.

## The module

| Fact | Value |
|---|---|
| Size | speed core **10,019 B** (the default); memory core 2,639 B |
| Imports | none |
| Allocator | none. A static 64 KiB IO region is exposed by `io_ptr()` |
| Memory | fixed at 3 pages (`--initial-memory = --max-memory`), so `grow` fails and JS views never detach |
| Batch clamp | `n ∈ [0, 2978]` per call, the most that fits the IO region; the loader chunks larger batches |

**Default core: speed.** Inside wasm on Node 24, the speed core's `encode_many` takes 6.5 ns per
id and `decode_many` 8.9 ns per id. The memory core takes 19.6 and 25.1 ns. That is about 3× the
speed for 7.4 KB more module.

## Why no wasm-bindgen

The ABI is five integer functions and one byte region, so there is nothing to bind. Raw exports
keep the module import-free and 10 KB. They also keep the JS side to one synchronous
instantiation, and they need no `wasm-bindgen-cli` matched to a crate version in the build.

## The loader

- [`scripts/build-wasm.ts`](../ts/packages/brd14-wasm/scripts/build-wasm.ts) runs
  `cargo build -p brd14-wasm --target wasm32-unknown-unknown --release`.
- It writes the generated, gitignored `src/wasm-bytes.ts`, which holds:
  - the module as base64;
  - its byte length;
  - its core name;
  - its sha256.

  `make -C ts wasm-bytes` rebuilds it when a Rust source is newer.
- [`src/module.ts`](../ts/packages/brd14-wasm/src/module.ts) decodes the base64 with `atob`.
  `Uint8Array.fromBase64` is not available in Node 24's V8.
- It then instantiates the module synchronously, once, at import (`new WebAssembly.Module` and
  `new WebAssembly.Instance`, no imports). There is no `await init()`, so Node and Bun run
  identical code.
- It caches typed-array views of the IO region once. Memory cannot grow, so the views stay valid
  for the life of the process.

## Mapping JS values onto the ABI

| JS input | What crosses the boundary |
|---|---|
| namespace `string` | classified on its UTF-8 bytes, exactly like the pure package. Three ASCII bytes are packed little-endian into an `i32`; anything else is refused as `NAMESPACE` before the call |
| snowflake `bigint` | an `i64`. A value outside `[0, 2^63)` goes in as `-1`, so wasm applies the contract's namespace-then-range precedence and `2^64 + x` can never wrap through |
| id `string` | classified on its UTF-8 bytes. A non-ASCII character changes the byte length, so it is `LENGTH`, as in the pure package |
| id `Uint8Array` | copied as-is into the IO region. Anything over 64 KiB is `LENGTH` without a call |
| result | `decode` returns an `i64`: a value ≥ 0 is the snowflake, and −1 to −4 is the error code, thrown as the pure package's `InvalidIdError` |

`Generator`, `Minter`, `InvalidIdError` and `ErrorCode` are re-exported from the pure `brd14`
package, not duplicated. A test checks that every result and error matches the pure package for
every input.

## API

```ts
import { encode, decode, check, isValid, hash32,
         encodeMany, encodeManyInto, decodeMany, decodeManyInto, checkMany } from "brd14-wasm";

encode("USR", 274557032793636864n);          // "USR0KHTOWnGLuC"
decode("USR0NgWEfAEJfs");                    // { ns: "USR", snow: 320636799581945856n }
encodeMany("USR", snows);                    // string[]: one ABI crossing per 2,978 ids
encodeManyInto("USR", snows, out);           // writes 14·n bytes into `out`; creates no strings
decodeMany(idBytes);                         // BigInt64Array; a refused id throws BatchInvalidIdError (index + code)
checkMany(idBytes);                          // Uint8Array of codes; never throws
```

## When wasm wins, and when it doesn't

The numbers below come from one unpinned smoke run on Node 24.21.0 on a shared machine. Read the
ratios, not the absolute values. Each figure is ns per id, from `ts/bench/wasm.ts`, which times the
pure package in the same process.

| Op | wasm | pure (same process) | Ratio |
|---|---:|---:|---:|
| `encode`, one crossing per id | 101 | 98 | 1.0× |
| `decode`, one crossing per id | 115 | 127 | 1.1× |
| `encode_many` → `string[]` | 55 | 98 | 1.8× |
| `encode_many_into` → bytes | **11.5** | 98 | **8.6×** |
| `decode_many` → `BigInt64Array` | **21.4** | 127 | **5.9×** |

- **Per-id calls are a wash.** The time goes to building the JS string and the BigInt, and to
  crossing the boundary, not to the base62 arithmetic. The pure package already does that
  arithmetic without BigInt.
- **Batches win because the strings disappear.** Writing ids into a byte buffer or reading them
  from one moves the work into wasm, and the result is 6–9×.
- **Use** `encodeManyInto` and `decodeMany` for bulk paths: ETL, log replay, index rebuilds, wire
  formats that carry bytes.
- **Use** the pure package for single ids.

A pinned, quiet run on both runtimes is planned in [roadmap.md](roadmap.md).

## Build, test, bench

```bash
. scripts/env.sh
make -C ts wasm-bytes     # cargo → src/wasm-bytes.ts
make -C ts test           # typecheck + vitest (Node) + bun test (Bun), both packages
python3 tools/parity.py --only ts-wasm
make -C ts bench          # both benches, both runtimes, BUN_OPTIONS/NODE_OPTIONS cleared
```
