"""The snowflake generator and node derivation.

A generator owns one monotonic cell holding ``ts << 12 | seq`` (ts relative
to the epoch) and advances it to ``max(now_part, last + 1)`` under a
:class:`threading.Lock`. Python has no compare-and-swap, so the lock is the
contract's "a lock where the runtime has no CAS". It is not optional on any
build: with the GIL the read-modify-write of the cell can still be interleaved
between bytecodes, and on the free-threaded build (3.14t) threads run truly in
parallel. The clock is read *outside* the lock: a thread that read an older
``now`` and wins the lock later still gets ``last + 1``, so the stream stays
strictly increasing in lock order, the same argument as the Go CAS loop.
"""

from __future__ import annotations

import os
import threading
from collections.abc import Callable, Iterator
from operator import index as _index
from time import time_ns as _time_ns
from typing import NoReturn

from ._codec import EPOCH_MS, encode

__all__ = ["NODE_MAX", "Generator", "default_node", "node_from"]

#: The largest node id: the node field is 10 bits.
NODE_MAX = 1023

_FNV_OFFSET = 0x811C_9DC5
_FNV_PRIME = 0x0100_0193


def node_from(host: bytes | str, pid: int) -> int:
    """The 10-bit node id: FNV-32a over ``host ++ ASCII-decimal(pid)``, masked to 1023.

    The pid is mixed unconditionally, so two processes on one host differ
    except when the masked hash collides (about 1 in 1024 per pair). An empty
    host hashes the pid alone. A ``str`` host is hashed as its UTF-8 bytes.
    ``node_from("hosta", 100) == 585``.
    """
    if isinstance(host, str):
        host = host.encode("utf-8", "surrogatepass")
    h = _FNV_OFFSET
    for byte in bytes(host) + str(_index(pid)).encode("ascii"):
        h = ((h ^ byte) * _FNV_PRIME) & 0xFFFF_FFFF
    return h & NODE_MAX


def default_node() -> int:
    """A coordination-free node id from this host's name and this process's pid.

    The hostname is taken as the operating system's bytes. Computed on every
    call, so a forked child that calls it again gets its own pid's node.
    """
    import socket

    try:
        host = os.fsencode(socket.gethostname())
    except OSError:
        host = b""
    return node_from(host, os.getpid())


class Generator:
    """A thread-safe, strictly monotonic snowflake minter for one node.

    ``Generator(node)`` mints ``ts << 22 | node << 12 | seq`` with ``ts`` in
    milliseconds since 2024-01-01Z, read from ``time.time_ns() // 1_000_000``.
    Strictly increasing under every clock regime: a burst past 4096 ids/ms
    borrows into the timestamp (no blocking, no sleeping), and a backward clock
    step keeps minting off the logical clock (no duplicates).

    ``clock`` replaces the wall clock with any callable returning Unix
    milliseconds; it exists for tests. ``node`` must be in ``[0, 1023]``
    (ValueError otherwise; Go masks instead, which silently aliases nodes).

    A Generator is also an infinite iterator of snowflakes. It refuses to be
    copied or pickled, because two copies of one cell mint duplicate ids.
    """

    __slots__ = ("__weakref__", "_clock", "_last", "_lock", "_node", "_node_bits")

    _node: int
    _node_bits: int
    _clock: Callable[[], int] | None
    _lock: threading.Lock
    _last: int

    def __init__(self, node: int, *, clock: Callable[[], int] | None = None) -> None:
        node = _index(node)
        if not 0 <= node <= NODE_MAX:
            raise ValueError(f"node must be in [0, {NODE_MAX}], got {node}")
        self._node = node
        self._node_bits = node << 12
        self._clock = clock
        self._lock = threading.Lock()
        now_ms = _time_ns() // 1_000_000 if clock is None else clock()
        self._last = (now_ms - EPOCH_MS) << 12

    @property
    def node(self) -> int:
        """This generator's node id."""
        return self._node

    def next(self) -> int:
        """Mint the next snowflake."""
        clock = self._clock
        now = ((_time_ns() // 1_000_000 if clock is None else clock()) - EPOCH_MS) << 12
        with self._lock:
            last = self._last + 1
            if now > last:
                last = now
            self._last = last
        return (last >> 12 << 22) | self._node_bits | (last & 4095)

    def next_branded(self, ns: str) -> str:
        """Mint the next snowflake and brand it under ``ns`` in one call.

        Raises :class:`~brd14.InvalidIdError` (NAMESPACE) for a malformed
        namespace; the snowflake drawn for it is skipped, as in Go.
        """
        return encode(ns, self.next())

    def __iter__(self) -> Iterator[int]:
        return self

    def __next__(self) -> int:
        return self.next()

    def __repr__(self) -> str:
        return f"Generator(node={self._node})"

    def __copy__(self) -> NoReturn:
        raise TypeError("a Generator cannot be copied: two copies of one cell mint duplicate ids")

    def __deepcopy__(self, memo: object) -> NoReturn:
        self.__copy__()

    def __reduce__(self) -> NoReturn:
        raise TypeError("a Generator cannot be pickled: two copies of one cell mint duplicate ids")
