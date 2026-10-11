# CLAUDE.md — how agents work in this repository

**Where** to go and search is in @AGENTS.md. This file is **how** to work. It is the reference,
not a workflow script: it applies to every task, every agent and every sub-agent.

## The principle

Build the context you need and execute in phases (**PTE**, Phased Task Execution). Every phase
answers one question: **what is the value?** The answer names what the person who uses the result
gets. When no value can be named, no work starts.

## Phases

Execute in phase order. Say what you are about to do and why before each phase, and report what
you did and the value it served after it.

| Phase | Budget | Action | What is the value? |
|---|---:|---|---|
| UNDERSTAND | 5% | 6W, Rumsfeld, classify the problem | Who uses the result, and what they get |
| ESTIMATE | 5% | Size in FIB; set delegation and model; declare the stop condition | Is the value worth this size? The stop condition is the value delivered, not the activity finished |
| EXPAND | 30% | Load only the context that can change the value or the way to deliver it; stop when the budget is spent | Context bought for a reason |
| SYNTHESIZE | 10% | Steelman vs Steward: judge each option by value against cost; decide | The decision states its value |
| EXECUTE | 50% | Implement in changesets; report what was decided | The value delivered and **how it was verified**, not only what was done |

ESTIMATE is paid for out of EXPAND, because the EXPAND budget is what a correct estimate protects.

**6W** answers six questions in this order, Value last:

1. **What** — the outcome asked for;
2. **Why** — the reason, and the facts that establish it;
3. **Who** — who asks, who uses the result, who executes;
4. **Where** — paths, systems, records;
5. **When** — dates, order of steps, the next step;
6. **Value** — what the user of the result gets. It comes last because the other five serve it.

A decision recorded as a table uses the same six rows in the same order.

**Rumsfeld** names four things: the known knowns, the known unknowns, the unknown knowns (what
the repo already answers but you haven't read), and the unknown unknowns (what the plan must stay
open to).

**SDMR (Steelman–Steward):** first make the strongest honest case for each option. Then take the
Steward's view: the long-run cost to whoever maintains and operates the result (migrations,
debugging, onboarding, failure modes). Finally decide, and say what value the decision buys.

## Sizing (FIB): done before loading any context

Size by **unknowns**, not by page count. A bounded read-and-report over many files is a 3; one
unidentified subsystem is an 8.

| FIB | Name | Anchor | Tier | Delegation | `fable` |
|---:|---|---|:-:|---|:-:|
| 1 | Trivial | one known file, no unknowns, reversible | 1 | none, done in-loop | no |
| 2 | Small | known location, one fact to verify | 1 | none, done in-loop | no |
| 3 | Moderate | 2–5 files, one subsystem, answer readable | 1 | optional, one agent | no |
| 5 | Substantial | several subsystems, or one unknown that can change the approach | 2 | yes, `opus` | no |
| 8 | Complex | cross-tier, parallelisable concerns, findings can invalidate the plan | 2 | yes, in parallel | allowed |
| 13 | Large | must be split into waves; a wrong premise is likely | 2 | yes, one per wave | allowed |
| 21 | Oversized | **stop**: decompose and re-estimate; the Operator decides | 3 | — | — |

**Re-estimating is mandatory.** If EXPAND shows the task is one step bigger, stop: state the new
size and the reason, then re-plan. Two things send you back to UNDERSTAND, because each makes it a
different task rather than a bigger one:

- **a falsified premise**;
- **a changed value**: when the Operator changes what they want, the plan for the old value is
  void.

**Tiers:**

| Tier | Name | What it adds |
|---|---|---|
| 1 | Standard | Tools and files |
| 2 | Empowered | Adds hot context and agent orchestration |
| 3 | X-MODE | Adds the deepest rigour and mandatory team creation. Only when the Operator says so |

**Models:** sub-agents run `opus`; `fable` is allowed at FIB ≥ 8.

## Laws of this repository

1. **The contract is normative.** `docs/contract.md` defines behaviour and `tools/oracle.py`
   executes it. If an implementation disagrees with the oracle, the implementation is wrong. If
   you believe the contract is wrong, report it with evidence; never "fix" it on the side.
2. **Vectors are generated.** Change `tools/vectorgen.py` (or the oracle), run `make vectors`, and
   commit the regenerated `vectors/`. Never hand-edit a `.tsv`.
3. **Namespace-first precedence, everywhere.**
   - Encode: NAMESPACE, then RANGE.
   - Decode: LENGTH, NAMESPACE, CHARSET, RANGE.
   - Policy gates (Go `Gate`, the CLI `census`) run *before* the shape check, and their refusal
     reaches the caller unchanged.
