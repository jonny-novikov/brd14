"""The parity shim speaks the protocol: HELLO first, one line per request, nothing else on stdout."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from support import FREE_THREADED

SHIM = Path(__file__).resolve().parents[1] / "conform.py"
ARGV = [sys.executable, *(["-X", "gil=0"] if FREE_THREADED else []), str(SHIM)]

REQUESTS = {
    "E 555352 274557032793636864": "OK USR0KHTOWnGLuC",
    "E 757372 9223372036854775808": "ERR NAMESPACE",
    "E 555352 9223372036854775808": "ERR RANGE",
    "E - 0": "ERR NAMESPACE",
    "D 555352304e6757456641454a6673": "OK USR 320636799581945856",
    "D 5553527a7a7a7a7a7a7a7a7a7a7a": "ERR RANGE",
    "D 757372304b48544f576e474c2121": "ERR NAMESPACE",
    "D 5553527a7a7a7a7a7a7a7a7a7a21": "ERR CHARSET",
    "D -": "ERR LENGTH",
    "D 555352304b48544f576e474c75c389": "ERR LENGTH",
    "H 274557032793636864": "OK 234878118",
    "H 18446744073709551615": "OK 2225773772",
    "U 274557032793636864": "OK 1769526697641",
    "F 274557032793636864": "OK 65459497641 0 0",
    "N 686f737461 100": "OK 585",
    "N - 101": "OK 559",
    # clock.tsv rows: steady, observe-same-ms-higher-node, observe-ahead-refused
    "G 613 1769526697641 m1,t1769526697642,m1,t1769526697643,m3":
        "OK 5 274557032796147713 274557032804536322 383af2dbf5414555 - 1769526697643",
    "G 5 1769526697641 o274557032797323264~1000,m2":
        "OK 2 274557032797851648 274557032797851649 3f0682719c8657b0 1 1769526697642",
    "G 5 1769526697641 o274557053765169161~1000,m2":
        "OK 2 274557032793657345 274557032793657346 33fe19e86709694e 0 1769526697641",
}


def run(stdin: bytes) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(ARGV, input=stdin, capture_output=True, timeout=120, check=True)


def test_hello_only_on_empty_input() -> None:
    p = run(b"")
    assert p.stdout == b"HELLO python pure EDHUFNG\n"
    assert b"conform:" in p.stderr


def test_answers() -> None:
    p = run("".join(r + "\n" for r in REQUESTS).encode())
    lines = p.stdout.decode("ascii").splitlines()
    assert lines[0] == "HELLO python pure EDHUFNG"
    assert lines[1:] == list(REQUESTS.values())
