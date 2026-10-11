"""threads.py: multi-thread mint throughput, the case free-threading changes.

    python bench/threads.py [--per-thread 200000] [--threads 1,2,4,8]

Three workloads, each run with N threads released together by a barrier:

- shared:  N threads mint from ONE Generator (the lock is contended);
- private: each thread mints from its OWN Generator (no shared lock), the
           ceiling the shared case is measured against;
- encode:  each thread encodes snowflakes (pure CPU, no lock at all).

Prints aggregate millions of ops per second and the speed-up over one
thread. Not pinned (the point is to use several cores) and not written to
bench/results: the bench protocol is single-threaded per-op latency.
"""

from __future__ import annotations

import argparse
import platform
import sys
import sysconfig
import threading
import time
from collections.abc import Callable
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

import brd14  # noqa: E402

FREE_THREADED = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
GIL = sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else True


def run(n: int, per: int, make: Callable[[int], Callable[[], object]]) -> float:
    """Aggregate ops/s for n threads each calling its work function `per` times."""
    works = [make(i) for i in range(n)]
    barrier = threading.Barrier(n + 1)
    sink: list[object] = [None] * n

    def body(i: int) -> None:
        f = works[i]
        r: object = None
        barrier.wait()
        for _ in range(per):
            r = f()
        sink[i] = r

    threads = [threading.Thread(target=body, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    barrier.wait()
    t0 = time.perf_counter()
    for t in threads:
        t.join()
    return n * per / (time.perf_counter() - t0)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--per-thread", type=int, default=200_000)
    ap.add_argument("--threads", default="1,2,4,8")
    ap.add_argument("--repeat", type=int, default=3, help="best of N runs per cell")
    a = ap.parse_args()
    counts = [int(x) for x in a.threads.split(",")]

    shared = brd14.Generator(1)
    workloads: dict[str, Callable[[int], Callable[[], object]]] = {
        "shared next()": lambda i: shared.next,
        "private next()": lambda i: brd14.Generator(i % 1024).next,
        "shared next_branded()": lambda i: lambda: shared.next_branded("USR"),
        "encode()": lambda i: lambda: brd14.encode("USR", 274557032793636864 + i),
    }
    runtime = f"{platform.python_version()}{'t' if FREE_THREADED else ''}"
    print(f"\nCPython {runtime}, GIL {'enabled' if GIL else 'disabled'}, "
          f"{a.per_thread} ops per thread, best of {a.repeat}")
    print(f"{'workload':<24}" + "".join(f"{f'{n} thr':>16}" for n in counts))
    for name, make in workloads.items():
        rates = [max(run(n, a.per_thread, make) for _ in range(a.repeat)) for n in counts]
        cells = "".join(f"{r / 1e6:>8.2f} M/s x{r / rates[0]:<4.1f}" for r in rates)
        print(f"{name:<24}{cells}")


if __name__ == "__main__":
    main()
