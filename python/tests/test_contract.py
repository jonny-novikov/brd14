"""The contract's frozen literals, asserted inline (they hold with or without vectors/),
plus the Python-specific surface: types, errors, str classification, time helpers."""

from __future__ import annotations

import datetime as dt
import pickle
from enum import IntEnum

import pytest

import brd14
from brd14 import ErrorCode, InvalidIdError, NamespaceRefusedError

MAX = 2**63 - 1
REF = 274557032793636864


# ── V-1 .. V-7, E-1, E-2, N-1 ───────────────────────────────────────────────


def test_v1_encode_and_inverse() -> None:
    assert brd14.encode("USR", REF) == "USR0KHTOWnGLuC"
    assert brd14.decode("USR0KHTOWnGLuC") == ("USR", REF)


def test_v2_decode() -> None:
    assert brd14.decode("USR0NgWEfAEJfs") == ("USR", 320636799581945856)


def test_v3_zero_is_left_padded() -> None:
    assert brd14.encode("ABC", 0) == "ABC00000000000"


def test_v4_max_payload() -> None:
    assert brd14.encode("ABC", MAX)[3:] == "AzL8n0Y58m7"
    assert brd14.decode("ABCAzL8n0Y58m7") == ("ABC", MAX)


@pytest.mark.parametrize(
    ("id_", "code"),
    [
        ("USRzzzzzzzzzzz", ErrorCode.RANGE),
        ("usr0KHTOWnGLuC", ErrorCode.NAMESPACE),
        ("USR0KHTOWnGLu", ErrorCode.LENGTH),
        ("USR0KHTOWnGLuCC", ErrorCode.LENGTH),
        ("USRAzL8n0Y58m8", ErrorCode.RANGE),  # the boundary from above
        ("usr0KHTOWnGL!!", ErrorCode.NAMESPACE),  # namespace beats charset
        ("USRzzzzzzzzzz!", ErrorCode.CHARSET),  # charset beats range
        ("", ErrorCode.LENGTH),
    ],
)
def test_v5_refusals_and_precedence(id_: str, code: ErrorCode) -> None:
    for view in (id_, id_.encode("ascii")):
        with pytest.raises(InvalidIdError) as ei:
            brd14.decode(view)
        assert ei.value.code is code
        assert brd14.check(view) is code
        assert brd14.is_valid(view) is False


def test_v6_hash32() -> None:
    assert brd14.hash32(REF) == 234878118


def test_v7_byte_order_is_numeric_order() -> None:
    snows = [*range(62), 62, 3843, 3844, 1 << 22, MAX]
    ids = [brd14.encode("SES", s) for s in snows]
    assert sorted(ids) == ids
    assert sorted(i.encode() for i in ids) == [i.encode() for i in ids]


def test_e1_e2_unix_ms() -> None:
    assert brd14.unix_ms(REF) == 1769526697641
    assert brd14.unix_ms(320636799581945856) == 1780512970164
    assert brd14.to_datetime(REF) == dt.datetime(2026, 1, 27, 15, 11, 37, 641000, tzinfo=dt.UTC)
    assert brd14.to_datetime(320636799581945856).isoformat() == "2026-06-03T18:56:10.164000+00:00"


@pytest.mark.parametrize(
    ("host", "pid", "node"),
    [("hosta", 100, 585), ("hosta", 101, 182), ("hosta", 4242, 290), ("", 100, 156), ("", 101, 559)],
)
def test_n1_node_from(host: str, pid: int, node: int) -> None:
    assert brd14.node_from(host, pid) == node
    assert brd14.node_from(host.encode(), pid) == node


def test_range_guard_constants() -> None:
    # The arithmetic form of the guard: 2**63 - 1 == QA * 62**6 + RB.
    assert divmod(MAX, 62**6) == (162382637, 503620799)
    assert brd14.MAX_SNOW == MAX
    assert brd14.EPOCH_MS == 1_704_067_200_000
    assert brd14.LEN == 14
    assert brd14.ALPHABET == "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


# ── encode ──────────────────────────────────────────────────────────────────


