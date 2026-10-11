"""oracle.py — the brd14 contract as an executable specification.

This is the judge, not an implementation: every library in the repository is
checked against it, so it is written to be *obviously* correct rather than fast.
It shares no algorithm with any fast path — arbitrary-precision divmod by 62,
digit-by-digit Horner sums, a byte-set membership charset check, and a numeric
(not lexicographic) range guard — so agreement with it is evidence, not echo.

Stdlib only. Run directly for the self-test against the frozen vectors:

    python3 tools/oracle.py
"""

from __future__ import annotations

ALPHABET = b"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
EPOCH_MS = 1_704_067_200_000
LEN = 14
NS_LEN = 3
PAYLOAD_LEN = 11
MAX_SNOW = 2**63 - 1
U64 = 2**64

OK, LENGTH, NAMESPACE, CHARSET, RANGE = 0, 1, 2, 3, 4
CLASS = {LENGTH: "LENGTH", NAMESPACE: "NAMESPACE", CHARSET: "CHARSET", RANGE: "RANGE"}

_DIGIT = {c: i for i, c in enumerate(ALPHABET)}
_UPPER = frozenset(range(ord("A"), ord("Z") + 1))


def ns_ok(ns: bytes) -> bool:
    return len(ns) == NS_LEN and all(b in _UPPER for b in ns)


def encode(ns: bytes, snow: int) -> bytes | int:
    """The 14-byte id, or an error code. Precedence: NAMESPACE, then RANGE."""
    if not ns_ok(ns):
        return NAMESPACE
    if not 0 <= snow <= MAX_SNOW:
        return RANGE
    digits = []
    v = snow
    for _ in range(PAYLOAD_LEN):
        v, r = divmod(v, 62)
        digits.append(ALPHABET[r])
    assert v == 0
    return bytes(ns) + bytes(reversed(digits))


def decode(id_: bytes) -> tuple[bytes, int] | int:
    """(namespace, snowflake), or an error code.

    Precedence: LENGTH, NAMESPACE, CHARSET, RANGE.
    """
    if len(id_) != LEN:
        return LENGTH
    if not ns_ok(id_[:NS_LEN]):
        return NAMESPACE
    payload = id_[NS_LEN:]
    if any(b not in _DIGIT for b in payload):
        return CHARSET
    value = 0
    for b in payload:
        value = value * 62 + _DIGIT[b]
    if value > MAX_SNOW:
        return RANGE
    return bytes(id_[:NS_LEN]), value


def hash32(k: int) -> int:
    k %= U64
    k ^= k >> 33
    k = (k * 0xFF51AFD7ED558CCD) % U64
    k ^= k >> 33
    return k % 2**32


def unix_ms(snow: int) -> int:
    return (snow >> 22) + EPOCH_MS


def fields(snow: int) -> tuple[int, int, int]:
    return snow >> 22, (snow >> 12) & 1023, snow & 4095


def min_for(t_ms: int) -> int:
    return (t_ms - EPOCH_MS) << 22


def fnv32a(data: bytes) -> int:
    h = 0x811C9DC5
    for b in data:
        h ^= b
        h = (h * 0x01000193) % 2**32
    return h


def node_from(host: bytes, pid: int) -> int:
    return fnv32a(bytes(host) + str(pid).encode("ascii")) & 1023


class SplitMix64:
    """Language-neutral deterministic stream (Steele, Lea & Flood, 2014)."""

    def __init__(self, seed: int) -> None:
        self.state = seed % U64

    def next(self) -> int:
        self.state = (self.state + 0x9E3779B97F4A7C15) % U64
        z = self.state
        z = ((z ^ (z >> 30)) * 0xBF58476D1CE4E5B9) % U64
        z = ((z ^ (z >> 27)) * 0x94D049BB133111EB) % U64
        return z ^ (z >> 31)

    def below(self, n: int) -> int:
        """Uniform in [0, n) by rejection — no modulo bias. n <= 2^64."""
        if not 0 < n <= U64:
            raise ValueError(f"below({n}): n must be in (0, 2^64]")
        limit = U64 - U64 % n
        while True:
            x = self.next()
            if x < limit:
                return x % n

    def ns(self) -> bytes:
        return bytes(ord("A") + self.below(26) for _ in range(NS_LEN))

    def bytes(self, n: int) -> bytes:
        return bytes(self.below(256) for _ in range(n))


def hexs(b: bytes) -> str:
    """Hex as the vectors and the parity protocol write it: '-' for empty."""
    return b.hex() if b else "-"


def unhex(s: str) -> bytes:
    return b"" if s == "-" else bytes.fromhex(s)


def self_test() -> None:
    assert encode(b"USR", 274557032793636864) == b"USR0KHTOWnGLuC"  # V-1
    assert decode(b"USR0KHTOWnGLuC") == (b"USR", 274557032793636864)
    assert decode(b"USR0NgWEfAEJfs") == (b"USR", 320636799581945856)  # V-2
    assert encode(b"ABC", 0) == b"ABC00000000000"  # V-3
    assert encode(b"ABC", MAX_SNOW)[3:] == b"AzL8n0Y58m7"  # V-4
    assert decode(b"USRzzzzzzzzzzz") == RANGE  # V-5
    assert decode(b"usr0KHTOWnGLuC") == NAMESPACE
    assert decode(b"USR0KHTOWnGLu") == LENGTH
    assert decode(b"USR0KHTOWnGLuCC") == LENGTH
    assert decode(b"USRAzL8n0Y58m8") == RANGE
    assert hash32(274557032793636864) == 234878118  # V-6
    assert unix_ms(274557032793636864) == 1769526697641  # E-1
    assert unix_ms(320636799581945856) == 1780512970164  # E-2
    for host, pid, want in [(b"hosta", 100, 585), (b"hosta", 101, 182), (b"hosta", 4242, 290),
                            (b"", 100, 156), (b"", 101, 559)]:
        assert node_from(host, pid) == want, (host, pid)  # N-1
    # The arithmetic range guard of the memory cores is the same boundary.
    qa, rb = divmod(MAX_SNOW, 62**6)
    assert (qa, rb) == (162382637, 503620799)
    # V-7: byte order == numeric order, every alphabet index in the low digit.
    snows = list(range(62)) + [62, 3843, 3844, 1 << 22, MAX_SNOW]
    ids = [encode(b"SES", s) for s in snows]
    assert sorted(ids) == ids
    # Precedence, both directions.
    assert encode(b"usr", 2**63) == NAMESPACE
    assert encode(b"US", 0) == NAMESPACE
    assert decode(b"usr0KHTOWnGL!!") == NAMESPACE
    assert decode(b"USRzzzzzzzzzz!") == CHARSET


if __name__ == "__main__":
    self_test()
    print("oracle: self-test ok (V-1..V-7, E-1, E-2, N-1, precedence, QA/RB)")
