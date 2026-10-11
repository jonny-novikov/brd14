"""bench.py: the brd14 pure-Python benchmarks, per bench/README.md.

    python bench/bench.py [--fast] [--affinity=2] [--ops encode,decode]   # pyperf (preferred)
    python bench/bench.py --timeit                                        # stdlib fallback

Every op cycles through the first 4096 rows of vectors/valid.tsv, in order,
inside the timed loop; the reported time is per op and includes the loop's
own iteration (a few ns; docs/python.md gives the measured baseline). The
median and the median absolute deviation go to
<repo>/bench/results/python-pure-<runtime>.json, runtime ``cpython-3.14.8``
or ``cpython-3.14.8t``.

pyperf runs each op in fresh worker processes (calibration, warmups, then
timed values) and pins them with --affinity, which this script defaults to
CPU 2 when the machine has one. On a free-threaded build every process
asserts that the GIL is really off, so a 3.14t number cannot silently be a
GIL number.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import sys
import sysconfig
import time
from collections.abc import Callable
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
sys.path.insert(0, str(HERE.parent / "src"))

import brd14  # noqa: E402

CORPUS_ROWS = 4096
FREE_THREADED = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
GIL = sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else True
RUNTIME = f"{sys.implementation.name}-{platform.python_version()}{'t' if FREE_THREADED else ''}"
PIN_CPU = 2

if FREE_THREADED and GIL:
    raise SystemExit(f"bench: {RUNTIME} is running WITH the GIL; run with PYTHON_GIL=0 / -X gil=0")


def load_corpus() -> list[tuple[str, int, str]]:
    path = REPO / "vectors" / "valid.tsv"
    rows = []
    with path.open(encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            ns, snow, id_ = line.split("\t")[:3]
            rows.append((ns, int(snow), id_))
            if len(rows) == CORPUS_ROWS:
                break
    if len(rows) != CORPUS_ROWS:
        raise SystemExit(f"bench: {path} has {len(rows)} rows, the corpus needs {CORPUS_ROWS}")
    return rows


CORPUS = load_corpus()
PAIRS = [(ns, snow) for ns, snow, _ in CORPUS]
SNOWS = [snow for _, snow, _ in CORPUS]
IDS = [id_ for _, _, id_ in CORPUS]
IDS_B = [id_.encode("ascii") for id_ in IDS]
NSS = [ns for ns, _, _ in CORPUS]
SINK: list[object] = []  # every op's last result lands here, so no call is dead code

# Each timer runs `loops` passes over the 4096-row corpus and returns seconds;
# pyperf divides by loops * 4096 (inner_loops).


def t_encode(loops: int) -> float:
    rows, f, r = PAIRS, brd14.encode, None
    t0 = time.perf_counter()
    for _ in range(loops):
        for ns, snow in rows:
            r = f(ns, snow)
    dt = time.perf_counter() - t0
    SINK.append(r)
    return dt


def t_decode(loops: int) -> float:
    rows, f, r = IDS, brd14.decode, None
    t0 = time.perf_counter()
    for _ in range(loops):
        for id_ in rows:
            r = f(id_)
    dt = time.perf_counter() - t0
    SINK.append(r)
    return dt


def t_decode_bytes(loops: int) -> float:
    rows, f, r = IDS_B, brd14.decode, None
    t0 = time.perf_counter()
    for _ in range(loops):
        for id_ in rows:
            r = f(id_)
    dt = time.perf_counter() - t0
    SINK.append(r)
    return dt


def t_hash32(loops: int) -> float:
    rows, f, r = SNOWS, brd14.hash32, 0
    t0 = time.perf_counter()
    for _ in range(loops):
        for snow in rows:
            r = f(snow)
    dt = time.perf_counter() - t0
    SINK.append(r)
    return dt


def t_valid(loops: int) -> float:
    rows, f, r = IDS, brd14.is_valid, False
    t0 = time.perf_counter()
    for _ in range(loops):
        for id_ in rows:
            r = f(id_)
    dt = time.perf_counter() - t0
    SINK.append(r)
    return dt


def t_mint(loops: int) -> float:
    rows, f, r = NSS, brd14.Generator(1).next_branded, ""
    t0 = time.perf_counter()
    for _ in range(loops):
        for ns in rows:
            r = f(ns)
    dt = time.perf_counter() - t0
    SINK.append(r)
    return dt


def t_next(loops: int) -> float:
    rows, f, r = NSS, brd14.Generator(1).next, 0
    t0 = time.perf_counter()
    for _ in range(loops):
        for _ns in rows:
            r = f()
    dt = time.perf_counter() - t0
    SINK.append(r)
    return dt


OPS: dict[str, Callable[[int], float]] = {
    "encode": t_encode,
    "decode": t_decode,
    "hash32": t_hash32,
    "mint": t_mint,
    "valid": t_valid,
    "decode_bytes": t_decode_bytes,  # variant-specific: the bytes input path
    "next": t_next,  # variant-specific: a bare snowflake, no branding
}


def summarize(op: str, seconds_per_op: list[float]) -> dict[str, Any]:
    ns = [v * 1e9 for v in seconds_per_op]
    med = statistics.median(ns)
    return {
        "op": op,
        "ns_per_op": round(med, 2),
        "mad_ns": round(statistics.median(abs(v - med) for v in ns), 2),
        "samples": len(ns),
        "cv": round(statistics.stdev(ns) / statistics.fmean(ns), 4) if len(ns) > 1 else 0.0,
    }


def machine() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or platform.machine()


def can_pin() -> bool:
    return hasattr(os, "sched_setaffinity") and PIN_CPU in os.sched_getaffinity(0)


def write(results: list[dict[str, Any]], harness: str, pinned: bool, out_dir: Path) -> Path:
    doc = {
        "impl": "python",
        "variant": "pure",
        "runtime": RUNTIME,
        "machine": machine(),
        "pinned": pinned,
        "corpus": f"vectors/valid.tsv rows 1..{CORPUS_ROWS}",
        "harness": harness,
        "gil": GIL,
        "results": results,
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    path = out_dir / f"python-pure-{RUNTIME.replace('/', '-').replace(' ', '-')}.json"
    path.write_text(json.dumps(doc, indent=2) + "\n")
    return path


def print_table(results: list[dict[str, Any]]) -> None:
    print(f"\n{RUNTIME} (GIL {'enabled' if GIL else 'disabled'})")
    print(f"{'op':<14} {'ns/op':>9} {'mad':>7} {'cv':>7} {'samples':>8}")
    for r in results:
        print(f"{r['op']:<14} {r['ns_per_op']:>9.1f} {r['mad_ns']:>7.1f} {r['cv']:>7.2%} {r['samples']:>8}")


def run_pyperf(argv: list[str]) -> None:
    import pyperf

    def forward(cmd: list[str], args: argparse.Namespace) -> None:
        # Workers select their task by index, so they must see the same op list.
        if args.ops:
            cmd.extend(["--ops", args.ops])

    xopts = [f"-X{k}={v}" if v is not True else f"-X{k}" for k, v in sys._xoptions.items()]
    runner = pyperf.Runner(program_args=(*xopts, sys.argv[0]), add_cmdline_args=forward)
    runner.argparser.add_argument("--ops", default="", help="comma-separated subset of " + ",".join(OPS))
    runner.argparser.add_argument("--out", default=str(REPO / "bench" / "results"))
    if not any(a.startswith("--affinity") for a in argv) and can_pin():
        argv = [*argv, f"--affinity={PIN_CPU}"]
    args = runner.parse_args(argv)
    selected = [o for o in (args.ops.split(",") if args.ops else OPS) if o]
    benches = {}
    for op in selected:
        benches[op] = runner.bench_time_func(op, OPS[op], inner_loops=CORPUS_ROWS)
    if args.worker:
        return
    results = [summarize(op, list(b.get_values())) for op, b in benches.items() if b is not None]
    print_table(results)
    path = write(results, f"pyperf {pyperf.__version__}", bool(args.affinity), Path(args.out))
    print(f"wrote {path}")


def run_timeit(argv: list[str]) -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeit", action="store_true")
    ap.add_argument("--ops", default="")
    ap.add_argument("--out", default=str(REPO / "bench" / "results"))
    ap.add_argument("--samples", type=int, default=20)
    args = ap.parse_args(argv)
    pinned = False
    if can_pin():
        os.sched_setaffinity(0, {PIN_CPU})
        pinned = True
    results = []
    for op in [o for o in (args.ops.split(",") if args.ops else OPS) if o]:
        f = OPS[op]
        f(1)  # warm up
        loops = 1
        while f(loops) < 0.05:  # every sample at least 50 ms
            loops *= 2
        samples = [f(loops) / (loops * CORPUS_ROWS) for _ in range(args.samples)]
        results.append(summarize(op, samples))
    print_table(results)
    print(f"wrote {write(results, 'timeit (stdlib)', pinned, Path(args.out))}")


def main() -> None:
    argv = sys.argv[1:]
    try:
        import pyperf  # noqa: F401
    except ImportError:
        have_pyperf = False
    else:
        have_pyperf = True
    if "--timeit" in argv or not have_pyperf:
        run_timeit(argv)
    else:
        run_pyperf(argv)


if __name__ == "__main__":
    main()