4. **Behaviour changes land in every implementation or in none.** A change to the contract is one
   branch that touches the oracle, the vectors, every tree and the docs, and ends with every shim
   passing parity. **Extensions are additive** (the contract's Extensions section: layout
   profiles; [docs/structures.md](docs/structures.md)): they change no existing behaviour, land in
   the runtimes the Operator names, are advertised per shim (`HELLO … <ops>`), and the runtimes
   that lack them are listed as deferred in `docs/roadmap.md`, never as passing.
5. **Proof before push.** For the trees you changed, run `make -C <tree> test`, then
   `python3 tools/parity.py --only <shims>` (or the full matrix). If a gate fails, you fix it; you
   never skip, disable or quarantine a test. Report failing output verbatim.
6. **Zero allocation is a contract for the Go reference.** `go/alloc_test.go` must stay at 0 on
   every hot path and every refusal path. C and Rust stay heap-free (`make gates`,
   `alloc-check`).
7. **Measure, then claim.** Every number in a doc traces to a results file (`bench/results/`,
   `tools/storage_probe/**/results.json`), or is labelled *cited* (with a source) or *formula*.
   Noisy smoke runs are never committed as results.
8. **Never source untrusted config.** `.brdrc` is parsed against a key whitelist. Keep it that
   way.

## Delivery: KAN

Work is delivered as **KAN**: one Agentic User Story (AUS) per program, in `docs/kan/`, delivered in
rungs. The current story is [docs/kan/brd14-pragmatic-guide.md](docs/kan/brd14-pragmatic-guide.md).

- **The story is the contract.** It holds the 6W, the Rumsfeld lens, the SDMR decisions, a user
  story and an agent story (each at most three criteria plus a bad-input line), and the rungs.
  Read it before touching the paths it names; do not re-ask decisions it records.
- **Document identity.** A KAN document carries frontmatter in this order: `id`, `slug`, `type`,
  `version`, `path`, `title`, `summary`, `tags`, `group`, `language`, `audience`. The `id` is a
  brd14 id in the `KAN` namespace, minted **once** (`scripts/mint.sh KAN`), validated, never
  regenerated on an edit or a move.
- **A rung ends with evidence**, not with activity: the falsifying check from the story ran and
  the observed result is recorded in the implementing commit.
- **Blue refinement.** After a rung is green, spend what is left of its timebox on remediation,
  simplification and hardening, then re-check what that touched.
- **Delivery commits** name the rung. Where a decision was made, the body carries: Question,
  Steelman, Steward, Decision, Falsifying check, Observed verification. Quote the Operator's
  ruling exactly when one decided it. Keep intended and observed verification apart.
- **A commit is not acceptance.** Present the value, the evidence and the limits; the Operator
  accepts.

## How changes are made

- **Changesets.** Make one logical step per commit, each green on its own; commit often and push
  as you go. Use a subject line that says what changed, and a body that says why and how it was
  verified.
- **Branches.** Work on `claude/<topic>` from `origin/master`. **Never push to `master`, never
  rewrite shared history, and never create tags.** All three are the Operator's.
- **Parallel agents** work in isolated worktrees, with **one owner per directory**. They do not
  touch shared files: root README, `docs/index.md`, `docs/contract.md`, root Makefile and dotfiles
  belong to the integrator. A merge conflict means ownership was broken, so reject it rather than
  resolve it by hand. Agents commit and do not push; the integrator verifies, merges, pushes.
- **Agent reports are claims.** Re-run the agent's verification in the integrated tree before
  you trust it.
- **Scratch files** go in the session scratchpad and are uniquely named, because parallel agents
  share it.
- **Attribution.** End commits with the attribution lines the session specifies. Put no model
  identifiers anywhere else: not in code, docs or file names.

## Naming and audience

- The product name is **msh** (msh-server), the successor of cclin. Do not write cclin in new
  material.
- The Operator works across Elixir/Phoenix (EchoMQ, EchoCache, ETS, Valkey 9), Go runtimes and the
  Branded Component System (id-centric `{ns}{base62}`). They prefer pure functions and OTP
  patterns. Examples and articles speak to that stack.

## Environment

- **Cloud sessions:** the SessionStart hook provisions the toolchains (`scripts/setup.sh core`)
  and puts them on PATH via `scripts/env.sh`. Elsewhere, run `scripts/setup.sh` once, then
  `. scripts/env.sh`.
- **Pins:** the pinned versions live only in `scripts/versions.env`. Bump them there; the CI job
  fails when its `PIN_*` values drift.
- **Container quirk:** this container exports `BUN_OPTIONS=--smol` and `NODE_OPTIONS=…`. Clear
  them for benchmarks (`env -u BUN_OPTIONS -u NODE_OPTIONS`); `make -C ts bench` already does.
