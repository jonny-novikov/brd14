"""pymem.py: what a 14- versus 16-character id costs as a CPython object.

Run by tools/storage_probe/run.py once per interpreter and per width, so the
resident-set reading of one width never reuses memory freed by the other:

    python3.14 pymem.py <n> <width>

It prints one JSON object on stdout with three readings:

- sys.getsizeof of one str (compact ASCII) and of the same text as bytes: the
  object size CPython itself reports, header included.
- resident set size delta over n distinct strings held in a pre-sized list, so
  the list's pointer array is in the baseline: what the process pays per
  string once pymalloc has rounded the object up to a block.
- the pymalloc size-class table from sys._debugmallocstats(), read before and
  after the allocation: which class the strings landed in, as a block count.
  The function writes to the C-level stderr, so fd 2 is pointed at a temporary
  file around each call and parsed back.
"""

from __future__ import annotations

import json
import os
import re
import sys
import tempfile

ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
_ROW = re.compile(r"^\s*(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$")


def rss_bytes() -> int:
    with open("/proc/self/statm") as f:
        pages = int(f.read().split()[1])
    return pages * os.sysconf("SC_PAGE_SIZE")


def malloc_classes() -> dict[int, int]:
    """pymalloc 'blocks in use' per size class, from sys._debugmallocstats()."""
    stats = getattr(sys, "_debugmallocstats", None)
    if stats is None:
        return {}
    with tempfile.TemporaryFile(mode="w+b") as tmp:
        sys.stderr.flush()
        saved = os.dup(2)
        try:
            os.dup2(tmp.fileno(), 2)
            stats()
        finally:
            os.dup2(saved, 2)
            os.close(saved)
        tmp.seek(0)
        text = tmp.read().decode("ascii", "replace")
    out: dict[int, int] = {}
    for line in text.splitlines():
        m = _ROW.match(line)
        if m:
            _cls, size, _pools, in_use, _avail = (int(g) for g in m.groups())
            out[size] = in_use
    return out


def make(i: int, width: int) -> str:
    out = []
    v = i
    for _ in range(width):
        v, r = divmod(v, 62)
        out.append(ALPHABET[r])
    return "".join(reversed(out))


def measure(width: int, n: int) -> dict:
    keep = [None] * n  # the pointer array is allocated before the baseline
    c0 = malloc_classes()
    r0 = rss_bytes()
    for i in range(n):
        keep[i] = make(i, width)
    r1 = rss_bytes()
    c1 = malloc_classes()
    sample = keep[-1]
    assert len(sample) == width and sample.isascii()
    classes = {}
    for size in sorted(set(c0) | set(c1)):
        d = c1.get(size, 0) - c0.get(size, 0)
        if abs(d) >= n // 100:  # only classes that moved with the allocation
            classes[str(size)] = d
    return {
        "width": width,
        "n": n,
        "getsizeof_str": sys.getsizeof(sample),
        "getsizeof_bytes": sys.getsizeof(sample.encode("ascii")),
        "rss_delta": r1 - r0,
        "rss_per_string": (r1 - r0) / n,
        "pymalloc_blocks_in_use_delta_by_class": classes,
        "sample": sample,
    }


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 1_000_000
    width = int(sys.argv[2]) if len(sys.argv) > 2 else 14
    gil = getattr(sys, "_is_gil_enabled", lambda: True)()
    out = {
        "runtime": "cpython",
        "version": sys.version.split()[0],
        "free_threaded": not gil,
        "executable": sys.executable,
        "measurement": measure(width, n),
    }
    sys.stdout.write(json.dumps(out) + "\n")


if __name__ == "__main__":
    main()
