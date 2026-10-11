---
id: "KAN0R9TiVLe94q"
slug: "DOCS-KAN-BRD14-PRAGMATIC-GUIDE"
type: "aus"
version: "1.3"
path: "docs/kan/brd14-pragmatic-guide.md"
title: "brd14, pragmatically: metadata in the id and structures that use the id"
summary: "The brd14 pragmatic programmer's guide as one KAN story: in-band layout profiles, branded CHAMP/Tree/Buckets in Go, Rust and Elixir, the Rustler NIF, and echo_data at home in ex/."
tags: ["KAN", "AUS", "brd14", "structures", "layout-profiles", "echo_data"]
group: "brd14"
language: "en"
audience: ["Operator", "developer", "agent"]
---

# brd14, pragmatically

**One story, read two ways.** A programmer reads it as a guide: what a brd14 id already knows, and
which structure turns that knowledge into speed. An agent reads it as the delivery contract: the
boundaries, the distinguishing examples, and the checks that must pass before the Operator is asked
to accept.

[Contract](../contract.md) · [Structures](../structures.md) · [Elixir](../elixir.md) ·
[Parity](../parity.md) · [How agents work here](../../CLAUDE.md) · [Where things are](../../AGENTS.md)

<a id="toc"></a>

## In this document

- [6W: what this delivers, to whom](#six-w)
- [Rumsfeld: what we know and what we don't](#rumsfeld)
- [The guide: what the id knows, and how to use it](#guide)
- [The story: user and agent](#story)
- [SDMR: the consequential decisions](#sdmr)
- [Rungs: how it is delivered](#rungs)
- [Acceptance and evidence](#acceptance)

<a id="six-w"></a>

## 6W: what this delivers, to whom

| 6W | This story |
|---|---|
| **What** | Four additions to brd14:<br>1. **In-band layout profiles.** Custom metadata in the 22 low bits, chosen per namespace; ids stay valid 14-byte brd14.<br>2. **Branded structures** that use what the id already carries — `BrandedChamp`, `BrandedTree`, time `Buckets` — in **Go, Rust and Elixir**.<br>3. **A Rustler NIF** that puts the Rust champ and codec under Elixir.<br>4. **`echo_data` at home in `ex/`.** Isolated from the umbrella, hardened, redistributable, and proven by the parity run like every other implementation. |
| **Why** | **A brd14 id is not an opaque key.** Its namespace is a partition, its byte order is mint order, its high bits are a timestamp, and `hash32` is a contract function. Generic maps and sorted lists throw all four away and pay to rebuild them.<br>**The ex-umbrella code had no outside proof.** `echo_data` (fiberfx `kan`, `24a4083`) already had these structures in Elixir, but in an umbrella pinned to Elixir 1.18 and with no parity proof against the oracle.<br>**The id had no room for metadata.** An audit flag or a tenant shard had nowhere to go without a format change; layout profiles give it room inside the existing format.<br>**The earlier article was withdrawn.** This story replaces it with something that ships code. |
| **Who** | **Requester and acceptance owner:** the Operator. **Users:**<br>- programmers on the BCS stack: Elixir/Phoenix with EchoMQ and EchoCache, Go runtimes, Rust NIFs;<br>- agents that extend brd14.<br>**Executor:** the coordinating agent, with sub-agents owning disjoint directories. |
| **Where** | **Normative:**<br>- [docs/contract.md](../contract.md) § Extensions;<br>- [docs/structures.md](../structures.md).<br>**Oracles:** `tools/oracle.py`, `tools/champ_oracle.py`. **Vectors:** `vectors/layout.tsv`, `vectors/champ.tsv`. **Code:**<br>- `go/` (`layout.go`, `brdata/`);<br>- `native/rust/crates/{brd14,brd14-data}`;<br>- `ex/echo_data` (including `native/echo_data_nif`).<br>**Branch:** `claude/data-structures`. |
| **When** | Rungs R0–R6 in the order [below](#rungs). Each rung is pushed when its checks pass, so a ready increment never waits for the next. Each rung is a checkpoint: what was done, what is next, the value served. |
| **Value** | **A programmer gets:**<br>- a map that keeps snapshots cheap and namespaces apart;<br>- a feed ordered by creation time without a sort;<br>- expiry that never touches an entry;<br>- a few bits of metadata that ride inside the id — same API shape in three runtimes, proven equivalent rather than assumed.<br>**An agent gets** one contract, oracles and vectors that settle every disagreement. |

<a id="rumsfeld"></a>

## Rumsfeld: what we know and what we don't

| | |
|---|---|
| **Known knowns** | **The brd14 contract** and its 13-shim parity run (0 mismatches).<br>**The `ChampNode` algorithm:**<br>- fragments are LSB-first 5-bit slices of `hash32`;<br>- `max_level` 7, then collision nodes;<br>- deletes collapse into canonical form.<br>**`echo_data` on Elixir 1.14 / OTP 25:** it compiles with `--warnings-as-errors` and passes its suite (105 tests, 5 properties) once isolated.<br>**The parity protocol** already lets a shim advertise a subset of ops. |
| **Known unknowns** | - Does Rustler 0.38 load cleanly on OTP 25 (NIF 2.16)?<br>- Does a NIF champ win any point operation against the in-heap `ChampNode`, or only sharing and GC? R6 measures it.<br>- How do the Go and Rust structures compare with `map[string]V`, `HashMap`, `BTreeMap`?<br>- Do 3-way `hash32` collisions reproduce the prepend order identically in every language? Vectors include them. |
| **Unknown knowns** | Answered by reading, not guessing:<br>- `EchoData.Namespace` already separates the 3-letter platform space from the 4-letter developer space;<br>- `test/brd14_contract_test.exs` already pins vectors V-1..V-7;<br>- the Rust `brd14` crate already exports `hash32`, `fields`, `node_from`;<br>- the Go floor is 1.22, so no `iter` import. |
| **Unknown unknowns** | Contained by:<br>- small rungs pushed one at a time;<br>- vectors before implementations;<br>- an oracle independent of every implementation;<br>- each structure tested against a plain-map model on random operation streams, not only on vectors. |

<a id="guide"></a>

## The guide: what the id knows, and how to use it

```
USR0KHTOWnGLuC        bytes compare in mint order (same namespace)
└┬┘└─────┬────┘
 │       └─ base62( ts(41) | node | seq | meta )   ← the 22 low bits are a layout profile
 └───────── namespace: the partition, the type, the policy key
```

### Four facts, four structures

| The id already knows… | So don't… | Use | Cost |
|---|---|---|---|
| its **namespace** | build one map and filter by prefix | any branded structure: one trie or tree **per namespace**; `namespace_size` is O(1) | per-namespace ops never touch other namespaces |
| its **hash** (`hash32`, a contract function) | hash a 14-byte string again | **`BrandedChamp`** — a CHAMP trie routed by `hash32(snowflake)` | O(log₃₂ n) get/put; a put copies one path, so snapshots are free |
| its **mint order** (byte order = time order) | sort to page | **`BrandedTree`** — ordered by snowflake per namespace | `first`, `last`, `page_after(cursor)`, `between(t0, t1)` without a sort |
| its **mint time** (high 41 bits) | store an `expires_at` per entry | **`Buckets`** — bucket = `snowflake >> (22 + bits)` | expiry drops whole buckets: O(buckets), no entry touched |

**The default is still the plain map.** On the BEAM, `BrandedMap` (one native HAMT per
namespace) wins the general case. Reach for the champ when you need one of these:
- the trie's placement shared with Go or Rust;
- structural snapshots you can diff;
- with the NIF, a large index held off-heap and passed between processes by reference.

### Metadata in the id: layout profiles

The 22 bits under the timestamp are `node | seq` by default. A **layout profile** re-splits them as
`node(n) | seq(s) | meta(m)` with `n + s + m = 22`:

| Profile | n · s · m | Means | Per-node budget (formula) |
|---|---|---|---|
| `std` | 10 · 12 · 0 | today's ids, bit-identical | 1024 nodes × 4096 ids/ms |
| `audit` | 6 · 12 · 4 | 64 nodes, 4 flag bits (deleted, redacted, …) | 64 nodes × 4096 ids/ms |
| `shard` | 8 · 10 · 4 | 256 nodes, 16 tenant shards | 256 nodes × 1024 ids/ms |

**The meta field sits lowest, below the sequence.** That keeps a generator strictly increasing
whatever metadata each id carries: the generator advances the `ts | seq` cell exactly as it does
today. The id stays 14 bytes, sorts the same, and parses with every existing implementation. Only a
reader that knows the namespace's profile can split out `meta`.

**A namespace's profile is fixed once ids exist.** Treat it like the census: additive and never
rewritten. Bind it where the namespace policy already lives: Go `Gate`, Elixir
`EchoData.Namespace`, the CLI `census`.

```go
ord := brd14.MustLayout(6, 12, 4)              // the ORD namespace's profile
snow, _ := ord.Pack(ts, node, seq, flagDeleted) // or a profiled Generator
_, _, _, meta := ord.Fields(snow)               // meta == flagDeleted
```

### Choosing in three runtimes

| Need | Go (`go/brdata`) | Rust (`brd14-data`) | Elixir (`echo_data`) |
|---|---|---|---|
| default map | `map[uint64]V` per namespace | `HashMap<u64, V>` per namespace | `EchoData.BrandedMap` |
| persistent, shape-shared | `brdata.Champ[V]` | `brd14_data::Champ<V>` | `EchoData.BrandedChamp` / `EchoData.NativeChamp` |
| creation-ordered | `brdata.Tree[V]` | `brd14_data::Tree<V>` | `EchoData.BrandedTree` |
| expiry by age | `brdata.Buckets[V]` | `brd14_data::Buckets<V>` | `EchoData.Buckets` |

The three champs are **shape-identical**: the same operations in the same order build the same
trie, so the same digest and the same iteration order. Tree and Buckets agree on **behaviour**
(order, pages, expiry counts), not on internal shape.

<a id="story"></a>

## The story: user and agent

**Problem:** the id carries a partition, an order, a time and a hash. Every structure that ignores
them pays to rebuild them, and nothing cross-language proves the three runtimes agree.
**Value:** structures and profiles that use the id directly, with equivalence proven by oracle and
vectors.
**Sources:**
- [contract](../contract.md);
- the upstream `echo_data` (fiberfx `kan` @ `24a4083`, path `echo/apps/echo_data`);
- Operator rulings of 2026-10-11:
  - "In-band layout profiles";
  - "Rustler over the Rust champ";
  - "BrandedChamp, BrandedTree, Time buckets in Go, Rust and Elixir";
  - "harden echo_data isolating from umbrella and adding to brd14 repo ex/ folder";
  - "isolated copy you bring in target repo acceptable to run on 1.14".

**Profile:** change.
**Boundaries:** this repository, branch `claude/data-structures`.
- The 14-byte format, the epoch and the existing codec behaviour are unchanged.
- Runtimes outside Go, Rust and Elixir are deferred.
- Never push `master` and never tag.

**Acceptance:**
- every criterion below holds with recorded evidence;
- parity requires every shim;
- the Operator accepts.

### User (programmer)

As a programmer on the BCS stack, I want structures and id layouts that use what a brd14 id already
carries, so that ordering, partitioning and expiry cost nothing extra and behave the same in Go,
Rust and Elixir.

- **Criterion U1.**
  - **Given** an operation stream from `vectors/champ.tsv`;
  - **when** it is applied to the Go, Rust and Elixir champs (pure and NIF);
  - **then** each yields the vector's digest, size and iteration order.
- **Criterion U2.**
  - **Given** ids of namespace `ORD`;
  - **when** a `Tree` is paged after a cursor or windowed by time;
  - **then** entries come in mint order without a sort.
  - Separately, a `Buckets` expiry removes exactly the entries in buckets wholly older than the
    cutoff's bucket, and reports their count.
- **Criterion U3.**
  - **Given** profile `6·12·4`;
  - **when** a generator mints with any sequence of meta values;
  - **then** the ids are strictly increasing, valid brd14, and `Fields` returns each meta value.
- **Bad input:**
  - a profile whose widths do not sum to 22 is refused (`LAYOUT`);
  - a field wider than its width is refused (`RANGE`);
  - an invalid id given to a branded structure's write is refused loudly, never stored.

### Agent

As an agent extending brd14, I want one contract, an independent oracle and generated vectors for
every new operation, so that I can prove an implementation right without trusting another
implementation.

- **Criterion A1.**
  - **Given** the contract's Extensions section;
  - **when** `make vectors` runs;
  - **then** `vectors/layout.tsv` and `vectors/champ.tsv` regenerate with no drift.
- **Criterion A2.**
  - **Given** a shim that advertises `L` and `P`;
  - **when** `tools/parity.py --require` runs;
  - **then** it agrees with the oracle on every request.
  - A shim that does not advertise them is listed as deferred, never as passing.
- **Criterion A3.**
  - **Given** `ex/echo_data`;
  - **when** it is built standalone on Elixir 1.14 / OTP 25, or from its unpacked Hex tarball;
  - **then** it compiles with warnings as errors, its suite passes, and shims `ex-pure` and
    `ex-nif` pass parity.
- **Bad input:**
  - a mutant oracle (`parity.py --self-test`) is caught;
  - a champ whose collision list is appended instead of prepended fails the collision vectors.

**Route:** [CLAUDE.md](../../CLAUDE.md) → this story → [contract](../contract.md) §
Extensions → [structures](../structures.md) → the tree's `Makefile`.
**Command:** `make test && python3 tools/parity.py --require`.

<a id="sdmr"></a>

## SDMR: the consequential decisions

Each card gives the question, the strongest case for change (**Steelman**), the strongest case for
what exists (**Steward**), the options, the decision with confidence, and the check that would
refute it.

### 1. Where the metadata bits go

- **Question:** where in the 22 low bits does `meta` sit?
- **Steelman:** putting it between node and seq (`node | meta | seq`) groups by meta inside a
  millisecond, which range scans by flag could use.
- **Steward:** strict monotonicity of one generator is a guarantee callers rely on: cursors, Graft
  commit order, newer-wins coherence. With meta above seq, an id with meta 5 then one with meta 1
  in the same millisecond go *backwards*.

| Option | Weakest point |
|---|---|
| `node \| seq \| meta` (meta lowest) | flags do not cluster within a millisecond |
| `node \| meta \| seq` | breaks per-generator monotonicity whenever meta varies |
| meta in the namespace (brd15/16) | changes the length and every parser; out of scope |

**Decision:** meta lowest, confidence 90%. The `std` profile (10·12·0) is bit-identical, so
existing ids are untouched.

**Falsifying check:** mint 10 000 ids under `6·12·4` with meta drawn at random; any non-increasing
pair refutes it. This is a test in Go, Rust and Elixir.

### 2. Who defines the champ's shape

- **Question:** which implementation is the reference for CHAMP shape?
- **Steelman:** `EchoData.ChampNode` exists, is tested, and is what production runs. Make it the
  reference and port from it.
- **Steward:** this repository's law is that implementations never judge each other; an independent
  oracle does. A port that copies a bug agrees with it.

| Option | Weakest point |
|---|---|
| Python `tools/champ_oracle.py` mirrors `ChampNode` by its specification; vectors carry shape digests | one more oracle to maintain |
| Elixir as the reference, others compared against it | a shared bug is invisible |

**Decision:** an independent Python oracle written from `docs/structures.md`, confidence 85%.
`ChampNode` must pass the same vectors, which tests it too.

**Falsifying check:** an oracle that appends collision pairs instead of prepending them must fail
the explicit collision vectors.

### 3. Persistence of Tree and Buckets outside the BEAM

- **Question:** must Go and Rust Tree and Buckets be persistent like the Elixir ones?
- **Steelman:** identical semantics everywhere is simpler to teach.
- **Steward:** persistence is the BEAM's nature, not these structures' purpose. Their purpose is
  order and expiry. Persistent ordered trees in Go and Rust cost path-copying allocation on every
  write. Idiomatic mutable trees with an explicit `Clone()` serve the same users better.

**Decision:**
- the champ is persistent everywhere: its purpose is snapshots and structural sharing;
- Tree and Buckets are mutable in Go and Rust, each with `Clone()`;
- confidence 80%.

**Falsifying check:** a Go or Rust user who needs a Tree snapshot under concurrent writes and
cannot get one at a bounded cost reopens this decision.

### 4. One NIF, built with Rustler

- **Question:** how does Elixir reach the Rust champ and codec?
- **Steelman:** keep the existing C shim (`echo_native.c`). It is small and works.
- **Steward:** the C shim links a *vendored copy* of a Rust core, a second source of truth. Rustler
  gives typed resources, panics that become exceptions rather than VM aborts, and dirty
  schedulers.

**Decision:**
- one crate, `ex/echo_data/native/echo_data_nif`, built with rustler 0.38 in its own workspace
  (`panic = "unwind"`);
- the codec comes from the repository's `brd14` crate and the champ from `brd14-data`;
- values are stored as `term_to_binary`;
- `put` returns a new resource and leaves the old one valid (value semantics);
- confidence 75%.

**Falsifying check:** a NIF whose iteration order differs from `ChampNode` on any vector, or a
pure fallback that breaks when the `.so` is absent.

### 5. A redistributable package that depends on in-repo crates

- **Question:** the NIF depends on crates in `native/rust/`. How does a Hex tarball build?
- **Steelman:** publish the crates to crates.io.
- **Steward:** publishing is the Operator's call and outside this story.

**Decision:** `make -C ex/echo_data package` copies the two crates into `native/vendor/` and
rewrites the path dependencies. Confidence 80%.

**Falsifying check:** `mix hex.build --unpack`, then build and test inside the unpacked directory,
with the repository's crates out of reach.

### 6. echo_data's node derivation

- **Question:** must `EchoData.Snowflake` derive its node by the contract (FNV over host and pid)?
- **Steelman:** one derivation everywhere.
- **Steward:** existing echo consumers start with `phash2(node())`. Changing a running fleet's node
  numbers mid-flight risks same-millisecond collisions between old and new processes.

**Decision:** keep the default, and add `Snowflake.node_from/2` per the contract (shim op `N`). The
contract's derivation is opt-in. Confidence 85%.

**Falsifying check:** `node_from("hosta", 100)` ≠ 585 (vector N-1).

<a id="rungs"></a>

## Rungs: how it is delivered

| Rung | FIB | Timebox | Delivers | Falsifying check |
|---|---:|---|---|---|
| R0 | 2 | 15 min | Restore the CLI files master dropped; branch `claude/data-structures` | burst test without `BRD_FAKE_NOW_MS` fails |
| R1 | 3 | 30 min | This story; `CLAUDE.md`/`AGENTS.md` adopt KAN | a link or anchor that does not resolve |
| R2 | 5 | 60 min | `ex/echo_data`: verbatim import, isolation on 1.14, hardening, shim `ex-pure` | a fresh checkout without `priv/census.vectors` fails |
| R3 | 5 | 45 min | Layout profiles: contract, oracle, `vectors/layout.tsv`, Go/Rust/Elixir, ops `L`/`P` | a backwards pair under a profile with varying meta |
| R4 | 8 | 2 h | `docs/structures.md`, `tools/champ_oracle.py`, `vectors/champ.tsv`, `go/brdata`, `brd14-data`, Elixir proofs | append-instead-of-prepend collision mutant |
| R5 | 5 | 90 min | Rustler NIF (codec + champ), `NativeChamp`, shim `ex-nif`, `make package` | unpacked tarball fails to build alone |
| R6 | 3 | 60 min | Benchmarks vs baselines, docs, CI `elixir` job, acceptance package | any number without a results file |

**Ownership:**
- the coordinating agent owns the contract, the oracles, the vectors, `ex/` and the shared files;
- a Go agent owns `go/brdata`;
- a Rust agent owns `native/rust/crates/brd14-data`;
- one writer per file;
- agent reports are claims, re-verified in the integrated tree.

**Commits** name the rung. Where a decision was made, the commit carries Question, Steelman, Steward,
Decision, Falsifying check and Observed verification. A commit is not acceptance.

<a id="acceptance"></a>

## Acceptance and evidence

The Operator receives:
- the value delivered;
- the evidence: commits, the `make test` output, the parity matrix, the vector digests, benchmark
  results files;
- the limits:
  - deferred runtimes;
  - unmeasured claims;
  - the CI account block that keeps hosted runs from starting.

Evidence is recorded in the implementing commits and in [docs/parity.md](../parity.md),
[docs/benchmarks.md](../benchmarks.md) and [docs/structures.md](../structures.md). This story is
not updated with results. It stays the contract they are judged against.
