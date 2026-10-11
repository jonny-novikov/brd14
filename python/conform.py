"""conform.py: the parity shim for the pure-Python package.

Protocol: docs/contract.md, "Parity shim protocol". The first stdout line is
``HELLO python pure EDHUFN``; then one response line per request line. All of
stdin is read at once and all responses are written in a single write.
Interpreter details go to stderr only.

The shim answers from the library and, on every request, cross-checks the
library against itself, so the parity run covers every public path and not
just one. A ``D`` request is decoded through ``decode``, ``check``,
``is_valid`` and ``parse`` on the bytes, on a bytearray, and (when the bytes
are representable as a str, i.e. UTF-8 with ``surrogatepass``) on the str,
whose fast path is separate code. Any disagreement replaces the response with
``ERR DISAGREE``, which can never match the oracle, and is described on stderr.

Run from the repository root: ``python3.14 python/conform.py < requests``.
"""

from __future__ import annotations

import sys
import sysconfig
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "src"))

import brd14  # noqa: E402
from brd14 import ErrorCode, InvalidIdError  # noqa: E402

DISAGREE = "ERR DISAGREE"


def unhex(s: str) -> bytes:
    return b"" if s == "-" else bytes.fromhex(s)


def complain(what: str) -> str:
    sys.stderr.write(f"conform: {what}\n")
    return DISAGREE


def decode_line(value: str | bytes | bytearray) -> tuple[str, ErrorCode, tuple[str, int] | None]:
    try:
        ns, snow = brd14.decode(value)
    except InvalidIdError as e:
        return f"ERR {e.code.name}", e.code, None
    return f"OK {ns} {snow}", ErrorCode.OK, (ns, snow)


def answer_decode(raw: bytes) -> str:
    want, code, result = decode_line(raw)
    views: list[str | bytes | bytearray] = [raw, bytearray(raw)]
    try:
        views.append(raw.decode("utf-8", "surrogatepass"))
    except UnicodeDecodeError:
        pass  # not representable as a str; the bytes API is the whole story
    for view in views:
        line, _, _ = decode_line(view)
        if line != want:
            return complain(f"decode({view!r}) -> {line!r}, but decode({raw!r}) -> {want!r}")
        if brd14.check(view) is not code:
            return complain(f"check({view!r}) -> {brd14.check(view)!r}, want {code!r}")
        if brd14.is_valid(view) is not (code is ErrorCode.OK):
            return complain(f"is_valid({view!r}) disagrees with {code!r}")
        if result is not None and tuple(brd14.parse(view)) != result:
            return complain(f"parse({view!r}) disagrees with decode")
    return want


def answer_encode(ns_raw: bytes, snow: int) -> str:
    # A str namespace cannot hold arbitrary bytes, so map them losslessly with
    # surrogateescape. The class cannot change: ASCII bytes map to the same
    # characters and every other byte to a non-ASCII character, so the str is
    # three characters A-Z exactly when the bytes are three bytes A-Z.
    ns = ns_raw.decode("utf-8", "surrogateescape")
    try:
        id_ = brd14.encode(ns, snow)
    except InvalidIdError as e:
        return f"ERR {e.code.name}"
    if brd14.decode(id_) != (ns, snow) or not brd14.is_valid(id_):
        return complain(f"encode({ns!r}, {snow}) = {id_!r} does not round-trip")
    return f"OK {id_}"


def answer_fields(snow: int) -> str:
    fields = (brd14.ts_of(snow), brd14.node_of(snow), brd14.seq_of(snow))
    b = brd14.Branded("USR", snow)
    if (b.ts, b.node, b.seq) != fields or b.unix_ms != brd14.unix_ms(snow):
        return complain(f"Branded fields disagree with the readers for {snow}")
    return "OK {} {} {}".format(*fields)


def answer_node(host: bytes, pid: int) -> str:
    node = brd14.node_from(host, pid)
    try:
        as_str = host.decode("utf-8", "surrogatepass")
    except UnicodeDecodeError:
        pass
    else:
        if brd14.node_from(as_str, pid) != node:
            return complain(f"node_from(str) disagrees with node_from(bytes) for {host!r}")
    return f"OK {node}"


def answer(line: str) -> str:
    op, *args = line.split(" ")
    if op == "E":
        return answer_encode(unhex(args[0]), int(args[1]))
    if op == "D":
        return answer_decode(unhex(args[0]))
    if op == "H":
        return f"OK {brd14.hash32(int(args[0]))}"
    if op == "U":
        return f"OK {brd14.unix_ms(int(args[0]))}"
    if op == "F":
        return answer_fields(int(args[0]))
    if op == "N":
        return answer_node(unhex(args[0]), int(args[1]))
    return complain(f"unsupported request {line!r}")


def main() -> int:
    free = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))
    gil = sys._is_gil_enabled() if hasattr(sys, "_is_gil_enabled") else True
    sys.stderr.write(
        f"conform: brd14 {brd14.__version__} on {sys.implementation.name} "
        f"{sys.version.split()[0]}{'t' if free else ''} (GIL {'enabled' if gil else 'disabled'})\n"
    )
    out = ["HELLO python pure EDHUFN"]
    for line in sys.stdin.buffer.read().decode("ascii").splitlines():
        if line:
            out.append(answer(line))
    sys.stdout.buffer.write(("\n".join(out) + "\n").encode("ascii"))
    sys.stdout.buffer.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
