"""The codec: encode, decode, the validators, hash32 and the field readers.

Every literal here is contract (docs/contract.md), asserted by the frozen
vectors in the repository's ``vectors/`` and by every other implementation.

Speed notes, all measured on CPython 3.14 and 3.14t (docs/python.md has the
numbers). Arithmetic on ints below 2**30 ("compact" ints, one internal digit)
runs on fast paths; anything wider allocates a multi-digit int on every step.
So encode splits the value at 62**5 (= 916_132_832 < 2**30) twice, leaving three
pieces that are all compact, and turns each 5-digit piece into one alphabet
char plus two entries of a 3,844-entry pair table. Decode validates with the C
string predicates (``isascii``, ``isalpha``, ``isupper``, ``isalnum`` are exact
for ASCII, and the base62 alphabet is precisely ASCII alnum), maps the payload
to digit values with one ``bytes.translate``, and folds them in a Horner chain
that stays compact for the first five digits.
"""

from __future__ import annotations

import datetime as _dt
from collections.abc import Buffer
from operator import index as _index
from typing import NamedTuple, cast

from ._errors import ErrorCode, InvalidIdError
from ._tables import PAIRS, VALUE

__all__ = [
    "ALPHABET",
    "EPOCH_MS",
    "LEN",
    "MAX_SNOW",
    "Branded",
    "check",
    "decode",
    "encode",
    "hash32",
    "is_valid",
    "min_for",
    "node_of",
    "parse",
    "seq_of",
    "to_datetime",
    "ts_of",
    "unix_ms",
]

#: The base62 alphabet, in ASCII order, so byte order equals numeric order.
ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
#: The contract epoch, 2024-01-01T00:00:00Z, in Unix milliseconds.
EPOCH_MS = 1_704_067_200_000
#: The fixed length of a brd14 id, in bytes: 3 namespace + 11 payload.
LEN = 14
#: The largest snowflake, 2**63 - 1. The domain is [0, 2**63): an int64.
MAX_SNOW = (1 << 63) - 1

_MAX_PAYLOAD = "AzL8n0Y58m7"  # base62(2**63 - 1): the lexicographic range guard
_MAX_PAYLOAD_B = b"AzL8n0Y58m7"
_P2 = 62**2  # 3_844: one pair-table entry
_P4 = 62**4  # 14_776_336
_P5 = 62**5  # 916_132_832, below 2**30: the split point that keeps ints compact
_P6 = 62**6  # 56_800_235_584
_MASK32 = 0xFFFF_FFFF
_MASK64 = 0xFFFF_FFFF_FFFF_FFFF

# Every object the hot paths read is a literal, so it is shared without
# contention on the free-threaded build (see _tables.py): the single digits
# come from ALPHABET (an interned literal whose items are the interpreter's
# cached one-character strings), the 3,844-entry pair table and the byte ->
# digit table from _tables, and the constants above are folded literals.
# VALUE is only ever applied after an isalnum() check, so its 0xFF entries
# (bytes outside the alphabet) are never read.
_PAIRS = PAIRS
_VALUE = VALUE

_OK = ErrorCode.OK
_LENGTH = ErrorCode.LENGTH
_NAMESPACE = ErrorCode.NAMESPACE
_CHARSET = ErrorCode.CHARSET
_RANGE = ErrorCode.RANGE

_EPOCH_DT = _dt.datetime(2024, 1, 1, tzinfo=_dt.UTC)
_UNIX_EPOCH_DT = _dt.datetime(1970, 1, 1, tzinfo=_dt.UTC)
_ONE_MS = _dt.timedelta(milliseconds=1)

_tuple_new = tuple.__new__


# ── encode ──────────────────────────────────────────────────────────────────


def encode(ns: str, snow: int) -> str:
    """Brand a snowflake: ``encode("USR", 274557032793636864) == "USR0KHTOWnGLuC"``.

    ``ns`` must be exactly three characters ``A-Z``; ``snow`` must be an int in
    ``[0, 2**63)``. Raises :class:`InvalidIdError` with ``NAMESPACE`` before
    ``RANGE`` (namespace-first), and :class:`TypeError` for a non-str namespace
    or a non-integer snowflake. The payload is always 11 base62 digits,
    left-padded with ``0``.
    """
    if type(ns) is not str:
        ns = _str_arg(ns, "namespace")
    if type(snow) is not int:
        snow = _index(snow)
    if not (len(ns) == 3 and ns.isascii() and ns.isalpha() and ns.isupper()):
        raise _namespace_refusal(ns)
    if snow >> 63:  # nonzero exactly when snow >= 2**63 or snow < 0
        raise InvalidIdError(_RANGE, f"snowflake {snow} is outside [0, 2**63)")
    # snow = (d0 * 62**5 + hi) * 62**5 + lo, with hi and lo five digits each.
    q = snow // _P5
    lo = snow % _P5
    hi = q % _P5
    c, p = ALPHABET, _PAIRS
    return (
        f"{ns}{c[q // _P5]}"
        f"{c[hi // _P4]}{p[hi // _P2 % _P2]}{p[hi % _P2]}"
        f"{c[lo // _P4]}{p[lo // _P2 % _P2]}{p[lo % _P2]}"
    )


