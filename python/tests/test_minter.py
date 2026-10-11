"""The Gate/Minter plug, the one surface not frozen by the cross-language vectors.

Two tests are load-bearing beyond coverage, as in the Go suite:

- ``test_gate_exception_is_the_same_object`` pins "returned UNCHANGED": the
  very exception object the gate raised, not wrapped, not chained, message
  byte for byte.
- ``test_gate_runs_before_the_shape_check`` pins gate-first. Both orders
  refuse "log"; only the identity of the error tells them apart.
"""

from __future__ import annotations

import pytest

import brd14
from brd14 import EPOCH_MS, ErrorCode, Generator, InvalidIdError, Minter, NamespaceRefusedError


class CensusRefusal(Exception):
    pass


class Census:
    """A status-keyed registry, shaped like a real downstream policy."""

    def __init__(self, status: dict[str, str]) -> None:
        self.status = status
        self.seen: list[str] = []
        self.raised: list[CensusRefusal] = []

    def __call__(self, ns: str) -> None:
        self.seen.append(ns)
        if self.status.get(ns) == "active":
            return
        e = CensusRefusal(
            f"census: refusing to mint {ns!r} — not census-active "
            f"(status: {self.status.get(ns, 'unregistered')})"
        )
        self.raised.append(e)
        raise e


STATUS = {"USR": "active", "SES": "active", "LOG": "reserved"}


def test_gate_exception_is_the_same_object() -> None:
    census = Census(STATUS)
    m = Minter(Generator(1), census)
    with pytest.raises(CensusRefusal) as ei:
        m.mint("LOG")
    assert ei.value is census.raised[-1]
    assert str(ei.value) == "census: refusing to mint 'LOG' — not census-active (status: reserved)"
    assert ei.value.__cause__ is None and ei.value.__context__ is None
    with pytest.raises(CensusRefusal) as ei2:
        m.mint_snowflake("ZZZ")
    assert ei2.value is census.raised[-1]
    assert str(ei2.value).endswith("(status: unregistered)")


def test_gate_runs_before_the_shape_check() -> None:
    census = Census(STATUS)
    m = Minter(Generator(1), census)
    with pytest.raises(CensusRefusal):
        m.mint("log")  # off-census AND malformed: the policy's diagnostic wins
    assert census.seen == ["log"]  # the gate saw the raw namespace
    # And the converse: once admitted, the codec still refuses on its own terms.
    open_ = Minter(Generator(1), brd14.allow_all)
    with pytest.raises(InvalidIdError) as ei:
        open_.mint("lo")
    assert ei.value.code is ErrorCode.NAMESPACE


def test_refusal_mints_nothing() -> None:
    reads = []

    def clock() -> int:
        reads.append(1)
        return EPOCH_MS + 1_000

    g = Generator(1, clock=clock)
    m = Minter(g, brd14.deny_all)
    before = len(reads)
    with pytest.raises(NamespaceRefusedError):
        m.mint("USR")
    assert len(reads) == before  # the generator was never consulted


def test_deny_all_is_not_an_invalid_id() -> None:
    m = Minter(Generator(1), brd14.deny_all)
    for ns in ("USR", "ZZZ", "zz1", ""):
        with pytest.raises(NamespaceRefusedError) as ei:
            m.mint(ns)
        assert ei.value.ns == ns
        mro = type(ei.value).__mro__  # a policy refusal must not pass for a malformed id
        assert InvalidIdError not in mro and ValueError not in mro


@pytest.mark.parametrize("gate", [None, brd14.allow_all])
def test_no_policy_is_still_validated(gate: brd14.Gate | None) -> None:
    m = Minter(Generator(3), gate)
    for ns in ("USR", "ZZZ"):
        assert brd14.decode(m.mint(ns))[0] == ns
    for ns in ("zz1", "us", "USRX", "", "U R"):
        with pytest.raises(InvalidIdError) as ei:
            m.mint(ns)
        assert ei.value.code is ErrorCode.NAMESPACE


def test_mint_snowflake_agrees_with_the_id() -> None:
    m = Minter(Generator(613), Census(STATUS))
    id_, snow = m.mint_snowflake("USR")
    assert brd14.decode(id_) == ("USR", snow)
    assert brd14.node_of(snow) == 613


def test_mints_are_monotonic_across_both_entry_points() -> None:
    m = Minter(Generator(9), None)
    prev = 0
    for i in range(2_000):
        snow = m.mint_snowflake("SES")[1] if i % 2 else brd14.decode(m.mint("SES"))[1]
        assert snow > prev
        prev = snow


def test_a_gate_that_returns_a_value_is_refused() -> None:
    def bool_policy(ns: str) -> bool:
        return ns == "USR"

    m = Minter(Generator(1), bool_policy)  # type: ignore[arg-type]
    with pytest.raises(TypeError, match="returned a value"):
        m.mint("ZZZ")  # would have admitted everything
    with pytest.raises(TypeError):
        m.mint_snowflake("USR")


def test_generator_is_the_named_ungated_path() -> None:
    g = Generator(4)
    m = Minter(g, brd14.deny_all)
    assert m.generator is g
    assert brd14.decode(m.generator.next_branded("ZZZ"))[0] == "ZZZ"
    assert not hasattr(m, "next_branded") and not hasattr(m, "next")


def test_construction() -> None:
    with pytest.raises(TypeError):
        Minter(None, None)  # type: ignore[arg-type]
    assert repr(Minter(Generator(2), brd14.allow_all)) == "Minter(Generator(node=2), gate=allow_all)"
