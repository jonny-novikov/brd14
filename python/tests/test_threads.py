"""Concurrency: the point of running this suite on free-threaded 3.14t.

On a free-threaded build the GIL must really be off, or these tests prove
nothing; ``test_gil_is_disabled`` fails loudly if anything (an environment
variable, an extension module that is not marked free-threading safe)
re-enabled it. On GIL builds the switch interval is shortened so threads
interleave as often as the interpreter allows.
"""

from __future__ import annotations

import sys
import threading
from collections.abc import Callable, Iterator

import pytest

import brd14
from brd14 import Generator, Minter

from support import FREE_THREADED

THREADS = 8
PER_THREAD = 50_000


@pytest.fixture(autouse=True)
def eager_switching() -> Iterator[None]:
    old = sys.getswitchinterval()
    sys.setswitchinterval(1e-6)
    try:
        yield
    finally:
        sys.setswitchinterval(old)


def run_threads(n: int, work: Callable[[int], list[int]]) -> list[list[int]]:
    """Run ``work(i)`` on n threads released together by a barrier."""
    barrier = threading.Barrier(n)
    results: list[list[int]] = [[] for _ in range(n)]
    errors: list[BaseException] = []

    def body(i: int) -> None:
        try:
            barrier.wait()
            results[i] = work(i)
        except BaseException as e:  # surfaced below, with the thread's traceback
            errors.append(e)

    threads = [threading.Thread(target=body, args=(i,)) for i in range(n)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        raise errors[0]
    return results


@pytest.mark.skipif(not FREE_THREADED, reason="not a free-threaded build")
def test_gil_is_disabled() -> None:
    assert hasattr(sys, "_is_gil_enabled") and sys._is_gil_enabled() is False


def check_streams(streams: list[list[int]], per_thread: int) -> None:
    for i, s in enumerate(streams):
        assert len(s) == per_thread
        assert all(a < b for a, b in zip(s, s[1:])), f"thread {i} is not strictly increasing"
    merged = [x for s in streams for x in s]
    assert len(set(merged)) == len(merged), f"{len(merged) - len(set(merged))} duplicate snowflakes"


@pytest.mark.stress
def test_shared_generator_is_unique_and_per_thread_monotonic() -> None:
    g = Generator(77)

    def work(_: int) -> list[int]:
        nxt = g.next
        return [nxt() for _ in range(PER_THREAD)]

    streams = run_threads(THREADS, work)
    check_streams(streams, PER_THREAD)
    assert {brd14.node_of(x) for s in streams for x in s} == {77}


@pytest.mark.stress
def test_shared_generator_on_a_frozen_clock() -> None:
    # Every mint lands in one wall-clock millisecond: all uniqueness comes
    # from the lock-guarded cell borrowing into the timestamp.
    g = Generator(3, clock=lambda: brd14.EPOCH_MS + 10_000)

    def work(_: int) -> list[int]:
        return [g.next() for _ in range(PER_THREAD // 5)]

    streams = run_threads(THREADS, work)
    check_streams(streams, PER_THREAD // 5)
    total = THREADS * (PER_THREAD // 5)
    top = max(x for s in streams for x in s)
    # Exactly `total` consecutive cell values were handed out: nothing lost, nothing repeated.
    assert brd14.ts_of(top) * 4096 + brd14.seq_of(top) == 10_000 * 4096 + total


@pytest.mark.stress
def test_shared_minter_branded_ids() -> None:
    allowed = {"USR", "SES"}

    def gate(ns: str) -> None:
        if ns not in allowed:
            raise PermissionError(ns)

    m = Minter(Generator(5), gate)

    def work(i: int) -> list[int]:
        ns = "USR" if i % 2 else "SES"
        out = []
        for _ in range(PER_THREAD // 5):
            id_, snow = m.mint_snowflake(ns)
            assert id_[:3] == ns
            out.append(snow)
        return out

    check_streams(run_threads(THREADS, work), PER_THREAD // 5)


@pytest.mark.stress
def test_codec_is_reentrant() -> None:
    def work(i: int) -> list[int]:
        out = []
        for k in range(20_000):
            snow = (k * 0x9E3779B97F4A7C15 + i) % 2**63
            ns, back = brd14.decode(brd14.encode("THR", snow))
            assert (ns, back) == ("THR", snow)
            out.append(back)
        return out

    run_threads(THREADS, work)
