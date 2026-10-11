# Roadmap — further implementation and measurement

Where the work stands, and the plan to finish. Each item states the value it delivers.

## Done (on `master`, with the CLI and agent guides on `claude/workflow`)

| Wave | Delivered |
|---|---|
| W0 | Go moved to `go/` (`github.com/jonny-novikov/brd14/go`, go 1.22 floor). `native/` split by language and variant. Pinned toolchains via `scripts/setup.sh` and a SessionStart hook: Go 1.26.9, Python 3.14/3.14t, Node 24.21.0 LTS, Bun 1.4.3, Rust 1.99.0. The normative [contract](contract.md). |
| W1 | The independent [oracle](../tools/oracle.py), deterministic [vectors](../vectors/), the differential [parity](parity.md) driver and its self-test. |
| W2 | Go reference (typed errors, zero-alloc API, fuzz). C speed and table-free memory cores (gates, sanitizers, libFuzzer). Rust workspace (`no_std` core, FFI drop-in, wasm ABI crate, Miri, cargo-fuzz). Pure Python (3.12–3.14t). Pure TypeScript (Node + Bun). The [namespaces and storage article](articles/namespaces-and-storage.md) with a reproducible [storage probe](../tools/storage_probe/). **Parity: 10 of 12 shims, 0 mismatches.** |
| W3 | `ts/packages/brd14-wasm`: the Rust core over WebAssembly on Node and Bun, with batch APIs. The wasm shims, the bench and [wasm.md](wasm.md). **Parity: 12 of 12 shims, 0 mismatches.** |
| CLI | `scripts/brd.sh` + `scripts/mint.sh` (pure bash, shim 13), `.brdrc`, `CLAUDE.md`, `AGENTS.md`. **Parity: 13 of 13.** |

## Next — implementation

1. **Fold `native/beam` into `make -C native test`**, so `make test` runs the NIF link check as
   well.
2. **Open decisions for the Operator:**
   - **NIF `encode/2` with a namespace that isn't 3 bytes:** it raises `badarg` today, while the
     contract classes this as NAMESPACE (`:error`).
   - **`MinFor` before the epoch:** Go wraps, Rust saturates, Python/TS/oracle go negative. Pick
     one behaviour and add it to the contract and to parity.
   - **brd16 metadata placement:** suffix vs namespace-adjacent, and whether the metadata is
     fixed at mint time.
3. **Door-open formats.** If brd15/brd16 are approved:
   - add `vectors/brd16/*.tsv` from the oracle;
   - add a length-dispatching `ParseAny` to each tree;
   - extend parity with `E16`/`D16` requests.
4. **Accelerations noted, not built:**
   - PyO3/maturin binding over `native/rust` for Python;
   - SWAR/AVX2 batch decode for the speed tier (the CPU has AVX2, AVX-512BW and BMI2);
   - batch NIFs for EchoMQ bulk paths.

## Next — measurement

1. **A consolidated bench run.** The current numbers are a per-agent baseline. Run `make bench`
   for every tree in one quiet session:
   - `taskset -c 2`, nothing else running;
   - `env -u BUN_OPTIONS -u NODE_OPTIONS`;
   - then `python3 tools/benchreport.py`.

   Accept a result only at CV ≤ 5%, and report the ratios against C speed from that same session.
2. **wasm vs pure TS crossover:** the per-call boundary cost against batch size, on Node and on Bun.
3. **3.14t scaling curve:** 1–4 threads for encode, per-thread generators and a shared generator.
4. **BEAM:** NIF call cost vs pure Elixir, on the pinned EchoMQ bench (OTP 25, erts 13.2.2.5).
5. **Storage at scale:** re-run [the probe](../tools/storage_probe/) at N = 10M, and add Valkey 9
   (key embedding) and MySQL 8 (the collation trap, executed rather than cited).

## Next — CI

[`.github/workflows/ci.yml`](../.github/workflows/ci.yml) runs these jobs:

- oracle self-test, vectors reproducibility, and a check that the CI pins match
  `scripts/versions.env`;
- Go 1.26.9 and the 1.22.12 floor (race, fuzz);
- native: C, Rust and NIF;
- harden: Miri and libFuzzer;
- Python 3.12, 3.13, 3.14 and 3.14t;
- TS on Node and Bun;
- parity with `--require`.

The parity job requires all 13 shims (`--require`, no filter). The first green run is the
acceptance gate for this branch.
