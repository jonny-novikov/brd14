"""brd14: a 14-byte branded identity that is time-ordered, coordination-free, and carries its own type.

::

    USR0KHTOWnGLuC
    └┬┘└─────┬────┘
     │       └─ 11 chars of base62 over a ts(41) | node(10) | seq(12) snowflake
     └───────── a 3-letter uppercase namespace: the brand IS the type

Pure Python, standard library only, thread-safe on the free-threaded build.
The normative contract is docs/contract.md in the repository; this package is
one of several independent implementations held to it by shared vectors and a
differential parity run.

>>> import brd14
>>> brd14.encode("USR", 274557032793636864)
'USR0KHTOWnGLuC'
>>> brd14.decode("USR0KHTOWnGLuC")
('USR', 274557032793636864)
>>> brd14.parse("USR0KHTOWnGLuC").datetime.isoformat()
'2026-01-27T15:11:37.641000+00:00'
"""

from __future__ import annotations

from ._codec import (
    ALPHABET,
    EPOCH_MS,
    LEN,
    MAX_SNOW,
    Branded,
    check,
    decode,
    encode,
    hash32,
    is_valid,
    min_for,
    node_of,
    parse,
    seq_of,
    to_datetime,
    ts_of,
    unix_ms,
)
from ._errors import ErrorCode, InvalidIdError, NamespaceRefusedError
from ._generator import NODE_MAX, Generator, default_node, node_from
from ._minter import Gate, Minter, allow_all, deny_all

__version__ = "0.1.0"

__all__ = [
    "ALPHABET",
    "EPOCH_MS",
    "LEN",
    "MAX_SNOW",
    "NODE_MAX",
    "Branded",
    "ErrorCode",
    "Gate",
    "Generator",
    "InvalidIdError",
    "Minter",
    "NamespaceRefusedError",
    "__version__",
    "allow_all",
    "check",
    "decode",
    "default_node",
    "deny_all",
    "encode",
    "hash32",
    "is_valid",
    "min_for",
    "node_from",
    "node_of",
    "parse",
    "seq_of",
    "to_datetime",
    "ts_of",
    "unix_ms",
]
