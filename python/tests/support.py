"""Test support: locating the repository's frozen vectors, shared constants.

Suites that read ``vectors/`` skip when it is absent (an sdist, a wheel test
run) and fail when it is absent but ``BRD14_REQUIRE_VECTORS=1`` is set (the
root Makefile and CI), per docs/contract.md.
"""

from __future__ import annotations

import os
import sysconfig
from collections.abc import Mapping
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parents[2]
VECTORS = REPO / "vectors"
FREE_THREADED = bool(sysconfig.get_config_var("Py_GIL_DISABLED"))


def locate_vectors(path: Path, environ: Mapping[str, str]) -> Path:
    """Return ``path`` if it holds the vectors; otherwise skip, or fail when required."""
    if (path / "valid.tsv").is_file():
        return path
    if environ.get("BRD14_REQUIRE_VECTORS") == "1":
        pytest.fail(f"BRD14_REQUIRE_VECTORS=1 but the contract vectors are missing at {path}")
    pytest.skip(f"contract vectors not present at {path} (published package?)")


def read_tsv(name: str) -> list[list[str]]:
    """The data rows of ``vectors/<name>``: comments dropped, columns split on TAB."""
    path = locate_vectors(VECTORS, os.environ) / name
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if line and not line.startswith("#"):
            rows.append(line.split("\t"))
    return rows


def unhex(s: str) -> bytes:
    """Hex as the vectors write it: '-' is the empty byte string."""
    return b"" if s == "-" else bytes.fromhex(s)
