"""Seeded property tests: round-trip, ordering, totality, and agreement with a
small reference model written from the contract text (digit by digit, numeric
range guard), sharing nothing with the package's fast paths."""

from __future__ import annotations

import random

import pytest

import brd14
from brd14 import ErrorCode, InvalidIdError

ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
MAX = 2**63 - 1
N = 20_000


def model(raw: bytes) -> tuple[str, int] | ErrorCode:
    """docs/contract.md, decode, read literally."""
    if len(raw) != 14:
        return ErrorCode.LENGTH
    if not all(chr(b) in UPPER for b in raw[:3]):
        return ErrorCode.NAMESPACE
    if not all(chr(b) in ALPHABET for b in raw[3:]):
        return ErrorCode.CHARSET
    value = 0
    for b in raw[3:]:
        value = value * 62 + ALPHABET.index(chr(b))
    if value > MAX:
        return ErrorCode.RANGE
    return raw[:3].decode("ascii"), value


def observe(value: object) -> tuple[str, int] | ErrorCode:
    """decode, check and is_valid on one input; they must agree, and nothing
    but InvalidIdError may escape decode."""
    try:
        got: tuple[str, int] | ErrorCode = brd14.decode(value)  # type: ignore[arg-type]
    except InvalidIdError as e:
        got = e.code
        assert e.code is not ErrorCode.OK
    code = brd14.check(value)  # type: ignore[arg-type]
    assert isinstance(code, ErrorCode)
    assert code is (got if isinstance(got, ErrorCode) else ErrorCode.OK)
    assert brd14.is_valid(value) is (code is ErrorCode.OK)
    return got


def rand_snow(rng: random.Random) -> int:
    kind = rng.randrange(4)
    if kind == 0:
        return rng.randrange(2**63)
    if kind == 1:  # realistic: a timestamp near now, any node, any seq
        return (rng.randrange(2**36) << 22) | rng.randrange(2**22)
    if kind == 2:
        return rng.choice([0, 1, 61, 62, 3843, 3844, MAX, MAX - 1, 62**10, 62**10 - 1, 62**5, 62**6])
    return rng.randrange(2**rng.randrange(1, 64))


def rand_ns(rng: random.Random) -> str:
    return "".join(rng.choice(UPPER) for _ in range(3))


def test_round_trip() -> None:
    rng = random.Random(0xB4D14)
    for _ in range(N):
        ns, snow = rand_ns(rng), rand_snow(rng)
        id_ = brd14.encode(ns, snow)
        assert len(id_) == 14 and id_.isascii()
        assert brd14.decode(id_) == (ns, snow) == model(id_.encode())
        assert brd14.decode(id_.encode()) == (ns, snow)
        assert brd14.is_valid(id_)


def test_byte_order_is_numeric_order() -> None:
    rng = random.Random(7)
    snows = [rand_snow(rng) for _ in range(5_000)]
    snows += [d * 62**k for k in range(11) for d in range(62) if d * 62**k <= MAX]
    ids = [brd14.encode("ORD", s) for s in snows]
    assert sorted(ids) == [brd14.encode("ORD", s) for s in sorted(snows)]
    assert sorted(ids, key=str.encode) == sorted(ids)


def mutate(rng: random.Random, raw: bytes) -> bytes:
    b = bytearray(raw)
    for _ in range(rng.randrange(1, 3)):
        op = rng.randrange(4)
        if op == 0 and b:
            b[rng.randrange(len(b))] = rng.randrange(256)
        elif op == 1 and b:
            b[rng.randrange(len(b))] = ord(rng.choice(ALPHABET))
        elif op == 2 and b:
            del b[rng.randrange(len(b))]
        else:
            b.insert(rng.randrange(len(b) + 1), rng.randrange(256))
    return bytes(b)


def rand_bytes(rng: random.Random) -> bytes:
    kind = rng.randrange(5)
    if kind == 0:
        return bytes(rng.randrange(256) for _ in range(rng.randrange(21)))
    if kind == 1:  # alphabet soup of plausible length
        return "".join(rng.choice(ALPHABET) for _ in range(rng.randrange(12, 17))).encode()
    if kind == 2:  # near the range boundary
        return rand_ns(rng).encode() + b"A" + "".join(rng.choice(ALPHABET) for _ in range(10)).encode()
    valid = brd14.encode(rand_ns(rng), rand_snow(rng)).encode()
    return valid if kind == 3 else mutate(rng, valid)


def test_bytes_totality_and_model() -> None:
    rng = random.Random(0xF00D)
    for _ in range(N):
        raw = rand_bytes(rng)
        got = observe(raw)
        assert got == model(raw), raw
        assert observe(bytearray(raw)) == got


def rand_char(rng: random.Random) -> str:
    kind = rng.randrange(6)
    if kind < 2:
        return rng.choice(ALPHABET)
    if kind == 2:
        return chr(rng.randrange(0x80, 0x100))  # Latin-1: 2 UTF-8 bytes
    if kind == 3:
        return chr(rng.randrange(0x100, 0xD800))  # BMP: 2-3 bytes
    if kind == 4:
        return chr(rng.randrange(0xD800, 0xE000))  # lone surrogate: 3 bytes (surrogatepass)
    return chr(rng.randrange(0x10000, 0x110000))  # astral: 4 bytes


def test_str_totality_and_utf8_classification() -> None:
    rng = random.Random(0x5EED)
    for _ in range(N):
        if rng.randrange(3) == 0:
            s = brd14.encode(rand_ns(rng), rand_snow(rng))
            i = rng.randrange(14)
            s = s[:i] + rand_char(rng) + s[i + 1 :]
        else:
            s = "".join(rand_char(rng) for _ in range(rng.randrange(16)))
        raw = s.encode("utf-8", "surrogatepass")
        got = observe(s)
        assert got == model(raw), s
        assert got == observe(raw)


@pytest.mark.parametrize("seed", range(4))
def test_encode_totality(seed: int) -> None:
    rng = random.Random(seed)
    for _ in range(N // 4):
        ns = "".join(rand_char(rng) for _ in range(rng.randrange(5)))
        snow = rng.choice([rand_snow(rng), -rng.randrange(1, 2**70), 2**63 + rng.randrange(2**70)])
        ns_ok = len(ns) == 3 and all(c in UPPER for c in ns)
        try:
            id_ = brd14.encode(ns, snow)
        except InvalidIdError as e:
            assert e.code is (ErrorCode.RANGE if ns_ok else ErrorCode.NAMESPACE)
            assert ns_ok is False or not 0 <= snow <= MAX
        else:
            assert ns_ok and 0 <= snow <= MAX and model(id_.encode()) == (ns, snow)


def test_hash32_matches_definition() -> None:
    rng = random.Random(32)
    for _ in range(N):
        k = rng.randrange(2**64)
        x = k ^ (k >> 33)
        x = (x * 0xFF51AFD7ED558CCD) % 2**64
        x ^= x >> 33
        assert brd14.hash32(k) == x % 2**32
