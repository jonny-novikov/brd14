"""The generated literal tables: right contents, reproducible, and (the reason they
are literals) immortal on the free-threaded build when loaded from a .pyc."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import runpy
import subprocess
import sys
from pathlib import Path

import pytest

import brd14
from brd14 import _tables

from support import FREE_THREADED

SRC = Path(__file__).resolve().parents[1] / "src"


def test_tables_match_the_alphabet() -> None:
    a = brd14.ALPHABET
    assert _tables.PAIRS == tuple(x + y for x in a for y in a)
    assert len(_tables.VALUE) == 256
    for byte in range(256):
        want = a.index(chr(byte)) if chr(byte) in a else 0xFF
        assert _tables.VALUE[byte] == want, byte


def test_tables_regenerate_to_themselves() -> None:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        runpy.run_path(_tables.__file__, run_name="__main__")
    assert out.getvalue() == Path(_tables.__file__).read_text(encoding="utf-8")


@pytest.mark.skipif(not FREE_THREADED, reason="immortal constants are a free-threaded concern")
def test_tables_are_immortal_when_loaded_from_pyc() -> None:
    probe = (
        "import sys, brd14._tables as t, brd14._codec as c;"
        "print(all(map(sys._is_immortal, (t.PAIRS, t.VALUE, c.ALPHABET, c._MAX_PAYLOAD))))"
    )
    argv = [sys.executable, "-X", "gil=0", "-c", probe]
    env = {**os.environ, "PYTHONPATH": str(SRC)}
    subprocess.run(argv, env=env, check=True, capture_output=True)  # writes the .pyc if it can
    if not Path(importlib.util.cache_from_source(_tables.__file__)).exists():
        pytest.skip("no .pyc could be written; constants compiled from source are not immortalized")
    out = subprocess.run(argv, env=env, check=True, capture_output=True, text=True).stdout
    assert out.strip() == "True"
