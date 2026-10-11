"""The two failure kinds of brd14, kept apart on purpose.

``InvalidIdError`` means *this is not a branded id* (or cannot become one): a
shape or range fact about the bytes, classified by :class:`ErrorCode` with the
contract's namespace-first precedence. ``NamespaceRefusedError`` means *policy
said no*: the namespace may be perfectly well-formed. A caller that conflates
the two cannot tell "this brand is not yours to mint" from "this is garbage",
so neither class derives from the other, and only the first is a ValueError.
"""

from __future__ import annotations

from enum import IntEnum

__all__ = ["ErrorCode", "InvalidIdError", "NamespaceRefusedError"]


class ErrorCode(IntEnum):
    """The refusal classes of the contract, numbered as the C ABI numbers them.

    ``OK`` is what :func:`brd14.check` returns for a valid id; it is never the
    code of a raised :class:`InvalidIdError`.
    """

    OK = 0
    LENGTH = 1  #: decode input is not exactly 14 bytes
    NAMESPACE = 2  #: namespace is not exactly 3 bytes of A-Z
    CHARSET = 3  #: a payload byte is outside the base62 alphabet
    RANGE = 4  #: value outside [0, 2^63)


class InvalidIdError(ValueError):
    """A branded id (or an encode request) refused by the contract.

    ``code`` is the :class:`ErrorCode` the contract's precedence selects:
    encode checks NAMESPACE then RANGE; decode checks LENGTH, NAMESPACE,
    CHARSET, then RANGE. It is a :class:`ValueError`, so code that already
    handles bad values keeps working.
    """

    code: ErrorCode
    detail: str

    def __init__(self, code: ErrorCode | int, detail: str = "") -> None:
        self.code = ErrorCode(code)
        self.detail = detail
        super().__init__(f"{self.code.name}: {detail}" if detail else self.code.name)

    def __reduce__(self) -> tuple[type[InvalidIdError], tuple[ErrorCode, str]]:
        return (type(self), (self.code, self.detail))


class NamespaceRefusedError(Exception):
    """What :func:`brd14.deny_all` raises: a namespace refused by policy.

    Deliberately *not* an :class:`InvalidIdError` and not a ``ValueError``:
    the namespace may be well-formed, and a policy refusal must never pass for
    a malformed id. A real policy should raise its own exception with its own
    detail rather than reuse this one.
    """

    ns: str

    def __init__(self, ns: str) -> None:
        self.ns = ns
        super().__init__(f"namespace {ns!r} refused by policy")

    def __reduce__(self) -> tuple[type[NamespaceRefusedError], tuple[str]]:
        return (type(self), (self.ns,))
