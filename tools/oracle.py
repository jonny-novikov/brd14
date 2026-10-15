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

OK, LENGTH, NAMESPACE, CHARSET, RANGE, LAYOUT = 0, 1, 2, 3, 4, 5
CLASS = {LENGTH: "LENGTH", NAMESPACE: "NAMESPACE", CHARSET: "CHARSET", RANGE: "RANGE", LAYOUT: "LAYOUT"}

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


# ── extension: layout profiles (docs/contract.md § Extensions) ─────────────
# The 22 bits under the timestamp split as node(n) | seq(s) | meta(m), meta
# lowest, n + s + m = 22. (10, 12, 0) is the base layout, bit for bit.
TS_BITS = 41
LOW_BITS = 22


class Refused(int):
    """An error class returned where a plain int is also a valid result (layout_pack)."""


def layout_ok(n: int, s: int, m: int) -> bool:
    return all(0 <= w <= LOW_BITS for w in (n, s, m)) and n + s + m == LOW_BITS


def layout_fields(n: int, s: int, m: int, snow: int) -> tuple[int, int, int, int] | int:
    """(ts, node, seq, meta) under the profile; LAYOUT before RANGE."""
    if not layout_ok(n, s, m):
        return Refused(LAYOUT)
    if not 0 <= snow <= MAX_SNOW:
        return Refused(RANGE)
    ts, low = divmod(snow, 2**LOW_BITS)
    rest, meta = divmod(low, 2**m)
    node, seq = divmod(rest, 2**s)
    return ts, node, seq, meta


def layout_pack(n: int, s: int, m: int, ts: int, node: int, seq: int, meta: int) -> int:
    """The snowflake of the fields under the profile, or a Refused class; LAYOUT before RANGE."""
    if not layout_ok(n, s, m):
        return Refused(LAYOUT)
    if not (0 <= ts < 2**TS_BITS and 0 <= node < 2**n and 0 <= seq < 2**s and 0 <= meta < 2**m):
        return Refused(RANGE)
    return ((ts * 2**n + node) * 2**s + seq) * 2**m + meta


def layout_mint(s: int, cell: int, now_ms: int) -> int:
    """The generator cell under a profile: ts << s | seq, advanced to max(now, last + 1)."""
    return max((now_ms - EPOCH_MS) * 2**s, cell + 1)


# ── extension: the virtual clock (docs/contract.md § Extensions) ───────────
# A generator's cell `ts << 12 | seq` is a hybrid logical clock for local events:
# each mint advances it to max(physical, last + 1). `observe` is the receive rule.
# A snowflake orders by ts | node | seq but the cell by ts | seq, so matching the
# observed cell is NOT enough: a lower node in the same millisecond would sort
# first. The rule therefore moves the cell to the end of the observed id's
# millisecond, and the next mint lands in a later millisecond than the observed id.


def vclock_run(node: int, start_ms: int, program: list[tuple]) -> tuple[list[int], list[bool], int]:
    """Replays a generator under a virtual clock.

    program: ("t", unix_ms) sets the clock; ("m", k) mints k ids; ("o", snow, max_ahead_ms)
    observes a snowflake, refused (cell unchanged) when its ms is more than max_ahead_ms ahead
    of the physical clock. Returns (minted snowflakes, observe verdicts, final virtual unix ms).
    """
    assert 0 <= node <= 1023, node  # the domain (docs/contract.md, Virtual clock)
    assert EPOCH_MS <= start_ms < EPOCH_MS + 2**41, start_ms
    now = start_ms
    cell = (now - EPOCH_MS) * 2**12
    ids: list[int] = []
    verdicts: list[bool] = []
    for ev in program:
        if ev[0] == "t":
            now = ev[1]
            assert EPOCH_MS <= now < EPOCH_MS + 2**41, now
        elif ev[0] == "m":
            for _ in range(ev[1]):
                cell = max((now - EPOCH_MS) * 2**12, cell + 1)
                ids.append((cell // 2**12) * 2**22 + node * 2**12 + cell % 2**12)
        elif ev[0] == "o":
            snow, max_ahead = ev[1], ev[2]
            assert 0 <= snow <= MAX_SNOW
            ts = snow // 2**22
            if ts - (now - EPOCH_MS) > max_ahead:
                verdicts.append(False)
            else:
                verdicts.append(True)
                cell = max(cell, (ts + 1) * 2**12 - 1)
    return ids, verdicts, cell // 2**12 + EPOCH_MS


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
    # Layout profiles: the base profile is the base layout; packing inverts fields.
    for snow in (0, 274557032793636864, 320636799581945856, MAX_SNOW):
        ts, node, seq, meta = layout_fields(10, 12, 0, snow)
        assert (ts, node, seq) == fields(snow) and meta == 0
        for n, s_, m in ((6, 12, 4), (8, 10, 4), (0, 0, 22), (22, 0, 0), (0, 22, 0)):
            assert layout_pack(n, s_, m, *layout_fields(n, s_, m, snow)) == snow
    assert layout_fields(10, 12, 1, 0) == LAYOUT and layout_fields(23, 0, -1, 0) == LAYOUT
    assert layout_fields(10, 12, 0, 2**63) == RANGE
    assert layout_fields(10, 12, 1, 2**63) == LAYOUT  # LAYOUT before RANGE
    assert layout_pack(0, 0, 22, 0, 0, 0, 4) == 4 and not isinstance(layout_pack(0, 0, 22, 0, 0, 0, 4), Refused)
    assert isinstance(layout_pack(6, 12, 4, 0, 64, 0, 0), Refused)
    assert layout_pack(6, 12, 4, 0, 64, 0, 0) == RANGE and layout_pack(6, 12, 4, 2**41, 0, 0, 0) == RANGE
    assert layout_pack(6, 12, 4, 0, 0, 0, 16) == RANGE and layout_pack(6, 12, 4, 0, 0, 4096, 0) == RANGE
    # The virtual clock: the receive rule orders a reply after the message across nodes,
    # where matching the cell alone (the textbook HLC rule) would not.
    a, _, _ = vclock_run(900, EPOCH_MS + 100, [("m", 1)])
    b, ok, _ = vclock_run(5, EPOCH_MS + 100, [("o", a[0], 1000), ("m", 1)])
    assert ok == [True] and b[0] > a[0] and b[0] // 2**22 == a[0] // 2**22 + 1
    naive = (a[0] // 2**22) * 2**22 + 5 * 2**12 + (a[0] % 2**12) + 1  # cell matched, node 5
    assert naive < a[0]
    far = (100 + 5000) * 2**22  # an id 5 s ahead of the physical clock
    _, ok, v = vclock_run(5, EPOCH_MS + 100, [("o", far, 1000), ("m", 1)])
    assert ok == [False] and v == EPOCH_MS + 100
    # Meta lowest keeps one generator strictly increasing whatever meta each id carries.
    rng, cell, last = SplitMix64(7), 0, -1
    for i in range(20000):
        cell = layout_mint(12, cell, EPOCH_MS + i // 9000)  # bursts past 4096 per ms borrow into ts
        snow = layout_pack(6, 12, 4, cell >> 12, 33, cell & 4095, rng.below(16))
        assert snow > last, (i, snow, last)
        last = snow


if __name__ == "__main__":
    self_test()
    print("oracle: self-test ok (V-1..V-7, E-1, E-2, N-1, precedence, QA/RB, layout profiles, virtual clock)")