@pytest.mark.parametrize(
    ("ns", "snow", "code"),
    [
        ("usr", 2**63, ErrorCode.NAMESPACE),  # namespace first
        ("US", 0, ErrorCode.NAMESPACE),
        ("USRX", 0, ErrorCode.NAMESPACE),
        ("", 0, ErrorCode.NAMESPACE),
        ("U1R", 0, ErrorCode.NAMESPACE),  # "U1R".isupper() is True: isalpha must hold too
        ("ÀBC", 0, ErrorCode.NAMESPACE),
        ("USR", 2**63, ErrorCode.RANGE),
        ("USR", 2**64 - 1, ErrorCode.RANGE),
        ("USR", -1, ErrorCode.RANGE),
        ("USR", -(2**70), ErrorCode.RANGE),
    ],
)
def test_encode_refusals(ns: str, snow: int, code: ErrorCode) -> None:
    with pytest.raises(InvalidIdError) as ei:
        brd14.encode(ns, snow)
    assert ei.value.code is code


def test_encode_accepts_integer_likes() -> None:
    class Small(IntEnum):
        ONE = 1

    assert brd14.encode("ABC", True) == brd14.encode("ABC", 1) == brd14.encode("ABC", Small.ONE)

    class Indexable:
        def __index__(self) -> int:
            return REF

    assert brd14.encode("USR", Indexable()) == "USR0KHTOWnGLuC"  # type: ignore[arg-type]


def test_encode_type_errors() -> None:
    with pytest.raises(TypeError):
        brd14.encode("USR", 1.0)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        brd14.encode("USR", "1")  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        brd14.encode(b"USR", 1)  # type: ignore[arg-type]


def test_encode_str_subclass_namespace_gives_exact_str() -> None:
    class Ns(str):
        def __format__(self, spec: str) -> str:
            return "XXX"

    id_ = brd14.encode(Ns("USR"), REF)
    assert id_ == "USR0KHTOWnGLuC"
    assert type(id_) is str


# ── decode inputs ───────────────────────────────────────────────────────────


def test_str_is_classified_on_utf8_bytes() -> None:
    # 14 characters, 15 bytes: LENGTH, as the bytes API sees it.
    assert brd14.check("USR0KHTOWnGLuÉ") is ErrorCode.LENGTH
    # 13 characters, 14 bytes, the non-ASCII byte in the payload: CHARSET.
    assert brd14.check("USR0KHTOWnGLÉ") is ErrorCode.CHARSET
    # ... and in the namespace: NAMESPACE.
    assert brd14.check("UÉ0KHTOWnGLuC") is ErrorCode.NAMESPACE
    # A lone surrogate is 3 bytes under surrogatepass: 11 + 3 = 14, 10 + 3 = 13.
    assert brd14.check("USR0KHTOWnG\ud800") is ErrorCode.CHARSET
    assert brd14.check("USR0KHTOWn\ud800") is ErrorCode.LENGTH
    # Unicode digits and letters outside ASCII are not base62.
    assert brd14.check("USR0KHTOWnGLu١") is ErrorCode.LENGTH
    assert brd14.check("USR0KHTOWnGL١") is ErrorCode.CHARSET


def test_bytes_like_inputs() -> None:
    raw = b"USR0KHTOWnGLuC"
    for view in (raw, bytearray(raw), memoryview(raw)):
        assert brd14.decode(view) == ("USR", REF)
        assert brd14.is_valid(view)
        assert brd14.check(view) is ErrorCode.OK

    class Sub(str):
        pass

    assert brd14.decode(Sub("USR0KHTOWnGLuC")) == ("USR", REF)
    assert brd14.is_valid(Sub("USR0KHTOWnGLuC"))


def test_non_id_types() -> None:
    for bad in (None, 14, 3.0, ["USR0KHTOWnGLuC"]):
        assert brd14.is_valid(bad) is False
        with pytest.raises(TypeError):
            brd14.decode(bad)  # type: ignore[arg-type]
        with pytest.raises(TypeError):
            brd14.check(bad)  # type: ignore[arg-type]


def test_decode_result_types() -> None:
    for view in ("USR0KHTOWnGLuC", b"USR0KHTOWnGLuC"):
        ns, snow = brd14.decode(view)
        assert type(ns) is str and type(snow) is int


# ── errors ──────────────────────────────────────────────────────────────────