# ── decode and the validators ───────────────────────────────────────────────


def decode(id: str | Buffer) -> tuple[str, int]:
    """Split a branded id into ``(namespace, snowflake)``.

    Total over every ``str`` and bytes-like input: anything that is not a valid
    id raises :class:`InvalidIdError`, classified LENGTH, NAMESPACE, CHARSET,
    RANGE in that order. A ``str`` is classified on its UTF-8 bytes (lone
    surrogates encoded with ``surrogatepass``), so a 14-character string with a
    non-ASCII character is a LENGTH refusal, exactly as the bytes API sees it.
    """
    if type(id) is str:
        if len(id) == 14 and id.isascii():
            ns = id[:3]
            payload = id[3:]
            if ns.isalpha() and ns.isupper() and payload.isalnum() and payload <= _MAX_PAYLOAD:
                a, b, c, d, e, f, g, h, i, j, k = payload.encode().translate(_VALUE)
                return ns, (
                    ((((a * 62 + b) * 62 + c) * 62 + d) * 62 + e) * _P6
                    + (((((f * 62 + g) * 62 + h) * 62 + i) * 62 + j) * 62 + k)
                )
        raw = id.encode("utf-8", "surrogatepass")
    elif type(id) is bytes:
        raw = id
    else:
        raw = _as_bytes(id)
    if len(raw) == 14:
        ns_b = raw[:3]
        payload_b = raw[3:]
        if ns_b.isalpha() and ns_b.isupper() and payload_b.isalnum() and payload_b <= _MAX_PAYLOAD_B:
            a, b, c, d, e, f, g, h, i, j, k = payload_b.translate(_VALUE)
            return ns_b.decode("ascii"), (
                ((((a * 62 + b) * 62 + c) * 62 + d) * 62 + e) * _P6
                + (((((f * 62 + g) * 62 + h) * 62 + i) * 62 + j) * 62 + k)
            )
    raise _decode_refusal(id, raw)


def parse(id: str | Buffer) -> Branded:
    """Like :func:`decode`, returning a :class:`Branded` with field accessors."""
    return _tuple_new(Branded, decode(id))


def is_valid(id: object) -> bool:
    """True iff ``id`` is a valid brd14 id (shape and range). Never raises.

    Accepts ``str`` and bytes-like objects; any other object is simply not a
    valid id, so the answer is False rather than a TypeError.
    """
    if type(id) is str:
        if len(id) != 14 or not id.isascii() or not id.isalnum():
            return False
        ns = id[:3]
        # A payload led by a digit is below 10 * 62**10 < 2**63; only an
        # 'A'-led one needs the full lexicographic guard (above 'A' fails it).
        return ns.isalpha() and ns.isupper() and (id[3] < "A" or id[3:] <= _MAX_PAYLOAD)
    if type(id) is bytes:
        raw = id
    else:
        try:
            raw = _as_bytes(id)
        except TypeError:
            return False
    return _classify(raw) is _OK


def check(id: str | Buffer) -> ErrorCode:
    """Classify ``id`` without raising: ``ErrorCode.OK`` or the refusal class.

    The same classification :func:`decode` raises with, in the same
    precedence. Raises :class:`TypeError` only for an input that is neither
    ``str`` nor bytes-like.
    """
    if type(id) is str:
        if is_valid(id):
            return _OK
        raw = id.encode("utf-8", "surrogatepass")
    elif type(id) is bytes:
        raw = id
    else:
        raw = _as_bytes(id)
    return _classify(raw)


def _classify(raw: bytes) -> ErrorCode:
    """The contract's decode precedence over raw bytes: LENGTH, NAMESPACE, CHARSET, RANGE."""
    if len(raw) != 14:
        return _LENGTH
    ns = raw[:3]
    if not (ns.isalpha() and ns.isupper()):  # bytes predicates are ASCII-only
        return _NAMESPACE
    payload = raw[3:]
    if not payload.isalnum():  # ASCII alnum is exactly the base62 alphabet
        return _CHARSET
    if payload > _MAX_PAYLOAD_B:
        return _RANGE
    return _OK


