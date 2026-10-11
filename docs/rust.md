# Rust

The Rust tree, [`native/rust/`](../native/rust/), is a Cargo workspace on edition 2024, pinned to
Rust 1.99.0 by [`rust-toolchain.toml`](../native/rust/rust-toolchain.toml). It implements the
[contract](contract.md) in two cores, `speed` and `memory`. Around them it ships a C ABI drop-in, the
WebAssembly module, and the parity shim. The library crates use no third-party crates, including
dev-dependencies.

## Crate map

| Crate | Kind | What it is |
|---|---|---|
| [`crates/brd14`](../native/rust/crates/brd14/) | `#![no_std]` lib, `#![forbid(unsafe_code)]` | The codec. `brd14::speed` and `brd14::memory` have the same API. The crate root re-exports `speed`, plus the table-free helpers. The `std` feature adds `Generator` and `Minter`. |
| [`crates/brd14-ffi`](../native/rust/crates/brd14-ffi/) | `cdylib` + `staticlib`, `no_std` | A drop-in for [`branded_id.h`](../native/include/branded_id.h). Builds `libbrd14_ffi.so` and `libbrd14_ffi.a`. The core is speed by default; the `memory` feature selects memory. |
| [`crates/brd14-wasm`](../native/rust/crates/brd14-wasm/) | `cdylib`, `no_std` | The [WebAssembly ABI](contract.md#the-webassembly-abi-nativerustcratesbrd14-wasm). Builds `brd14_wasm.wasm`. Same core switch as the ffi crate. |
| [`crates/brd14-conform`](../native/rust/crates/brd14-conform/) | std bin | The parity shim: `brd14-conform speed\|memory`. |
| [`fuzz/`](../native/rust/fuzz/) | cargo-fuzz project | Two libFuzzer differential targets. It is excluded from the workspace and has its own lockfile. |

### Public API of `brd14`

| Item | Notes |
|---|---|
| `encode(&[u8; 3], u64) -> Result<[u8; 14], Error>` | Returns the id by value, with no buffer and no allocation. A 3-byte array type means the length is checked by the type system. Callers holding a `&[u8]` of another length report `NAMESPACE`, as the conform shim does. |
| `decode(&[u8]) -> Result<([u8; 3], u64), Error>` | Total over every byte string. |
| `hash32`, `unix_ms`, `node_of`, `seq_of`, `fields`, `min_for`, `node_from` | All `const fn` and table-free. They are shared by both cores. |
| `Error` | `Length = 1`, `Namespace = 2`, `Charset = 3`, `Range = 4`, `#[repr(i32)]` (the C ABI codes). Implements `Display` and `core::error::Error`. `code()` returns the status code and `class()` returns `"LENGTH"` etc. |
| `LEN`, `NS_LEN`, `PAYLOAD_LEN`, `EPOCH_MS`, `MAX_SNOW`, `ALPHABET`, field widths | Constants. |
| `speed::TABLE_BYTES` = 7,944; `memory::TABLE_BYTES` = 0; `memory::{QA, RB}` | The footprint and the arithmetic guard constants. |
| `Generator`, `Clock`, `SystemClock`, `default_node`, `Minter`, `MintError`, `allow_all` | Behind the `std` feature. |

`min_for` is total. An instant before the epoch gives `0`, so every snowflake qualifies. An
instant past the 41-bit timestamp horizon gives `2^63`, so none does. `node_from(host, pid: u32)`
writes the decimal pid into a 10-byte stack buffer, so it allocates nothing.

## Building and testing

```bash
. scripts/env.sh
make -C native/rust test       # workspace suites + C drop-in check (both cores) + wasm ABI check (both cores)
make -C native/rust conform    # target/release/brd14-conform
python3 tools/parity.py --only rust-
make -C native/rust ffi        # target/release/libbrd14_ffi.{so,a}  (FFI_FEATURES=--features=memory)
make -C native/rust wasm       # target/wasm32-unknown-unknown/release/brd14_wasm.wasm (WASM_FEATURES=--features=memory)
make -C native/rust bench      # pinned, JSON into bench/results/
make -C native/rust harden     # fmt + clippy, alloc check, Miri, fuzz (nightly)
```

When `cargo` is not on `PATH`, the Makefile adds `~/.cargo/bin` itself. This lets
`tools/parity.py`, which calls `make conform`, work without `scripts/env.sh`.

## Guarantees and how they are enforced

| Guarantee | Enforcement |
|---|---|
| **`no_std`** | `brd14` is `#![no_std]`. `brd14-ffi` and `brd14-wasm` are `no_std` outside `cfg(test)` and define their own `#[panic_handler]`. If anything linked `std` into them, the two panic handlers would collide at compile time. |
| **No allocation** | No crate links `alloc`, and both codecs return fixed-size arrays by value. `make alloc-check` fails if `nm -u` on `libbrd14_ffi.so` or `.a` names any allocator symbol. The `.so`'s whole undefined-symbol list is the C runtime's weak `_ITM_*`, `__cxa_finalize` and `__gmon_start__`. It imports **nothing from libc**, not even `memcmp` (see the speed core's range guard). The wasm module has an empty import list. |
| **No `unsafe` in the codec** | `#![forbid(unsafe_code)]` on `brd14`. Only two crates contain `unsafe`: the ffi crate (raw pointers from C) and the wasm crate (its static IO region). Both run under Miri with strict provenance. |
| **No panics** | Decode is total: a length mismatch is a `let … else`, and payload access uses slice patterns on a `&[u8; 14]`. Off-alphabet bytes go through wrapping arithmetic (speed) or contribute digit 0 (memory). After LTO, `nm` on `libbrd14_ffi.so` finds no panic symbol, and the disassembly of `branded_decode` contains no `call`. |

The `std` feature, and the `Generator` behind it, is compiled under
`cfg(any(test, feature = "std"))`. Its unit tests therefore run in a plain
`cargo test --workspace`, while no workspace member enables `std` on `brd14`. Enabling it on a crate
with its own panic handler (ffi, wasm) would collide, so the bench enables it only through
`cargo bench -p brd14 --features std`.

## The two cores

Both cores split the value at 62^6 into `hi` (5 digits, `< 62^5`, so a `u32`) and `lo` (6 digits).
That gives two independent dependency chains that the CPU overlaps. Every divisor is a compile-time
constant, which LLVM strength-reduces to a multiply and a shift.

| | `speed` | `memory` |
|---|---|---|
| encode | Two digits per divmod through a 62×62 pair table (7,688 bytes, built by `const fn`). That is 2 + 2 divmods. | One digit per divmod (5 + 6). The digit becomes a char arithmetically: `'0' + d`, +7 past `'9'`, +6 past `'Z'`. |
| decode | One 256-byte table maps each byte to digit + 1, with 0 for invalid. The charset check and digit extraction share one load and are branchless. | Three disjoint range masks (`0-9`, `A-Z`, `a-z`), branch-free and correct for all 256 byte values. An off-alphabet byte selects no range, so it adds digit 0 and the accumulators cannot wrap. LLVM vectorises the classifier. |
| range guard | **Lexicographic**: `payload <= "AzL8n0Y58m7"` bytewise. It compares two big-endian words (bytes 0..8, 8..11) in registers rather than calling `memcmp`. | **Arithmetic**, after the charset check: `hi < QA \|\| (hi == QA && lo <= RB)` with `QA = 162382637` and `RB = 503620799`. A `const` assertion pins `QA·62^6 + RB == 2^63 − 1`. |
| read-only data | 7,944 bytes of tables. The `.so` has 8,006 bytes of `.rodata`. | No tables. The `.so` has 80 bytes of `.rodata`, all SIMD splat constants for the vectorised range masks. |

Precedence is namespace-first in both directions, as the contract requires. Encode checks
`NAMESPACE`, then `RANGE`. Decode checks `LENGTH`, then `NAMESPACE`, `CHARSET` and `RANGE`. A
payload that is both off-alphabet and above the maximum is `CHARSET`.

## The C ABI drop-in

`brd14-ffi` exports `branded_encode`, `branded_decode`, `branded_hash32` and `branded_unix_ms`.
Their signatures and status codes match [`native/include/branded_id.h`](../native/include/branded_id.h).
The C cores and this library are interchangeable at link time:

- `make ffi-check`, part of `make test`, compiles
  [`crates/brd14-ffi/c/dropin.c`](../native/rust/crates/brd14-ffi/c/dropin.c) against the unchanged
  header. It links that program once against `libbrd14_ffi.a` and once against `libbrd14_ffi.so`,
  for each core, and asserts V-1..V-6, E-1, E-2 and the precedence rules.
- The parity run sends the same request file to `c-speed`, `c-memory`, `rust-speed` and
  `rust-memory`, and diffs each response line against the oracle. Agreement there is agreement
  between the C and Rust cores.
- `native/beam` links `native/rust/target/release/libbrd14_ffi.so` as the default core for the
  Erlang NIF.

The library also handles pointer cases. A null `ns` or `out` is refused with `NAMESPACE`, and a
null decode pointer with `LENGTH`. In both cases nothing is written. `snowflake_out` may be
unaligned.

| Artefact (release, LTO, `panic=abort`) | speed | memory |
|---|---:|---:|
| `libbrd14_ffi.so` | 14,784 B | 8,008 B |
| `libbrd14_ffi.a` | 4.6 MB¹ | 4.6 MB¹ |

¹ Almost all of the archive is `compiler_builtins` (274 of its members). A static link pulls in
only the one member holding the four symbols, and that member needs nothing external.

## The WebAssembly module

[`crates/brd14-wasm`](../native/rust/crates/brd14-wasm/src/lib.rs) implements the contract's ABI
exactly:

| Export | Semantics |
|---|---|
| `io_ptr() → i32` | Address of the 64 KiB IO region (16-byte aligned). |
| `encode(ns: i32, snow: i64) → i32` | `ns` is the namespace packed little-endian. Writes 14 bytes at `io[0..14]` and returns the status. A negative `snow` is outside `[0, 2^63)`. |
| `decode(len: i32) → i64` | Reads `len` bytes at `io[0..]` and returns the snowflake or `−code`. On success the namespace stays at `io[0..3]`. |
| `hash32(k: i64) → i32` | Both values are reinterpreted bitwise. |
| `encode_many(ns: i32, n: i32) → i32` | Reads `n` i64 at `io[0..8n]` and writes `14n` bytes at `io[8n..]`. Returns the count encoded before the first error. |
| `decode_many(n: i32) → i32` | Reads `14n` bytes and writes `n` i64 at `round_up_8(14n)`. Returns `n`. |

The contract leaves two details open. This module resolves both by refusing:

- A packed `ns` with a non-zero fourth byte is `NAMESPACE`. Such a value cannot be a 3-byte namespace.
- The batch exports clamp `n` to `[0, 2978]`. 2,978 is the largest `n` whose input and output fit in
  the region together. No call can touch memory outside the region. The TypeScript loader chunks
  larger batches.

**No imports, no allocator, fixed memory.** The IO region is a `static mut` that is only ever
reached through `&raw mut`. Each export takes one exclusive view of it and drops that view on
return. [`build.rs`](../native/rust/crates/brd14-wasm/build.rs) passes these link arguments to this
crate's `cdylib`, and only when the target is wasm32:

```
--initial-memory=196608  --max-memory=196608  -zstack-size=65536  --strip-all
```

That is three 64 KiB pages, with `initial == max`, so `memory.grow` always fails and JS views never
detach. The layout is the 64 KiB stack, then static data, then the IO region. The flags live in
`build.rs` and not in `.cargo/config.toml`, because cargo finds a config file only relative to the
working directory. A `cargo build --manifest-path …` from the repository root would silently lose
them. `--strip-all` drops the name and producers sections, so the module contains the ABI and
nothing else. Its exports are exactly the six functions plus `memory`.

The crate is an ordinary workspace member and compiles on the host. There, the exports lose
`#[no_mangle]`, and the ABI logic (batches, clamping, refusals) is unit-tested natively and under
Miri. A mutex serialises the tests over the one region.

[`check.mjs`](../native/rust/crates/brd14-wasm/check.mjs) verifies a built module through its raw
exports in Node 24. `make wasm-check`, part of `make test`, runs it on both cores. It checks:

- the import list is empty;
- the exports equal the ABI plus `memory`, with the right arities;
- `memory.grow(1)` throws and `byteLength` never changes;
- V-1..V-6 and precedence;
- every row of `valid.tsv`, `invalid.tsv` and `encode_invalid.tsv`, plus `encode_many` and
  `decode_many` over the whole corpus in 2,978-id chunks. This step skips when `vectors/` is absent
  and fails when it is absent with `BRD14_REQUIRE_VECTORS=1`.

### Choosing the default core

Both cores build into wasm. `make wasm-cores` writes them to `target/wasm-cores/`. One indicative
run with `check.mjs --bench`, in Node 24.21.0, each core in its own process, pinned to one core:

| Module | Bytes | encode | decode | hash32 | encode_many / id | decode_many / id |
|---|---:|---:|---:|---:|---:|---:|
| **speed** (default) | **10,019** | 11.3 ns | 45.8 ns | 4.9 ns | **6.5 ns** | **8.9 ns** |
| memory | 2,639 | 24.6 ns | 61.0 ns | 4.7 ns | 19.6 ns | 25.1 ns |

The single-call `decode` column is dominated by the JS side: copying 14 bytes into the region and
returning a BigInt. The batch columns isolate the cores, and there **speed is about 3× faster per
id**. **Speed is the default.** It costs 7.4 KB more, nearly all of it the pair and decode tables in
the data segment, and at about 10 KB the module is still tiny. For a bundle where size matters
more than throughput, `make wasm WASM_FEATURES=--features=memory` builds the 2.6 KB module. Its
ABI is identical.

## The generator and the minter (`std` feature)

`Generator<C: Clock = SystemClock>` mirrors the Go reference. One `AtomicU64` cell holds
`ts << 12 | seq`, with `ts` relative to the epoch. `next()` CAS-advances the cell to
`max(now_part, last + 1)` and returns `ts << 22 | node << 12 | seq`. It is lock-free and
allocation-free. The construction is the same as Go's: the cell starts at the current instant, so
the first mint within the same millisecond has `seq` 1.

| Property | Test (`src/generator.rs`) |
|---|---|
| Strictly increasing within one generator | Every test, plus 4 threads × 25,000 mints on a frozen clock: all unique, increasing per thread, gap-free. |
| A burst past 4,096 per ms borrows into the timestamp | 50,000 mints on a frozen clock. Mint *k* is exactly `(ts0 + k/4096, node, k % 4096)`. |
| A backward clock step keeps minting off the logical clock | The clock jumps back 5 s and the ids keep increasing. When the clock overtakes the logical clock again, the sequence resets to 0 at the new ms. |
| The node is masked to 10 bits and stamped into every id | `with_clock(0xFFFF, …)` gives node 1023 in every id. |
| A clock before the epoch still mints | The cell starts at 0. |

The clock is injectable. `Clock` is implemented for any `Fn() -> u64` that returns Unix
milliseconds, so the tests drive frozen, stepping and regressing clocks. `default_node()` is
`node_from(hostname, pid)`, with the hostname read the way Go's `os.Hostname` reads it on Linux
(`/proc/sys/kernel/hostname`). Reading the hostname allocates once; minting does not.

`Minter` is the contract's policy seam, a gate over a borrowed `Generator`. The gate sees the raw
namespace bytes first, and its error comes back unchanged as `MintError::Refused(e)`. An admitted
namespace still faces the codec's shape check, which reports `MintError::Invalid(Error)`.
`allow_all` is the explicit open gate.

## Tests

| Suite | What it proves |
|---|---|
| unit (`src/*.rs`) | Contract vectors, boundaries, precedence, error codes and `Display`, the readers and N-1. The memory core's digit/char bijection and its classifier over all 256 bytes. The generator and minter properties. |
| [`tests/vectors.rs`](../native/rust/crates/brd14/tests/vectors.rs) | Every row of `valid.tsv` (encode, decode, hash32, unix_ms, fields, min_for), `invalid.tsv`, `encode_invalid.tsv` and `node.tsv`, against both cores. It finds `vectors/` through `CARGO_MANIFEST_DIR`, or `BRD14_VECTORS_DIR` if set. It skips when the directory is absent and fails when it is absent with `BRD14_REQUIRE_VECTORS=1`. |
| [`tests/properties.rs`](../native/rust/crates/brd14/tests/properties.rs) | speed == memory == an independent reference, which uses u128 Horner sums, `position()` lookups and a numeric guard. Cases: all 256 byte values at every one of the 14 positions around four corner seeds; the 62-digit mapping at every payload place; 1,000,000 splitmix64 round trips with byte-equal encodes; 100,000 values ≥ 2^63 refused; the boundary set (62^k ± 1, the 62^6 split, the `(QA, RB)` corner, ±64 around the maximum); V-7 ordering; multi-fault precedence; decode on random noise; `node_from` against an allocating reference. |
| ffi, wasm, conform unit tests | ABI behaviour: null pointers, unaligned output, refusals write nothing, batch clamping and first-error stop, protocol lines. |

Loop counts shrink under `cfg(miri)`.

Parity at the time of writing, from `python3 tools/parity.py --only rust-`:

```
rust-speed       rust/speed           DEFHNU      30651         0  PASS
rust-memory      rust/memory          DEFHNU      30651         0  PASS
```

With `--scale 10`, 174,651 requests per shim pass with 0 mismatches.

## Hardening

`make harden` runs four targets:

- **`clippy`**: `rustfmt --check` on the workspace and the fuzz project, then
  `clippy -D warnings` on every configuration:
  - the workspace with `--all-targets`;
  - `brd14` with `std`, which includes the bench;
  - ffi and wasm with the memory core;
  - wasm on `wasm32-unknown-unknown`.
- **`alloc-check`**: the `nm -u` gate described under *Guarantees*.
- **`miri`** (nightly):
  - `brd14` with `-Zmiri-disable-isolation`, because the suites read `vectors/`, the wall clock and
    the hostname. Under Miri the vectors suite reads only the first 8 KiB of each file; Miri is
    there to find UB, and the native run reads every row.
  - `brd14-ffi` and `brd14-wasm` under `-Zmiri-strict-provenance`, for both cores. They are also
    clean under `-Zmiri-tree-borrows`.
- **`fuzz`** (nightly, libFuzzer with ASan, `FUZZ_SECONDS` per target, default 30, seeded from the
  corpus ids):
  - `decode_differential`: on arbitrary bytes, the speed core, the memory core and a u128 reference
    agree, and every accepted id re-encodes to the same bytes in both cores.
  - `encode_differential`: for any 3 bytes and any `u64`, both cores agree, the only refusals are
    `NAMESPACE` (exactly when the namespace is bad) and `RANGE` (exactly when the namespace is good
    and the value is ≥ 2^63), and every id decodes back.

  In one run of 36 s per target, `decode_differential` executed 23.1M inputs (cov 165) and
  `encode_differential` 22.4M (cov 78), with no findings.

## Benchmarks

`make bench` runs [`benches/codec.rs`](../native/rust/crates/brd14/benches/codec.rs)
(`harness = false`, std only), pinned with `taskset -c 2`, following [the protocol](../bench/README.md):

- the corpus is the first 4096 rows of `valid.tsv`, cycled in order;
- every result goes through `black_box`;
- a warm-up and calibration step makes each sample at least 50 ms;
- it takes 15 samples and reports the median, the MAD and the CV.

`bench_core` is generic over the core's functions, so each core is monomorphised and inlined as at
a real call site rather than called through a function pointer. Results go to
`bench/results/rust-{speed,memory}-rustc-1.99.0.json`, which is not committed.

The table below is **one run**, so treat it as indicative: rustc 1.99.0 on an
Intel Xeon @ 2.10 GHz, 4 vCPU, pinned, while other builds shared the machine. Several rows have a
CV above 5%. Their medians were stable from run to run, with MADs of 0.0–2.2 ns.

| op | speed ns/op | memory ns/op |
|---|---:|---:|
| encode | 5.68 | 16.70 |
| decode | 8.60 | 21.92 |
| hash32 | 0.80 | 0.68 |
| mint (wall-clock `Generator` + encode) | 47.6 | 51.6 |

`mint` is dominated by reading the wall clock (`SystemTime::now`) inside the VM. The CAS and the
encode add a few nanoseconds. Moving the speed core's range guard from a `memcmp` call to two
register compares took decode from 10.8 to 8.9 ns in an A/B pair, with hash32 as the noise
reference.