def test_error_model() -> None:
    assert issubclass(InvalidIdError, ValueError)
    assert not issubclass(NamespaceRefusedError, ValueError)
    assert not issubclass(NamespaceRefusedError, InvalidIdError)
    assert [int(c) for c in ErrorCode] == [0, 1, 2, 3, 4]
    assert [c.name for c in ErrorCode] == ["OK", "LENGTH", "NAMESPACE", "CHARSET", "RANGE"]
    with pytest.raises(InvalidIdError) as ei:
        brd14.decode("USR0KHTOWnGLu")
    assert "LENGTH" in str(ei.value) and "13 bytes" in str(ei.value)


def test_errors_pickle() -> None:
    e = InvalidIdError(ErrorCode.RANGE, "detail")
    back = pickle.loads(pickle.dumps(e))
    assert type(back) is InvalidIdError and back.code is ErrorCode.RANGE and str(back) == str(e)
    r = pickle.loads(pickle.dumps(NamespaceRefusedError("ZZZ")))
    assert r.ns == "ZZZ" and str(r) == str(NamespaceRefusedError("ZZZ"))


def test_huge_inputs_are_described_briefly() -> None:
    with pytest.raises(InvalidIdError) as ei:
        brd14.decode("x" * 10_000)
    assert len(str(ei.value)) < 200


# ── Branded, fields, time helpers ───────────────────────────────────────────


def test_parse_returns_branded() -> None:
    b = brd14.parse("USR0KHTOWnGLuC")
    assert isinstance(b, brd14.Branded) and isinstance(b, tuple)
    assert b == ("USR", REF) and b.ns == "USR" and b.snow == REF
    assert (b.ts, b.node, b.seq) == (REF >> 22, (REF >> 12) & 1023, REF & 4095)
    assert b.unix_ms == 1769526697641
    assert b.datetime == brd14.to_datetime(REF) and b.datetime.tzinfo is dt.UTC
    assert str(b) == "USR0KHTOWnGLuC"
    assert pickle.loads(pickle.dumps(b)) == b
    assert repr(b) == f"Branded(ns='USR', snow={REF})"


def test_field_readers() -> None:
    snow = (123456789 << 22) | (1023 << 12) | 4095
    assert (brd14.ts_of(snow), brd14.node_of(snow), brd14.seq_of(snow)) == (123456789, 1023, 4095)


def test_min_for() -> None:
    t = dt.datetime(2026, 1, 27, 15, 11, 37, 641999, tzinfo=dt.UTC)
    lo = brd14.min_for(t)
    assert lo == (1769526697641 - brd14.EPOCH_MS) << 22  # sub-millisecond part floored
    assert lo == brd14.min_for(1769526697641)
    assert lo <= REF and brd14.ts_of(lo) == brd14.ts_of(REF)
    # Any zone: the same instant gives the same bound.
    plus2 = dt.timezone(dt.timedelta(hours=2))
    assert brd14.min_for(t.astimezone(plus2)) == lo
    assert brd14.min_for(dt.datetime(2024, 1, 1, tzinfo=dt.UTC)) == 0
    assert brd14.min_for(brd14.EPOCH_MS - 1) == -(1 << 22)  # before the epoch: still a lower bound
    with pytest.raises(ValueError):
        brd14.min_for(dt.datetime(2026, 1, 1))
    with pytest.raises(TypeError):
        brd14.min_for(1.5)  # type: ignore[arg-type]


def test_hash32_full_u64_domain() -> None:
    def ref(k: int) -> int:
        k %= 2**64
        k ^= k >> 33
        k = (k * 0xFF51AFD7ED558CCD) % 2**64
        k ^= k >> 33
        return k % 2**32

    for k in (0, 1, 2**32 - 1, 2**32, MAX, 2**63, 2**64 - 1, REF):
        assert brd14.hash32(k) == ref(k)
        assert 0 <= brd14.hash32(k) < 2**32
    assert brd14.hash32(-1) == brd14.hash32(2**64 - 1)  # reduced modulo 2**64, as the oracle does
    assert brd14.hash32(2**64 + 5) == brd14.hash32(5)
    with pytest.raises(TypeError):
        brd14.hash32(1.0)  # type: ignore[arg-type]


def test_public_surface() -> None:
    for name in brd14.__all__:
        assert hasattr(brd14, name), name
    assert brd14.__version__ == "0.1.0"
