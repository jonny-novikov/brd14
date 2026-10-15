---
id: "KAN0R9YJSzZO2k"
slug: "DOCS-PYTHON"
type: "guide"
version: "1.3"
path: "docs/python.md"
title: "brd14 — Python"
summary: "The pure-Python package on CPython 3.12 to 3.14t, with the free-threaded specifics."
tags: ["python", "cpython", "free-threaded"]
group: "implementations"
language: "en"
audience: ["developer", "agent"]
---

# brd14 — Python

The pure-Python implementation of the [contract](contract.md): standard library only, no native
extension, typed, and correct on the free-threaded CPython 3.14t build. The source is in
[`python/`](../python/), and the package README is [`python/README.md`](../python/README.md).

| | |
|---|---|
| Package | `brd14` (src layout, hatchling, `py3-none-any` wheel) |
| Python | ≥ 3.12. Tested on 3.12, 3.13, 3.14 and 3.14t (GIL disabled) |
| Dependencies | none at runtime. Dev: pytest, pyperf, mypy (in `make venv` venvs) |
| Typing | `py.typed`; `mypy --strict` clean over the package, tests, bench and shim |
| Variant | `pure`, in the [taxonomy](architecture.md#the-variant-taxonomy): no native code. The speed tricks are Python-level and chosen by measurement (see [below](#how-pure-python-gets-fast)) |

```
python/
├── src/brd14/
│   ├── __init__.py     public surface, __version__
│   ├── _codec.py       encode, decode, parse, is_valid, check, hash32, field and time readers, Branded
│   ├── _tables.py      generated literal tables (pair table, byte → digit); regenerates itself
│   ├── _generator.py   Generator, node_from, default_node
│   ├── _minter.py      Minter, Gate, allow_all, deny_all
│   └── _errors.py      ErrorCode, InvalidIdError, NamespaceRefusedError
├── tests/              pytest: vectors, contract, properties, generator, threads, minter, tables, shim
├── bench/bench.py      the bench protocol (pyperf, stdlib-timeit fallback)
├── bench/threads.py    multi-thread throughput (not part of the JSON protocol)
├── conform.py          the parity shim
└── Makefile            venv · test · bench · harden · threads · parity · conform · clean
```

[Index](index.md#toc) · [Contract](contract.md#toc) · [Structures](structures/README.md#toc) · [Parity](parity.md#toc) · [KAN story](kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [API](#api)
- [Error model](#error-model)
- [How pure Python gets fast](#pure-python-gets-fast)
- [Allocation profile](#allocation-profile)
- [CPython 3.14 vs 3.14t](#cpython-3-14-vs)
- [Benchmarks](#benchmarks)
- [Tests, parity, hardening](#tests-parity-hardening)
- [Future work: a native accelerator over native/rust](#future-work-native-accelerator)

<a id="api"></a>

## API

```python
import brd14
from datetime import UTC, datetime

brd14.encode("USR", 274557032793636864)      # 'USR0KHTOWnGLuC'
brd14.decode("USR0KHTOWnGLuC")               # ('USR', 274557032793636864)
brd14.decode(b"USR0KHTOWnGLuC")              # the same; any bytes-like input works
b = brd14.parse("USR0KHTOWnGLuC")            # Branded(ns='USR', snow=274557032793636864)
b.ts, b.node, b.seq, b.unix_ms, b.datetime   # fields, and the mint instant (UTC-aware)
str(b)                                       # 'USR0KHTOWnGLuC'
brd14.is_valid("USRzzzzzzzzzzz")             # False; never raises
brd14.check("usr0KHTOWnGLuC")                # <ErrorCode.NAMESPACE: 2>
brd14.hash32(274557032793636864)             # 234878118
brd14.min_for(datetime(2026, 1, 1, tzinfo=UTC))   # lower bound for a time-range scan

g = brd14.Generator(brd14.default_node())    # one per process; thread-safe
g.next()                                     # a bare snowflake
g.next_branded("USR")                        # mint and brand in one call
```

| Name | Signature | Notes |
|---|---|---|
| `encode` | `(ns: str, snow: int) -> str` | NAMESPACE before RANGE. Accepts any `__index__` integer; `TypeError` for a non-str namespace or a non-integer value |
| `decode` | `(id: str \| Buffer) -> tuple[str, int]` | Total: anything that is not an id raises `InvalidIdError`. `TypeError` only for a non-str, non-bytes-like object |
| `parse` | `(id) -> Branded` | `decode` returning a `NamedTuple` |
| `is_valid` | `(id: object) -> bool` | Never raises: `is_valid(None)` is `False` |
| `check` | `(id) -> ErrorCode` | `ErrorCode.OK`, or the class `decode` would raise |
| `hash32` | `(k: int) -> int` | MurmurHash3 `fmix64`, first half, truncated. `k` is reduced modulo 2⁶⁴, as the oracle does |
| `ts_of`, `node_of`, `seq_of` | `(snow) -> int` | `snow >> 22`, `(snow >> 12) & 1023`, `snow & 4095` |
| `unix_ms` | `(snow) -> int` | `(snow >> 22) + EPOCH_MS` |
| `to_datetime` | `(snow) -> datetime` | UTC-aware and exact: epoch plus a `timedelta`, no float |
| `min_for` | `(t: datetime \| int) -> int` | `(t_ms − EPOCH_MS) << 22`. Aware datetime or Unix ms. A naive datetime is a `ValueError`; sub-ms parts are floored |
| `node_from` | `(host: bytes \| str, pid: int) -> int` | FNV-32a over `host ++ str(pid)`, `& 1023`; a str host is hashed as UTF-8 |
| `default_node` | `() -> int` | `node_from(os.fsencode(socket.gethostname()), os.getpid())`, recomputed on each call |
| `Generator` | `(node: int, *, clock=None)` | `.next()`, `.next_branded(ns)`, `.node`, and the iterator protocol. `clock` returns Unix ms (tests, simulation). [Virtual clock](contract.md#virtual-clock-experimental): `.observe(snow, max_ahead_ms) -> bool`, the receive rule (`False` and no change when `snow` is too far ahead; `InvalidIdError` RANGE when `snow ≥ 2**63`); `.virtual_ms` |
| `Minter` | `(generator, gate: Gate \| None)` | `.mint(ns)`, `.mint_snowflake(ns) -> (id, snow)`, `.generator` |
| `Gate` | `Callable[[str], None]` | return `None` to admit, raise to refuse |
| `allow_all`, `deny_all` | gates | `deny_all` raises `NamespaceRefusedError` |
| `Branded` | `NamedTuple(ns, snow)` | properties `ts`, `node`, `seq`, `unix_ms`, `datetime`; `str()` gives the id |
| constants | `ALPHABET`, `EPOCH_MS`, `LEN`, `MAX_SNOW`, `NODE_MAX` | |

### Idioms

- **Sort ids as strings.** Byte order is numeric order (V-7). `sorted(ids)` gives mint order
  between milliseconds; within one millisecond the order is node, then sequence.
- **Scan a time range** with `min_for(start) <= snow < min_for(end)`, or compare ids against
  `encode(ns, min_for(t))`.
- **A Generator is an iterator.** `itertools.islice(g, 1000)` takes 1,000 snowflakes.
- **Bytes in, str out.** `decode(b"...")` returns a `str` namespace, so a value read off a socket
  and one read from JSON decode to equal tuples.
- **Fork.** A forked child inherits its parent's generator, cell and node, and would mint the
  parent's ids. Create generators after `os.fork()`. `default_node()` recomputes from the
  child's pid when called again.

### Where Python deliberately differs from the Go reference

| Behaviour | Go | Python | Why |
|---|---|---|---|
| node outside 0..1023 | masked | `ValueError` | a silently masked node aliases another node, which is a silent collision |
| `Decode` | returns the snowflake only | `decode` returns `(ns, snow)` (Go's `Parse`); `parse` returns a `Branded` | the API shape the task specified; a Python tuple is free to unpack |
| `Valid` on a non-string | n/a (typed) | `is_valid(obj)` is `False` for any non-id object | a predicate that never raises is easier to use at a boundary |
| gate returns a value | n/a | `TypeError` | a bool-returning policy would otherwise admit everything |
| copying a generator | possible | `TypeError` from `copy`, `deepcopy` and `pickle` | two copies of one cell mint duplicates |
| `MinFor` before the epoch | wraps (uint64) | negative, as the oracle has it | a negative lower bound is still a correct lower bound |

<a id="error-model"></a>

## Error model

```
ValueError
└── InvalidIdError        .code: ErrorCode, .detail: str   ← every contract refusal
Exception
└── NamespaceRefusedError .ns: str                         ← deny_all only; NOT a ValueError
TypeError                                                  ← wrong argument types (programming errors)
```

- `ErrorCode` is an `IntEnum` numbered as the C ABI numbers it: `OK=0 LENGTH=1 NAMESPACE=2
  CHARSET=3 RANGE=4`.
- Precedence is namespace-first. **encode** checks NAMESPACE, then RANGE. A namespace of any
  length other than 3 is NAMESPACE. **decode** checks LENGTH, NAMESPACE, CHARSET, then RANGE. A
  payload that is both off-alphabet and above the max is CHARSET.
- **str inputs are classified on their UTF-8 bytes,** with lone surrogates encoded by
  `surrogatepass`. So `"USR0KHTOWnGLuÉ"` (14 characters, 15 bytes) is LENGTH, `"USR0KHTOWnGLÉ"`
  (13 characters, 14 bytes) is CHARSET, and `"USR0KHTOWnG\ud800"` (11 + 3 bytes) is CHARSET.
  These are exactly the answers the bytes API gives on the encoded bytes. The parity shim checks
  this on every request.
- Messages name the class and the input, truncated to 40 characters of repr:
  `LENGTH: 'USR0KHTOWnGLu' is 13 bytes; a brd14 id is exactly 14`.
- Both exception classes pickle and unpickle with their attributes.
- **The gate's exception is returned verbatim.** `Minter.mint` calls the gate first, on the raw
  namespace. Whatever it raises propagates unchanged: the same object, with no `__cause__` and
  no `__context__` added. `test_gate_exception_is_the_same_object` pins this, and a refused mint
  never reads the clock. `deny_all`'s `NamespaceRefusedError` is deliberately neither an
  `InvalidIdError` nor a `ValueError`, so `except ValueError` cannot mistake a policy refusal for
  a malformed id.

<a id="pure-python-gets-fast"></a>

## How pure Python gets fast

One fact about CPython drives every choice here. An int below 2³⁰ is *compact*: it has one
internal digit, and the interpreter's fast paths handle it. Arithmetic on a wider int allocates a
multi-digit object at every step, and a 63-bit snowflake is a three-digit int. The other fact is
that `str.isascii`, `isalpha`, `isupper` and `isalnum` run in C, and the base62 alphabet is
**exactly ASCII alnum**. So once a string is known to be ASCII, `isalnum()` is the charset check.

**encode** splits the value at 62⁵ = 916,132,832, which is below 2³⁰, twice:
`snow = (d0·62⁵ + hi)·62⁵ + lo`. That leaves a leading digit `d0` and two 5-digit pieces, all
compact. Each piece becomes one alphabet character and two entries of a 3,844-entry pair table,
assembled in one f-string. The range guard is `snow >> 63`, which is nonzero exactly when
`snow ≥ 2⁶³` or `snow < 0`.

**decode** takes a `str` fast path: length 14, ASCII, then the C predicates, and the
lexicographic range guard `payload <= "AzL8n0Y58m7"`. It then maps the payload to digit values
with one `bytes.translate`, unpacks the 11 values, and folds them in an unrolled Horner chain.
The first five digits stay compact. Bytes inputs take the same path without the str layer.
Classification runs only after a failure, so the valid path never pays for diagnostics.

**is_valid** runs `isalnum()` over the whole string. It decides the range from the first payload
character: below `'A'` is always in range, above `'A'` never is, and only an `'A'` needs the
11-byte comparison.

Every alternative below was measured over the 4,096-row bench corpus. The candidates were
interleaved round-robin in one process pinned to CPU 2, and the table reports the minimum of 9
rounds in ns/op (2026-10-11, one machine, indicative):

| Operation | Candidate | 3.14 | 3.14t | |
|---|---|---:|---:|---|
| encode | **split at 62⁵ twice, `//` `%` on compact ints, pair table** | **451** | **605** | chosen |
| | split at 62⁶, pair table, `//` `%` | 490 | 654 | |
| | split at 62⁶, pair table, `divmod` | 536 | 766 | divmod's tuple costs more than two ops |
| | split at 62⁵, one digit per step (no pair table) | 562 | 763 | |
| | 11 unrolled `divmod(·, 62)` | 778 | 1023 | |
| | digit loop (`divmod` in a `for`) | 1159 | 1803 | 2.6–3.0× slower |
| decode (str) | **`encode().translate()` + unpack + unrolled Horner** | **619** | **790** | chosen |
| | same, indexing the translated bytes | 629 | 836 | |
| | dict lookup per char, unrolled | 704 | 890 | |
| | 2-char slices into a 3,844-entry dict | 725 | 1030 | slices allocate |
| | dict lookup per char, loop | 896 | 1165 | 1.4–1.5× slower |
| decode (bytes) | **`translate` + unpack + unrolled Horner** | **540** | **770** | chosen |
| | dict loop | 798 | 1121 | |
| valid (str) | **whole-string `isalnum` + first-char range** | **187** | **181** | chosen |
| | slices for ns and payload | 247 | 286 | |
| hash32 | mask to u64 first (total, matches the oracle) | 199 | 332 | chosen, 4–9% over no mask |

<a id="allocation-profile"></a>

## Allocation profile

The contract's zero-allocation rule is a Go and native concern. In Python, every call allocates
its result, and the question is what else it allocates. The answer is short-lived compact ints
from the arithmetic, which are freed at once, and nothing that outlives the call except the
result. *Retained blocks per call* below is `sys.getallocatedblocks()` growth while every result
is kept alive. It equals the number of objects in the result:

| Call | Result | `sys.getsizeof` 3.14 | 3.14t | Retained blocks / call | Temporaries |
|---|---|---:|---:|---:|---|
| `encode(ns, snow)` | `str` (14 ASCII) | 55 | 71 | 1 | ~4 ints; table entries and digits are shared, not copied |
| `decode(str)` | `tuple(str, int)` | 64 + 44 + 32 | 64 + 60 + 48 | 3 | 1 payload slice, 1 bytes, 1 translated bytes, ints |
| `decode(bytes)` | `tuple(str, int)` | same | same | 3 | 2 slices, 1 translated bytes, ints |
| `parse(id)` | `Branded` | same | same | 3 | as `decode` |
| `is_valid(str)` | `bool` singleton | — | — | 0 | 1–2 slices |
| `check(id)` | `ErrorCode` member | — | — | 0 | as `is_valid`; bytes on failure |
| `hash32(k)` | `int` | 28–32 | 44–48 | 1 | ~4 ints |
| `Generator.next()` | `int` | 32 | 48 | 1 | ~5 ints |
| `Generator.next_branded(ns)` | `str` | 55 | 71 | 1 | `next()` + `encode()` |

The free-threaded build's object header is 16 bytes larger: it carries the owning thread id and
split local/shared reference counts. That accounts for the 3.14t column.

**Resident tables:** the pair table is a 30.8 KB tuple of 3,844 two-character strings. With its
strings it is about 196 KB on 3.14 and 258 KB on 3.14t. The byte → digit table is 289 B. The C
speed tier carries 7.7 KB for the same job, because a Python `str` costs 43–59 bytes for two
characters. That trade buys the 2.6× encode speed-up above. `ALPHABET` and the one-character
digits are interpreter-cached and cost nothing extra.

<a id="cpython-3-14-vs"></a>

## CPython 3.14 vs 3.14t

### Single thread

The free-threaded build pays for its thread-safety even with one thread: biased reference
counting, larger headers, and per-object locks inside some builtins. The table below gives the
minimum of four alternating rounds of `bench.py --timeit`, run on 3.14, 3.14t and 3.12 in turn so
that all three share one time window:

| op | 3.14 | 3.14t | 3.12 | 3.14t / 3.14 |
|---|---:|---:|---:|---:|
| encode | 473 | 642 | 481 | 1.36 |
| decode | 709 | 827 | 774 | 1.17 |
| decode_bytes | 603 | 843 | 713 | 1.40 |
| hash32 | 239 | 344 | 240 | 1.44 |
| valid | 217 | 211 | 243 | 0.97 |
| next | 422 | 549 | 697 | 1.30 |
| mint | 946 | 1224 | 1169 | 1.29 |

Big-int arithmetic and allocation cost 17–44% more on 3.14t. `valid`, which only runs C string
predicates and allocates nothing that survives, is at parity. 3.14 beats 3.12 most clearly on
`next`, largely through the lock: an uncontended `with lock: pass` measured 147 ns on 3.12, 96 ns
on 3.13 and 65 ns on 3.14.

### Why the generator holds a `threading.Lock`

The contract's generator advances one cell to `max(now, last + 1)`. Python has no CAS, so the
contract's "a lock where the runtime has no CAS" applies. The clock is read outside the lock. A
thread that read an older `now` and wins the lock later still gets `last + 1`, so the stream is
strictly increasing in lock order. That is the same argument as Go's CAS loop.

The lock is load-bearing, and the GIL hides that. The experiment below copied the generator
without its lock and ran it on 8 threads × 50,000 mints:

| Build | Duplicates per 400,000 mints (3 runs) |
|---|---|
| 3.14t, GIL disabled | **186,834 · 223,248 · 260,064** |
| 3.14, GIL enabled (switch interval 5 ms) | 0 · 0 · 0 |
| 3.14, GIL enabled (switch interval 1 µs) | 0 · 0 · 0 |

Under the GIL, the read-modify-write happens never to be interrupted, because no eval-breaker
check falls inside it. That is an accident of bytecode layout, not a guarantee. On 3.14t, half
the ids were duplicates. `tests/test_threads.py` runs the same workload (8 × 50k on one shared
generator) through the real `Generator`. It asserts that every id is unique and every thread's
stream strictly increases. A frozen-clock variant asserts that exactly *N* consecutive cell
values were handed out, so nothing was lost or repeated. On a free-threaded build,
`test_gil_is_disabled` asserts `sys._is_gil_enabled() is False`, because a GIL-on run would
prove nothing. `make test` and `make harden` run 3.14t with `PYTHON_GIL=0 -X gil=0`, and
`harden` repeats the stress tests five times under `-X dev -W error`.

### Contention behaviour

`bench/threads.py` releases N threads together with a barrier. Each thread performs 100,000
operations, and the table reports the best of 3 runs as aggregate millions of ops/s and the ratio
to one thread. The machine has 4 vCPUs, so 8 threads oversubscribe it, and the run was unpinned:

| workload | build | 1 thread | 2 threads | 4 threads | 8 threads |
|---|---|---:|---:|---:|---:|
| `encode()` (no shared mutable state) | 3.14 | 2.03 | 1.71 (×0.8) | 1.85 (×0.9) | 1.74 (×0.9) |
| | **3.14t** | 1.58 | **3.11 (×2.0)** | **5.26 (×3.3)** | 4.48 (×2.8) |
| private `next()` (one generator per thread) | 3.14 | 2.01 | 2.22 (×1.1) | 2.00 (×1.0) | 2.01 (×1.0) |
| | **3.14t** | 1.63 | 2.05 (×1.3) | **3.51 (×2.2)** | **4.40 (×2.7)** |
| shared `next()` (one generator, contended lock) | 3.14 | 2.31 | 2.24 (×1.0) | 2.06 (×0.9) | 2.18 (×0.9) |
| | 3.14t | 1.51 | 1.07 (×0.7) | 0.46 (×0.3) | 0.76 (×0.5) |
| shared `next_branded()` | 3.14 | 1.06 | 1.02 (×1.0) | 0.96 (×0.9) | 0.90 (×0.9) |
| | 3.14t | 0.72 | 0.50 (×0.7) | 0.33 (×0.5) | 0.42 (×0.6) |

What this means:

- With the GIL, nothing scales, and nothing degrades either. The GIL serializes the threads in
  5 ms slices, so the generator's lock is never contended.
- On 3.14t, the codec scales with cores. `encode` reached 3.3× on 4 threads.
- **On 3.14t a single shared generator is a serialization point, and under heavy contention it is
  slower than one thread.** The critical section is a few integer operations, so the cost is the
  lock handoff. A contended `PyMutex` spins briefly, then parks the thread in the kernel. This is
  the price of the contract's strict monotonicity per generator. Uncontended use (one minting
  thread, or mints interleaved with real work) does not pay it.
- If many threads mint in a tight loop, give each thread its own `Generator` with its **own
  node**. That is the "private" row, and it scales. Two generators with the same node in one
  process would mint duplicates, so a per-thread design spends node ids, a 10-bit budget shared
  with every other process.

### Shared tables and reference counts

Under free-threading, every read of a *mortal* object that another thread owns updates that
object's shared reference count atomically. A lookup table in a module global is read by every
encoding thread, so its reference count becomes a contended cache line. Measured on 3.14t with
encode-only threads:

| encode tables | 1 thread | 2 threads | 4 threads |
|---|---:|---:|---:|
| tuples built at import (mortal) | ×1.00 | ×0.67 | **×0.64**, slower than one thread |
| literal tables (immortal) | ×1.00 | ×1.35 | ×1.58 |
| `brd14.encode` as shipped (literal tables, plus argument checks) | ×1.00 | ×1.55 | ×1.75 |
| locals-only control loop, same run | ×1.00 | ×2.27 | ×2.83 |

Immortal objects never have their reference count written. On 3.14t, interned strings are
immortal, and so are the constants of code objects loaded from a `.pyc`. Observed on 3.14.8t,
the constants of a module's *first* import, which compiles it from source through `compile()`,
are not. Every later import reads the `.pyc`. So the pair table and the
byte → digit table live as **literals** in a generated module, [`_tables.py`](../python/src/brd14/_tables.py),
which regenerates itself with `python -m brd14._tables`. Single digits come from the `ALPHABET`
literal, which is interned and yields cached one-character strings. `tests/test_tables.py` checks
that the literals equal the computed tables, that regeneration is a fixpoint, and, on 3.14t,
that the tables are immortal when loaded from a `.pyc`. An installed wheel is byte-compiled at
install time, so this is the normal case. GIL builds are unaffected.

### Free-threading hygiene

- The wheel is `py3-none-any`, and the package imports no extension module, so nothing can
  re-enable the GIL on import. The pyproject classifier is
  `Programming Language :: Python :: Free Threading :: 3 - Stable`.
- Mutable state lives in exactly one place, the generator's cell, which only its lock touches.
  Everything else is immutable: `str`, `bytes`, tuples, ints and enums.
- `bench.py` refuses to run on a free-threaded interpreter whose GIL is enabled. It forwards
  `-X gil=0` to pyperf's worker processes, and pyperf passes `PYTHON_GIL` through, so a 3.14t
  number cannot silently be a GIL number.

<a id="benchmarks"></a>

## Benchmarks

`make bench` runs `bench/bench.py` under pyperf on 3.14 and 3.14t (and 3.12 with
`BENCH_VERSIONS="3.14 3.14t 3.12"`). It follows [bench/README.md](../bench/README.md): the first
4,096 rows of `vectors/valid.tsv`, cycled in order inside the timed loop, every result reaching a
sink. pyperf launches fresh worker processes, which calibrate, warm up, and are pinned with
`--affinity=2`. The JSON goes to `bench/results/python-pure-cpython-<version>[t].json` with the
median `ns_per_op`, `mad_ns`, `samples` and `cv`. Without pyperf, `--timeit` produces the same
schema with the stdlib.

**Single run, 2026-10-11, Intel Xeon @ 2.10 GHz (4 vCPU, shared with other builds), pinned to CPU
2, pyperf 2.10.0 defaults (20 processes × 3 values = 60 samples). Median ns/op ± MAD (CV):**

| op | cpython-3.14.8 | cpython-3.14.8t | cpython-3.12.3 |
|---|---:|---:|---:|
| encode | 468 ± 17 (10%) | 657 ± 32 (12%) | 598 ± 50 (17%) |
| decode | 677 ± 19 (9%) | 834 ± 21 (14%) | 779 ± 30 (13%) |
| hash32 | 256 ± 23 (17%) | 332 ± 21 (15%) | 250 ± 17 (15%) |
| mint | 951 ± 38 (11%) | 1232 ± 32 (8%) | 1161 ± 58 (13%) |
| valid | 211 ± 7 (16%) | 203 ± 9 (17%) | 239 ± 11 (12%) |
| decode_bytes | 630 ± 23 (12%) | 872 ± 56 (12%) | 713 ± 31 (11%) |
| next | 430 ± 25 (14%) | 569 ± 20 (11%) | 515 ± 16 (15%) |

Read these as indicative. Every CV is above the protocol's 5% threshold, because the VM's speed
drifted by up to 2× during the session. In two earlier runs, `decode` and `hash32` on 3.14 came
out at twice these values. That was traced to something else sharing pinned CPU 2 during that
window, and it did not reproduce. The times include the benchmark loop's own iteration: 7–10 ns
on 3.14 and 10–17 ns on 3.14t. `decode_bytes` and `next` are variant-specific extras. For the
3.14 vs 3.14t comparison, prefer the alternating table above.

<a id="tests-parity-hardening"></a>

## Tests, parity, hardening

| Command | What it proves |
|---|---|
| `make test` | pytest on every venv: **96 passed, 2 skipped** on 3.12, 3.13 and 3.14 (the skips are the free-threaded-only tests); **98 passed** on 3.14t with the GIL off |
| `make harden` | 3.14t: the full suite under `-X dev -W error`, then the stress tests ×5. 3.14: the full suite under `-X dev -W error`. Then `mypy --strict` |
| `python3 tools/parity.py --only python` | the shim on 3.14, 3.14t and 3.12, each **PASS with 0 mismatches** over 30,651 requests (78,651 at `--scale 4`) |

- **Vectors.** All four TSVs, through both the str and the bytes API. The suite skips when
  `vectors/` is absent and fails when `BRD14_REQUIRE_VECTORS=1`. Both behaviours are tested.
- **Properties,** with seeded `random`. Round-trip; byte order equals numeric order; and
  totality over random bytes and random str (Latin-1, BMP, astral, lone surrogates), compared
  against a reference model read literally from the contract. Only `InvalidIdError` ever
  escapes, and `decode`, `check` and `is_valid` always agree.
- **Generator,** on a fake clock: a frozen millisecond borrows into ts after seq 4095, and a
  one-minute backward step keeps minting. Plus layout, node bounds, iteration, copy and pickle
  refusal, and 2⁶³ overflow giving RANGE.
- **Shim.** [`python/conform.py`](../python/conform.py) prints `HELLO python pure EDHUFN`, reads
  all of stdin, and writes once. It also cross-checks the library against itself. Every `D`
  request runs through `decode`, `check`, `is_valid` and `parse` on bytes, on a bytearray, and
  (when the bytes are valid UTF-8 under `surrogatepass`) on a str, whose fast path is separate
  code. Any disagreement answers `ERR DISAGREE`, which cannot match the oracle. So parity covers
  every public path, not just one.

<a id="future-work-native-accelerator"></a>

## Future work: a native accelerator over `native/rust`

The Operator chose pure Python, and nothing below is implemented. The path to native speed,
if it is ever wanted:

- A `brd14-py` crate in `native/rust/crates/`, built with **PyO3** and **maturin** over the
  existing `no_std` core, so it adds no second implementation of the algorithm. Expose
  `encode`, `decode`, `is_valid`, `check` and `hash32`. Keep the generator in Python, or move the
  cell to an `AtomicI64` CAS, which removes the lock contention measured above.
- Declare free-threading support with `#[pymodule(gil_used = false)]`. Otherwise importing the
  extension on 3.14t re-enables the GIL, which `test_gil_is_disabled` would catch. Build one
  wheel per platform and ABI: `abi3` wheels do not cover free-threaded builds, so 3.14t needs its
  own `cp314t` wheels.
- Ship it as an optional accelerator, e.g. `pip install brd14[native]`, with the pure package as
  the fallback (`try: from brd14_native import … except ImportError: …`). The public API, the
  error classes and precedence stay identical. `InvalidIdError` would be raised from Rust with
  the same `.code`.
- Register a `python-native` shim in `tools/parity.py`, so the oracle holds the accelerator to
  the same bytes, and add its rows to the bench table.

Expect the per-call floor to be CPython's own call and object-creation overhead: tens of ns for a
call plus the result `str` or tuple. The codec's own work would no longer be visible next to it.
