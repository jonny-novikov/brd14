// report.ts — the bench protocol of bench/README.md for the TypeScript trees:
// the shared corpus, protocol-shaped sampling on top of mitata, and the result
// JSON. Used by bench/pure.ts; bench/wasm.ts can reuse it unchanged.
//
// mitata's `bench()`/`run()` samples a fast function in batches of 4096 calls
// (one sample ≈ a few hundred µs) and trims two samples from each end. The
// protocol wants ≥ 10 samples of ≥ 50 ms each, median and MAD, so this file
// drives mitata's exported `measure()` directly: one timed iteration is
// `passes` full passes over the 4096-row corpus, calibrated to last ≥ 50 ms;
// mitata takes ≥ 16 such samples (its warmup, timing and do_not_optimize sink)
// and returns every one of them. ns_per_op is the median sample divided by the
// ops it contained; mad_ns the median absolute deviation of those per-op values.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { availableParallelism, cpus } from "node:os";
import { fileURLToPath } from "node:url";
import { do_not_optimize, measure as mitataMeasure } from "mitata";

export const REPO = fileURLToPath(new URL("../../", import.meta.url));
export const RESULTS_DIR = REPO + "bench/results/";
export const CORPUS_ROWS = 4096;
const MIN_SAMPLE_MS = 50;
const MIN_SAMPLES = 16;

export interface Corpus {
  ns: string[];
  snow: bigint[];
  id: string[];
  idBytes: Uint8Array[];
  ts: number[];
  node: number[];
  seq: number[];
  hi: number[];
  lo: number[];
  hash32: number[];
}

/** The first 4096 data rows of vectors/valid.tsv. */
export function loadCorpus(): Corpus {
  const path = REPO + "vectors/valid.tsv";
  if (!existsSync(path)) throw new Error(`bench: corpus missing: ${path}`);
  const rows = readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.length > 0 && !l.startsWith("#"))
    .slice(0, CORPUS_ROWS)
    .map((l) => l.split("\t"));
  if (rows.length !== CORPUS_ROWS) throw new Error(`bench: corpus has ${rows.length} rows, want ${CORPUS_ROWS}`);
  const enc = new TextEncoder();
  const c: Corpus = { ns: [], snow: [], id: [], idBytes: [], ts: [], node: [], seq: [], hi: [], lo: [], hash32: [] };
  for (const r of rows) {
    const snow = BigInt(r[1]!);
    c.ns.push(r[0]!);
    c.snow.push(snow);
    c.id.push(r[2]!);
    c.idBytes.push(enc.encode(r[2]!));
    c.hash32.push(Number(r[3]!));
    c.ts.push(Number(r[5]!));
    c.node.push(Number(r[6]!));
    c.seq.push(Number(r[7]!));
    c.hi.push(Number(snow >> 32n));
    c.lo.push(Number(snow & 0xffffffffn));
  }
  return c;
}

/** "node-24.21.0" or "bun-1.4.3". */
export function runtimeName(): string {
  const bun = (process.versions as Record<string, string | undefined>)["bun"];
  return bun !== undefined ? `bun-${bun}` : `node-${process.versions.node}`;
}

export function machineName(): string {
  try {
    return cpus()[0]?.model.trim() ?? "unknown";
  } catch {
    return "unknown";
  }
}

/** True under `taskset -c N`: one core available. */
export function isPinned(): boolean {
  try {
    return availableParallelism() === 1;
  } catch {
    return false;
  }
}

export interface OpResult {
  op: string;
  ns_per_op: number;
  mad_ns: number;
  samples: number;
  /** coefficient of variation of the samples (stddev / mean); > 0.05 is noisy */
  cv: number;
  /** ops per timed sample (passes × corpus rows) */
  ops_per_sample: number;
}

export interface Op {
  name: string;
  /** one full pass over the corpus; must feed every result to `sink` */
  pass: () => void;
}

/** The sink every op writes into; read by do_not_optimize after each sample. */
export let sink = 0;
export function feed(v: number): void {
  sink ^= v;
}

function median(xs: number[]): number {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m]! : (s[m - 1]! + s[m]!) / 2;
}

function mad(xs: number[], med: number): number {
  return median(xs.map((x) => Math.abs(x - med)));
}

function cv(xs: number[]): number {
  const mean = xs.reduce((a, b) => a + b, 0) / xs.length;
  const varc = xs.reduce((a, b) => a + (b - mean) ** 2, 0) / xs.length;
  return Math.sqrt(varc) / mean;
}

