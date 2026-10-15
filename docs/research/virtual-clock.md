---
id: "KAN0RGvS8UTse0"
slug: "DOCS-RESEARCH-VCLOCK"
type: "guide"
version: "1.3"
path: "docs/research/virtual-clock.md"
title: "The virtual clock: a brd14 id as hybrid logical time"
summary: "Research on using the timestamp inside a brd14 id as virtual time across nodes: the receive rule, why the textbook HLC rule breaks id order, the 2ε drift bound, the Go and Python evidence, and where it fits in an EchoMQ/EchoCache stack."
tags: ["research", "virtual-clock", "hlc", "causality", "generator"]
group: "research"
language: "en"
audience: ["Operator", "developer", "agent"]
---

# The virtual clock: a brd14 id as hybrid logical time

A brd14 generator already keeps a hybrid logical clock; it only lacked a rule for ids it
receives. This page derives that rule, shows why the textbook rule is wrong for a snowflake,
bounds how far virtual time can drift, and records the evidence from Go and Python. The normative
text is the contract's [Virtual clock](../contract.md#virtual-clock-experimental) extension.

[Index](../index.md#toc) · [Contract](../contract.md#toc) · [Go](../go.md#toc) · [Python](../python.md#toc) · [Parity](../parity.md#toc) · [KAN story](../kan/brd14-pragmatic-guide.md#toc)

<a id="toc"></a>

## In this document

- [The finding](#finding)
- [6W: what this delivers, to whom](#six-w)
- [Rumsfeld: what we know and what we don't](#rumsfeld)
- [Prior art](#prior-art)
- [The model](#model)
- [Why the textbook rule fails on a snowflake](#textbook-rule)
- [The drift bound](#drift-bound)
- [Evidence](#evidence)
- [Using it in the stack](#using)
- [Limits and cautions](#limits)
- [SDMR: the decisions](#sdmr)
- [Next steps](#next)

<a id="finding"></a>

## The finding

The generator cell `ts << 12 | seq` advances to `max(now, last + 1)` on every mint. That is the
local rule of a hybrid logical clock, with the 12-bit sequence as its logical counter. One more
rule makes it a clock that crosses nodes. **On receiving an id `m`, park the cell on the last slot
of `m`'s millisecond:**

```
cell ← max(cell, ((ts(m) + 1) << 12) − 1)        unless ts(m) is more than max_ahead_ms ahead
```

With that rule:

- **Causal order.** Every id minted after observing `m` sorts after `m`, whichever node minted
  it.
  - Go fleet: 0 of 199 978 replies sort before the message they answer.
  - The textbook HLC rule on the same fleet: 22 757 of them (11.4%) do.
- **Bounded drift.** When messages take at least 1 ms, a node's virtual time leads its own clock
  by at most **2ε**, where ε bounds clock skew. The bound is tight: measured 10 ms at ε = 5 ms.
- **A guard.** An id more than `max_ahead_ms` in the future is refused, and the clock does not
  move.
- **Determinism.** A generator over an injected clock is a pure function of its program, so
  generators are differential-tested for the first time: by `vectors/clock.tsv`, and in the
  parity matrix (op `G`). Go and Python mint identical ids for identical programs.

**Nothing on the wire changes.** The id *is* the clock value. Every message that already carries
a brd14 id carries a timestamp the receiver can observe, with no extra header and no wider id.
That is the leverage.

<a id="six-w"></a>

## 6W: what this delivers, to whom

| | |
|---|---|
| **What** | The timestamp inside a brd14 id, used as virtual (hybrid logical) time across nodes. The pieces: <br>- an injectable clock; <br>- the receive rule `observe`; <br>- a virtual-time reader; <br>- evidence in Go and Python. |
| **Why** | Ids sort by time and travel in every message. Today, causal order across services depends on clocks agreeing: for example, an EchoMQ job and the ids its consumer mints. Two facts make this research worth doing: <br>- the cell already follows the HLC local rule ([contract § The generator](../contract.md#the-generator)); <br>- the snowflake layout orders by `ts \| node \| seq` ([contract § The shape](../contract.md#shape)), which makes the textbook receive rule unsound ([below](#textbook-rule)). |
| **Who** | **Asks:** the Operator. **Uses:** developers of services that exchange brd14 ids, such as EchoMQ producers and consumers, EchoCache readers, and Go runtimes. **Executes:** the Go and Python generators, then the deferred runtimes. |
| **Where** | **Normative:** [contract § Virtual clock](../contract.md#virtual-clock-experimental). **Oracle:** `tools/oracle.py` `vclock_run`. **Vectors:** `vectors/clock.tsv`. **Go:** `go/snowflake.go`, `go/vclock_test.go`, `go/internal/vclocknode`. **Python:** `python/src/brd14/_generator.py`, `python/tests/test_virtual_clock.py`. **Parity:** op `G`. **Branch:** `claude/virtual-clock`. |
| **When** | Rung R7 of the [KAN story](../kan/brd14-pragmatic-guide.md#rungs). The first evidence is Go and Python, as the Operator asked. The other runtimes follow once the Operator names them. |
| **Value** | An id you received becomes a causal token: mint after observing it, and your id sorts after it. No coordinator, no wider id, no extra header. Every generator can also be checked against the oracle. |

<a id="rumsfeld"></a>

## Rumsfeld: what we know and what we don't

| | |
|---|---|
| **Known knowns** | The cell follows the HLC local rule. The ms-bump receive rule preserves id order: proved below, and tested on fleets of 8 and 16 nodes. Drift is at most 2ε when delays are ≥ 1 ms. A far-future id is refused. Go and Python agree on every program tried: 23 vector programs, 40 parity programs, and 20 random programs of 400 operations each. |
| **Known unknowns** | <br>- Real-world ε on the fleet: chrony or NTP offsets on the Fly Machines are not measured here. <br>- The right `max_ahead_ms` per deployment. <br>- The cost of `Observe` under contention: one CAS in Go, not benchmarked yet. <br>- How often bursts past 4096 ids/ms happen in production; a burst also moves virtual time ahead. |
| **Unknown knowns** | <br>- The base generator already tolerates backward clock steps without duplicates, and that same property makes an upward bump safe. <br>- Wherever a message already carries a brd14 id (a job id, an entity id), the receiver has the sender's clock value for free. |
| **Unknown unknowns** | <br>- How the rule meets layout profiles: the cell becomes `ts << s \| seq`, and the rule generalises to `((ts + 1) << s) − 1`, which is not yet specified. <br>- Restarts (see [Limits](#limits)). <br>- Long partitions with persistent skew. <br>- Hostile ids that stay inside `max_ahead_ms`. |

<a id="prior-art"></a>

## Prior art

Every entry here is *cited*. None of it is reproduced or measured in this repository.

| Work | What it contributes here |
|---|---|
| L. Lamport, "Time, Clocks, and the Ordering of Events in a Distributed System", *CACM* 21(7), 1978 | Logical clocks and the *clock condition*: if `a` happened before `b`, then `C(a) < C(b)`. The receive rule takes the max of the local and received values, then increments. P2 below is the clock condition for brd14 ids. |
| S. S. Kulkarni, M. Demirbas et al., "Logical Physical Clocks", *OPODIS* 2014 (hybrid logical clocks, HLC) | Pairs a physical part `l` with a counter `c`, keeps `l` within ε of physical time, and fits in 64 bits. The brd14 cell is that pair: `ts` is `l`, `seq` is `c`. |
| J. C. Corbett et al., "Spanner: Google's Globally-Distributed Database", *OSDI* 2012 | TrueTime makes clock uncertainty an explicit interval, and commit-wait turns it into external consistency. brd14 virtual time does **not** provide that (see [Limits](#limits)). |
| R. Taft et al., "CockroachDB: The Resilient Geo-Distributed SQL Database", *SIGMOD* 2020 | A production HLC with a configured maximum clock offset: a node whose clock strays too far from the others shuts itself down. The same idea as `max_ahead_ms`, enforced at a different place. |
| K. Davis, B. Peabody, P. Leach, "Universally Unique IDentifiers (UUIDs)", RFC 9562, 2024, §6.2 | Counter methods that keep time-ordered UUIDv7 monotonic within a millisecond, and how to handle counter rollover. brd14's 12-bit `seq`, which borrows into the timestamp, is a dedicated-counter design of that kind. |
| T. Akidau et al., "The Dataflow Model", *PVLDB* 8(12), 2015 | Event-time watermarks: a low watermark is the minimum over inputs of how far each has progressed. A node's virtual time gives such a bound for the ids it will mint ([below](#using)). |

<a id="model"></a>

## The model

Time `ts` is relative to the epoch `1704067200000`. The cell is `c = ts << 12 | seq`, and virtual
time is `V = (c >> 12) + epoch`.

| Event | Rule | HLC counterpart |
|---|---|---|
| mint (a local event or a send) | `c ← max(now << 12, c + 1)`; emit `ts << 22 \| node << 12 \| seq` | `l ← max(l, pt)`; `c ← c + 1` if `l` did not change, else `0` |
| observe `m` (a receive) | if `ts(m) − now > max_ahead_ms`: refuse; else `c ← max(c, ((ts(m) + 1) << 12) − 1)` | `l ← max(l, l_m, pt)`, with `c` set from whichever was largest |
| read | `V = (c >> 12) + epoch` | `l` |

The oracle states it as a pure fold, `vclock_run(node, start_ms, program)` in `tools/oracle.py`,
which returns the minted ids, the verdicts and the final virtual time. Every runtime must agree
with it.

**Properties.** Each one is checked by the tests named in [Evidence](#evidence).

- **P1, monotone.** One generator is strictly increasing under every program. Minting is the base
  contract, and `observe` only ever raises the cell.
- **P2, causal.** If `observe(m)` returned true before a mint `x`, on any generator, then
  `x > m`.
  - *Proof.* After the observe, `c ≥ ((ts_m + 1) << 12) − 1`. The mint makes `c′ ≥ (ts_m + 1) << 12`,
    so `ts_x ≥ ts_m + 1`, and a snowflake orders by `ts` first. ∎
  - By induction along any chain of mints and observes: *if `a` happened before `b`, then
    `id(a) < id(b)`*. This is Lamport's clock condition, read on the ids themselves.
- **P3, bounded drift.** Virtual time leads the node's clock by at most 2ε ([derivation](#drift-bound)).
- **P4, guarded.** A refused observe leaves `c` unchanged. An accepted one can put `V` at most
  `max_ahead_ms + 1` ahead of the physical clock at the moment it was accepted. That lead shrinks
  as the clock advances (bursts aside, and while the clock does not step back).
- **P5, deterministic.** Over an injected clock, a generator is a pure function of `(node,
  start_ms, program)`. That is what `vectors/clock.tsv` and op `G` pin down.

<a id="textbook-rule"></a>

## Why the textbook rule fails on a snowflake

HLC's receive rule, transplanted onto the cell, raises it to the observed cell: `c ← max(c, ts_m
<< 12 | seq_m)`. But a snowflake orders by `ts | node | seq`, and the cell orders by `ts | seq`.
The node field sits between them.

A worked example, at the V-1 instant `T = 65 459 497 641` ms after the epoch:

| Step | Snowflake | Fields `(ts, node, seq)` |
|---|---|---|
| node 900 mints `m` | `274557032797323264` | `(T, 900, 0)` |
| node 5, clock at `T`, textbook rule, then mints | `274557032793657345` | `(T, 5, 1)`: **sorts before `m`** |
| node 5, clock at `T`, ms-bump rule, then mints | `274557032797851648` | `(T + 1, 5, 0)`: sorts after `m` |

These are the `observe-same-ms-higher-node` row of `vectors/clock.tsv`. The textbook reply is
exactly what the Go suite produced when `Observe` was mutated to the textbook rule.

Whenever a lower-numbered node replies within the same millisecond, the textbook rule puts the
reply before the message. On a 16-node fleet spread over the whole 10-bit node range, that was
**11.4%** of replies, in Go and in Python alike.

**The cost of the fix.** Each hop can skip the rest of a millisecond's 4096 slots and move
virtual time forward by 1 ms. That is why message delay matters to the bound below. A rule that
compared full snowflakes `(ts, node, seq)` would still need the same bump whenever the sender's
node is higher, so no cheaper correct rule exists that leaves the layout unchanged.

<a id="drift-bound"></a>

## The drift bound

*Formula.* **Setup:**
- true time `t` is in whole milliseconds;
- node `n`'s clock reads `p_n(t) = t + o_n`, with `|o_n| ≤ ε`;
- every message is delivered at least 1 ms of true time after it was minted;
- no node mints 4096 ids within one millisecond.

**Claim.** Every id minted at true time `t` carries `ts ≤ t + ε` (in Unix ms).

**Proof,** by induction over events in true-time order. A mint sets `c ← max(p_n(t) << 12,
c + 1)`. The first term gives `ts ≤ t + ε`. For `c + 1`, look at what last set `c`:
1. **A mint at `t′ ≤ t`.** Its `ts ≤ t′ + ε ≤ t + ε`, by induction. With no burst, its `seq <
   4095`, so `c + 1` stays in the same millisecond.
2. **An observe of `m`, minted at `t_m ≤ t − 1`.** Then `c = (ts_m, 4095)`, and `c + 1` lands in
   `ts_m + 1 ≤ t_m + ε + 1 ≤ t + ε`.
3. **Construction at `t₀ ≤ t`.** `ts = p_n(t₀) ≤ t + ε`. ∎

After a reply at true time `t`, the receiver's virtual time is that reply's millisecond, so at
most `t + ε`. Its own clock reads at least `t − ε`. So:

```
drift = V − p_receiver ≤ 2ε
```

**The bound is tight.** Take a sender at `+ε` that mints at `t − 1`, so `ts = t − 1 + ε`, and a
receiver at `−ε`. The reply lands at `t + ε`, which is a drift of exactly 2ε. The ε = 5 ms fleet
reached it: 10 ms.

**What breaks it:**
- **Zero-delay hops.** A chain of `k` hops inside one millisecond adds up to `k` ms. The ordering
  fleet, with delays of 0–20 ms, still stayed at 92 ms for ε = 50, but no bound is claimed there.
- **Bursts.** Every 4096 ids within one millisecond borrow 1 ms ahead.

<a id="evidence"></a>

## Evidence

These numbers are not measurements. The seeds are pinned, so each one is the deterministic output
of the named test, and the test asserts the property rather than the number. Run the test to
reproduce it exactly.

| Claim | Test (prints the number) | Output |
|---|---|---|
| P2, Go, 16 nodes, ±50 ms, delays 0–20 ms | `go test -run TestObserveOrdersRepliesAcrossNodes -v` | 199 978 pairs, **0** out of order, max drift 92 ms |
| the textbook rule breaks P2 (Go) | `TestTextbookReceiveRuleBreaksOrder` | **22 757** of 199 978 out of order |
| P3, Go, ε = 0 / 5 / 50 / 500 ms, delays ≥ 1 ms | `TestVirtualDriftBound` | max drift 0 / 10 / 91 / 890 ms, bounds 0 / 10 / 100 / 1000 |
| P2, Python, 16 nodes | `pytest -s tests/test_virtual_clock.py` | 29 977 pairs, **0** out of order, max drift 92 ms |
| the textbook rule breaks P2 (Python) | same file | **3 410** of 29 977 out of order |
| P3, Python, ε = 0 / 5 / 50 / 500 ms | `test_drift_stays_within_two_skews` | 0 / 10 / 91 / 890 ms |
| P2 across runtimes: a mixed fleet, 4 Python + 4 Go generators (in `go/internal/vclocknode`, across a pipe) | `test_a_mixed_python_and_go_fleet_keeps_causal_order` | 2 980 pairs, **0** out of order, max drift 91 ms |
| P5 across runtimes | `test_python_and_go_mint_identical_ids_for_identical_programs` | 20 programs × 400 operations: identical ids, verdicts and virtual time |
| P4 | `TestObserveRefusesTheFarFuture`, `test_a_far_future_id_cannot_drag_the_clock` | an id 5 s ahead under a 1 s bound is refused, and `V` is unchanged |
| P1–P5 against the oracle | `TestVirtualClockVectors`, `test_clock_vectors_replay_exactly` | the 23 rows of `vectors/clock.tsv`, exact |
| parity | `python3 tools/parity.py --require` | 14 of 14 shims pass. Go and three Pythons answer 30 714 requests each, 63 of them `G`, with 0 mismatches |
| zero allocation | `go/alloc_test.go` | `Next` on a virtual clock, `Observe`, a refused `Observe`, `Observe` RANGE, `VirtualUnixMs`: 0 each |

**The tests can fail.** Each mutation below was applied once, temporarily, and reverted. The
outputs are recorded in the R7 commits.

| Mutant | Caught by |
|---|---|
| `Observe` uses the textbook cell | Go: vectors, fleet order ("22757 of 199978 replies sort before…"), drift, far future. Python: 8 of 10 tests. Parity: 41 `G` mismatches. |
| the `max_ahead` guard is removed | Go: vectors (verdict `1`, want `0`), far future. Python: vectors, far future, Python vs Go. |
| one `clock.tsv` digest is changed | the Go and Python replays, and the CI `oracle` job (the vectors no longer reproduce) |
| Go absent with `BRD14_REQUIRE_CROSS=1` | the cross-runtime tests fail instead of skipping |

<a id="using"></a>

## Using it in the stack

**1. Causal ids across EchoMQ hops.** A consumer observes the job's id before minting anything
for it. Its result ids then sort after the job, and after everything the producer minted before
sending it. A feed ordered by id, such as a `BrandedTree` cursor or a Valkey sorted set scored by
snowflake, never shows a reply before its question.

```go
// Go: one generator per process, built once.
ok, err := gen.Observe(job.Snow, 2_000) // accept up to 2 s of sender lead
switch {
case err != nil: // not an id (≥ 2^63): reject the message
case !ok:        // more than 2 s ahead: count it, quarantine or reject — the clock did not move
default:
	result := gen.Next() // sorts after job.Snow, whichever node minted it
	_ = result
}
```

```python
# Python
if gen.observe(job_snow, 2_000):
    result = gen.next()  # > job_snow
```

The Elixir runtime is deferred. The rule it would implement is one pure function over the cell,
written here only as a sketch:

```elixir
# A sketch of the contract's rule: ex/echo_data does not implement it yet.
def observe(cell, snow, now_ms, max_ahead_ms) do
  ts = snow >>> 22
  if ts - (now_ms - @epoch_ms) > max_ahead_ms,
    do: {:refused, cell},
    else: {:ok, max(cell, ((ts + 1) <<< 12) - 1)}
end
```

On the BEAM the cell would live in an `:atomics` slot, and the receive rule is the same CAS loop
as in Go.

**2. Read-your-writes tokens for EchoCache and Valkey replicas.**
- A client keeps the highest id it has written or read: its *causal token*.
- A replica that has applied everything up to id `W` serves the read when `W ≥ token`. Otherwise
  it waits or forwards the read to the primary.
- Because ids are minted under the receive rule, "applied up to" is a single 64-bit comparison.
- What brd14 does not supply: the replica's applied-up-to id comes from the replication stream.

**3. Watermarks for windows and expiry.**
- A cell never decreases, so every id that node `n` mints from now on has `unix_ms(id) ≥ V_n`.
- The minimum of `V_n` across the nodes that publish it, for example in heartbeats, is therefore
  a low watermark for **future mints**. It can close time windows, or settle `Buckets`
  generations.
- It does not cover messages in flight: ids minted earlier may still arrive below it. As in the
  Dataflow model, combine it with the transport's acknowledgements.

**4. Deterministic simulation.**
- Build generators over an injected clock: `NewGeneratorWithClock(node, clock)` in Go,
  `Generator(node, clock=…)` in Python.
- A test or an incident replay becomes a program `(node, start_ms, events)` with exactly one
  outcome. That is the form `vectors/clock.tsv` records.

<a id="limits"></a>

## Limits and cautions

- **Virtual time is not physical time.** Leases, TTLs, timeouts and rate limits must use the
  monotonic physical clock. Virtual time can lead by up to 2ε, or by `max_ahead_ms + 1` after
  accepting an id, and a lease measured on it would expire early.
- **No external consistency.** Unlike Spanner's commit-wait, two causally unrelated events are
  ordered arbitrarily within the skew window. The guarantee is P2: causality in, order out.
- **Restarts lose the cell.** Suppose a generator accepted an id ahead of its own clock, then
  restarts before that lead has passed. It can then mint ids below ones it minted before. The
  base generator has the same hazard with a backward clock step across a restart; the virtual
  clock makes the window larger. Two remedies:
  - persist the virtual high-water mark (in Valkey or a local file), and start from it or wait
    until the clock passes it;
  - keep `max_ahead_ms` small.
- **Bursts.** Each 4096 ids within one millisecond on one node borrow 1 ms of the future.
- **The end of the range.** Observing an id in the last millisecond of the 41-bit range
  (2093-09-06) parks the cell so that the next mint is out of range. That is the same edge the
  base generator reaches in 2093.
- **Trust.** `observe` trusts the id's timestamp. `max_ahead_ms` bounds what one hostile or
  badly skewed sender can do: it can still move every receiver forward by up to that much.
  - Choose `max_ahead_ms` as 2ε plus a margin.
  - Treat refusals as a signal, either skew or abuse, and count them.
- **Layout profiles.** Under a profile, the cell is `ts << s | seq`, and the rule generalises to
  `((ts + 1) << s) − 1`. It is not specified or tested yet.

<a id="sdmr"></a>

## SDMR: the decisions

| Question | Steelman (the option not taken) | Steward (long-run cost) | Decision |
|---|---|---|---|
| Which receive rule? | The textbook HLC rule: published, minimal, and it keeps one generator monotone. | It silently puts 11.4% of replies before their messages in every id-ordered feed. That is a correctness bug nobody would see until a feed showed it. | **Ms-bump.** It costs up to 1 ms of virtual time per hop and keeps P2 for every pair of nodes. |
| A far-future id: error, clamp, or verdict? | Clamp: accept it, but cap the cell at `now + max_ahead`. Nothing is dropped. | A clamped cell can mint below the id it accepted, which breaks P2 without a trace. An error would make a policy outcome look like a malformed input. | **A `false` verdict, cell unchanged.** Only `snow ≥ 2^63` is an error (RANGE). The caller decides between quarantine, rejection and logging, just as with a `Gate` refusal. |
| How is the clock injected? | An interface, or a package-level time hook: easy to mock. | A global hook leaks between tests and goroutines, and an interface costs an allocation or an indirection on the hot path. | **A `func() int64` field** (Unix ms; `nil` reads the wall clock). `Next` stays at 0 allocations, and Python reuses its existing `clock=`. |
| Which drift bound do the tests assert? | `2ε + 1`, leaving 1 ms of slack for the bump. | Unexplained slack hides a regression of exactly that size. | **`2ε`**, derived above. It is tight, and both suites assert it. |
| A parity op, or replay in each suite only? | The suites already replay `clock.tsv`; a parity op adds shim code. | Law 4 requires extensions to be advertised per shim. Parity checks against the oracle itself, not a frozen file, and every future runtime gets the check for free. | **Op `G`**, advertised by Go and Python. |

<a id="next"></a>

## Next steps

1. **The deferred runtimes:** Rust (an `AtomicI64` cell in the `no_std` core), C (C11 atomics),
   TypeScript and WebAssembly, Elixir (`:atomics` in `ex/echo_data`), and bash. Each one replays
   `clock.tsv` and advertises `G`. The list is kept in [roadmap.md](../roadmap.md#next-implementation).
2. **An EchoMQ adapter:** observe on receipt in the consumer, and publish `virtual_ms` in
   heartbeats for watermarks.
3. **Measure:**
   - `Observe` under contention (a Go benchmark, with a results file);
   - real ε on the Fly Machines (chrony tracking).
4. **A persisted high-water mark** for restarts: specify it, then test it with a restart in the
   fleet simulation.
5. **The virtual clock under layout profiles:** specify `((ts + 1) << s) − 1` and generate its
   vectors.