def _as_bytes(obj: object) -> bytes:
    if isinstance(obj, str):  # a str subclass
        return str.encode(obj, "utf-8", "surrogatepass")
    try:
        return bytes(memoryview(cast(Buffer, obj)))
    except TypeError:
        raise TypeError(f"a brd14 id is str or bytes-like, not {type(obj).__name__}") from None


def _str_arg(obj: object, what: str) -> str:
    if isinstance(obj, str):  # a subclass: work on an exact copy
        return str.__str__(obj)
    raise TypeError(f"the {what} must be str, not {type(obj).__name__}")


def _shown(obj: object) -> str:
    r = repr(obj)
    return r if len(r) <= 40 else r[:37] + "..."


def _namespace_refusal(ns: str) -> InvalidIdError:
    return InvalidIdError(_NAMESPACE, f"namespace {_shown(ns)} is not exactly 3 characters A-Z")


def _decode_refusal(id: object, raw: bytes) -> InvalidIdError:
    code = _classify(raw)
    shown = _shown(id)
    if code is _LENGTH:
        detail = f"{shown} is {len(raw)} bytes; a brd14 id is exactly {LEN}"
    elif code is _NAMESPACE:
        detail = f"{shown}: the namespace is not 3 bytes A-Z"
    elif code is _CHARSET:
        detail = f"{shown}: a payload byte is outside the base62 alphabet [0-9A-Za-z]"
    else:
        detail = f"{shown}: the payload exceeds {_MAX_PAYLOAD} = base62(2**63 - 1)"
    return InvalidIdError(code, detail)


# ── hash32 and the field readers ────────────────────────────────────────────


def hash32(k: int) -> int:
    """The trie-placement hash: the first half of MurmurHash3 ``fmix64``, truncated.

    Defined on the full u64; ``k`` is reduced modulo 2**64 first (two's
    complement for a negative int), as the oracle does.
    ``hash32(274557032793636864) == 234878118``.
    """
    k &= _MASK64
    k = ((k ^ (k >> 33)) * 0xFF51_AFD7_ED55_8CCD) & _MASK64
    return (k ^ (k >> 33)) & _MASK32


def ts_of(snow: int) -> int:
    """The 41-bit timestamp field: milliseconds since the brd14 epoch."""
    return snow >> 22


def node_of(snow: int) -> int:
    """The 10-bit node field."""
    return (snow >> 12) & 1023


def seq_of(snow: int) -> int:
    """The 12-bit sequence field."""
    return snow & 4095


def unix_ms(snow: int) -> int:
    """The mint instant in Unix milliseconds: ``(snow >> 22) + EPOCH_MS``."""
    return (snow >> 22) + EPOCH_MS


def to_datetime(snow: int) -> _dt.datetime:
    """The mint instant as a UTC-aware :class:`datetime.datetime` (exact, no float)."""
    return _EPOCH_DT + _dt.timedelta(milliseconds=snow >> 22)


def min_for(t: _dt.datetime | int) -> int:
    """The smallest snowflake mintable at or after ``t``: ``(t_ms - EPOCH_MS) << 22``.

    The half-open lower bound for time-range scans and synthetic cursors.
    ``t`` is an aware datetime or Unix milliseconds; a naive datetime is
    refused with ValueError, because its instant depends on the local zone.
    Sub-millisecond parts are floored. A ``t`` before the epoch yields a
    negative bound, which is still a correct lower bound (as the oracle has it).
    """
    if isinstance(t, _dt.datetime):
        if t.utcoffset() is None:
            raise ValueError("min_for: a naive datetime is ambiguous; attach a tzinfo")
        ms = (t - _UNIX_EPOCH_DT) // _ONE_MS
    else:
        ms = _index(t)
    return (ms - EPOCH_MS) << 22


class Branded(NamedTuple):
    """A decoded id: ``(ns, snow)`` plus read-only views of the snowflake fields.

    ``str(branded)`` is the canonical 14-character id.
    """

    ns: str
    snow: int

    @property
    def ts(self) -> int:
        """Milliseconds since the brd14 epoch."""
        return self.snow >> 22

    @property
    def node(self) -> int:
        return (self.snow >> 12) & 1023

    @property
    def seq(self) -> int:
        return self.snow & 4095

    @property
    def unix_ms(self) -> int:
        return (self.snow >> 22) + EPOCH_MS

    @property
    def datetime(self) -> _dt.datetime:
        """The mint instant, UTC-aware."""
        return _EPOCH_DT + _dt.timedelta(milliseconds=self.snow >> 22)

    def __str__(self) -> str:
        return encode(self.ns, self.snow)