/** Calibrates passes per sample so one sample lasts ≥ MIN_SAMPLE_MS. */
function calibrate(pass: () => void): number {
  pass(); // warm the JIT a little before timing
  pass();
  let passes = 1;
  for (;;) {
    const t0 = performance.now();
    for (let p = 0; p < passes; p++) pass();
    const ms = performance.now() - t0;
    if (ms >= MIN_SAMPLE_MS) return passes;
    passes = Math.max(passes + 1, Math.ceil((passes * MIN_SAMPLE_MS * 1.2) / Math.max(ms, 0.01)));
  }
}

interface MitataStats {
  samples: number[];
  p50: number;
  avg: number;
  min: number;
  max: number;
}

/** Runs every op through mitata's measure() with protocol-shaped samples; returns results in op order. */
export async function measure(ops: Op[], quiet = false): Promise<OpResult[]> {
  const results: OpResult[] = [];
  for (const op of ops) {
    const passes = calibrate(op.pass);
    const perOp = passes * CORPUS_ROWS;
    const stats = (await mitataMeasure(
      () => {
        for (let p = 0; p < passes; p++) op.pass();
        do_not_optimize(sink);
      },
      {
        min_samples: MIN_SAMPLES,
        min_cpu_time: MIN_SAMPLES * MIN_SAMPLE_MS * 1e6,
        samples_threshold: Number.MAX_SAFE_INTEGER, // keep every sample: no trimming
      },
    )) as MitataStats;
    const samples = stats.samples.map((ns) => ns / perOp);
    const med = median(samples);
    const r: OpResult = {
      op: op.name,
      ns_per_op: round(med),
      mad_ns: round(mad(samples, med)),
      samples: samples.length,
      cv: Math.round(cv(samples) * 10000) / 10000,
      ops_per_sample: perOp,
    };
    results.push(r);
    if (!quiet) {
      console.log(`${op.name.padEnd(14)} ${r.ns_per_op.toFixed(2).padStart(9)} ns/op  mad ${r.mad_ns.toFixed(2).padStart(6)}  cv ${(r.cv * 100).toFixed(1).padStart(4)}%  ${r.samples} samples × ${perOp} ops`);
    }
  }
  return results;
}

function round(x: number): number {
  return Math.round(x * 1000) / 1000;
}

export interface Report {
  impl: string;
  variant: string;
  runtime: string;
  machine: string;
  pinned: boolean;
  corpus: string;
  results: OpResult[];
}

/** Writes `bench/results/<impl>-<variant>-<runtime>.json` and returns its path. */
export function writeReport(impl: string, variant: string, results: OpResult[]): string {
  const runtime = runtimeName();
  const report: Report = {
    impl,
    variant,
    runtime,
    machine: machineName(),
    pinned: isPinned(),
    corpus: `vectors/valid.tsv rows 1..${CORPUS_ROWS}`,
    results,
  };
  mkdirSync(RESULTS_DIR, { recursive: true });
  const path = `${RESULTS_DIR}${impl}-${variant}-${runtime.replace(/[/ ]/g, "-")}.json`;
  writeFileSync(path, JSON.stringify(report, null, 2) + "\n");
  return path;
}

/** A compact table on stdout; `baselines` maps an op to the naive op it is compared with. */
export function printTable(results: OpResult[], baselines: Record<string, string>): void {
  const by = new Map(results.map((r) => [r.op, r]));
  const w = Math.max(...results.map((r) => r.op.length));
  console.log(`\n${runtimeName()} on ${machineName()}${isPinned() ? " (pinned)" : " (not pinned)"}`);
  console.log(`${"op".padEnd(w)}  ${"ns/op".padStart(9)}  ${"mad".padStart(7)}  ${"cv".padStart(6)}  samples  vs naive`);
  for (const r of results) {
    const base = baselines[r.op] !== undefined ? by.get(baselines[r.op]!) : undefined;
    const speed = base ? `${(base.ns_per_op / r.ns_per_op).toFixed(1)}x` : "";
    console.log(
      `${r.op.padEnd(w)}  ${r.ns_per_op.toFixed(2).padStart(9)}  ${r.mad_ns.toFixed(2).padStart(7)}  ${(r.cv * 100).toFixed(1).padStart(5)}%  ${String(r.samples).padStart(7)}  ${speed}`,
    );
  }
}
