"""The generator's three promises (strictly increasing, burst borrows into ts,
clock regression keeps minting), proven with an injected clock; plus node
derivation and the copy/pickle refusal."""

from __future__ import annotations

import copy
import itertools
import os
import pickle
import socket
import time

import pytest

import brd14
from brd14 import EPOCH_MS, ErrorCode, Generator, InvalidIdError


class FakeClock:
    """Unix milliseconds under the test's control; counts reads."""

    def __init__(self, ms: int) -> None:
        self.ms = ms
        self.reads = 0

    def __call__(self) -> int:
        self.reads += 1
        return self.ms


def fields(snow: int) -> tuple[int, int, int]:
    return brd14.ts_of(snow), brd14.node_of(snow), brd14.seq_of(snow)


def assert_strictly_increasing(xs: list[int]) -> None:
    bad = next((i for i in range(1, len(xs)) if xs[i] <= xs[i - 1]), None)
    assert bad is None, f"not strictly increasing at {bad}: {xs[bad - 1]} then {xs[bad]}"


def test_monotonic_on_the_real_clock() -> None:
    g = Generator(7)
    snows = [g.next() for _ in range(100_000)]
    assert_strictly_increasing(snows)
    assert {brd14.node_of(s) for s in snows} == {7}
    now = time.time_ns() // 1_000_000
    assert abs(brd14.unix_ms(snows[-1]) - now) < 5_000


def test_layout() -> None:
    clock = FakeClock(EPOCH_MS + 123_456)
    g = Generator(613, clock=clock)
    snow = g.next()
    # The cell starts at the construction instant, so the first mint is seq 1.
    assert fields(snow) == (123_456, 613, 1)
    assert snow == (123_456 << 22) | (613 << 12) | 1
    clock.ms += 1
    assert fields(g.next()) == (123_457, 613, 0)


def test_burst_borrows_into_the_timestamp() -> None:
    t0 = 1_000_000
    clock = FakeClock(EPOCH_MS + t0)
    g = Generator(5, clock=clock)
    snows = [g.next() for _ in range(10_000)]  # one frozen millisecond
    assert_strictly_increasing(snows)
    # seq 1..4095 in t0, then the carry moves into ts: no blocking, no sleeping.
    assert fields(snows[4094]) == (t0, 5, 4095)
    assert fields(snows[4095]) == (t0 + 1, 5, 0)
    assert brd14.ts_of(snows[-1]) == t0 + 10_000 // 4096
    # The wall clock catching up snaps the cell forward to it.
    clock.ms = EPOCH_MS + t0 + 50
    assert fields(g.next()) == (t0 + 50, 5, 0)


def test_clock_regression_keeps_minting() -> None:
    t0 = 2_000_000
    clock = FakeClock(EPOCH_MS + t0)
    g = Generator(9, clock=clock)
    before = [g.next() for _ in range(10)]
    clock.ms -= 60_000  # a one-minute backward step
    during = [g.next() for _ in range(5_000)]
    clock.ms = EPOCH_MS + t0 + 1  # recovers, but the logical clock is already ahead
    after = [g.next() for _ in range(10)]
    snows = before + during + after
    assert_strictly_increasing(snows)
    assert len(set(snows)) == len(snows)
    assert min(brd14.ts_of(s) for s in during) == t0  # never went back
    assert brd14.ts_of(after[-1]) == t0 + 1


def test_next_branded() -> None:
    g = Generator(7)
    prev = 0
    for _ in range(5_000):
        id_ = g.next_branded("SES")
        ns, snow = brd14.decode(id_)
        assert ns == "SES" and snow > prev and brd14.node_of(snow) == 7
        prev = snow
    with pytest.raises(InvalidIdError) as ei:
        g.next_branded("ses")
    assert ei.value.code is ErrorCode.NAMESPACE


def test_ids_sort_in_mint_order() -> None:
    g = Generator(3)
    ids = [g.next_branded("ORD") for _ in range(20_000)]
    assert sorted(ids) == ids


def test_iterator_protocol() -> None:
    g = Generator(1)
    snows = list(itertools.islice(g, 1000))
    assert_strictly_increasing(snows)
    assert iter(g) is g


@pytest.mark.parametrize("node", [-1, 1024, 2**40])
def test_node_out_of_range(node: int) -> None:
    with pytest.raises(ValueError):
        Generator(node)


def test_node_type() -> None:
    with pytest.raises(TypeError):
        Generator(1.0)  # type: ignore[arg-type]
    assert Generator(0).node == 0 and Generator(1023).node == 1023


def test_refuses_copy_and_pickle() -> None:
    g = Generator(1)
    for dup in (copy.copy, copy.deepcopy, pickle.dumps):
        with pytest.raises(TypeError):
            dup(g)


def test_overflow_past_2_63_is_a_range_refusal() -> None:
    # Year 2093 and beyond: the 41-bit timestamp is exhausted.
    g = Generator(1, clock=FakeClock(EPOCH_MS + (1 << 41)))
    assert g.next() >> 63 == 1
    with pytest.raises(InvalidIdError) as ei:
        g.next_branded("USR")
    assert ei.value.code is ErrorCode.RANGE


def test_default_node() -> None:
    node = brd14.default_node()
    assert 0 <= node <= brd14.NODE_MAX
    assert node == brd14.node_from(os.fsencode(socket.gethostname()), os.getpid())


def test_node_from_types() -> None:
    assert brd14.node_from("хост", 2**31 - 1) == brd14.node_from("хост".encode(), 2**31 - 1)
    assert brd14.node_from(bytearray(b"hosta"), 100) == 585  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        brd14.node_from(b"hosta", 1.5)  # type: ignore[arg-type]


def test_repr() -> None:
    assert repr(Generator(42)) == "Generator(node=42)"
