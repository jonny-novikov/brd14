"""The consumer-side namespace plug: a Generator plus one policy decision.

The codec knows what a namespace *looks like* (three bytes of A-Z) and nothing
about what any particular one *means*. Meaning is policy, and policy belongs to
the consumer. :class:`Minter` is the seam between the two.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import NoReturn

from ._codec import encode
from ._errors import NamespaceRefusedError
from ._generator import Generator

__all__ = ["Gate", "Minter", "allow_all", "deny_all"]

#: A namespace policy: return None to admit ``ns``, raise to refuse it.
type Gate = Callable[[str], None]


def allow_all(ns: str) -> None:
    """The explicit spelling of "no policy": every namespace passes the gate.

    The codec's shape check still applies after it.
    """


def deny_all(ns: str) -> NoReturn:
    """Refuse every namespace with :class:`NamespaceRefusedError`.

    A safe initial gate for a consumer that wires its real policy later, so a
    half-built minter refuses rather than admits.
    """
    raise NamespaceRefusedError(ns)


class Minter:
    """Mint branded ids from a :class:`Generator`, governed by a gate.

    The gate runs **first**, on the raw namespace the caller passed, before the
    codec's shape check. Whatever it raises reaches the caller unchanged: the
    same exception object, neither wrapped nor chained, so a refusal arrives in
    the policy's own words. Only an admitted namespace reaches ``encode``, whose
    shape check still applies (InvalidIdError, NAMESPACE).

    ``gate=None`` means *no policy*, never *no validation*; prefer
    :func:`allow_all` when openness is intended and :func:`deny_all` while the
    policy is undecided. A gate that *returns* a value instead of raising is a
    bug (a bool-returning policy would admit everything), so a non-None return
    raises TypeError rather than minting.

    The Minter wraps its generator instead of exposing ``next_branded``, so the
    ungated path has to be spelled ``minter.generator.next_branded(ns)``.
    """

    __slots__ = ("_gate", "_generator")

    _generator: Generator
    _gate: Gate | None

    def __init__(self, generator: Generator, gate: Gate | None) -> None:
        if generator is None:
            raise TypeError("Minter needs a Generator, got None")
        self._generator = generator
        self._gate = gate

    @property
    def generator(self) -> Generator:
        """The underlying generator: the ungated path, named so every bypass reads as one."""
        return self._generator

    def mint(self, ns: str) -> str:
        """Gate ``ns``, then brand the next snowflake under it."""
        gate = self._gate
        if gate is not None and gate(ns) is not None:
            _gate_returned(gate)
        return encode(ns, self._generator.next())

    def mint_snowflake(self, ns: str) -> tuple[str, int]:
        """Like :meth:`mint`, also returning the snowflake behind the id."""
        gate = self._gate
        if gate is not None and gate(ns) is not None:
            _gate_returned(gate)
        snow = self._generator.next()
        return encode(ns, snow), snow

    def __repr__(self) -> str:
        gate = getattr(self._gate, "__qualname__", repr(self._gate))
        return f"Minter({self._generator!r}, gate={gate})"


def _gate_returned(gate: object) -> NoReturn:
    raise TypeError(
        f"gate {gate!r} returned a value; a gate admits by returning None and refuses by raising"
    )
