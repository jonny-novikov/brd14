"""vectorgen.py — regenerate vectors/*.tsv from the oracle.

Deterministic: pinned splitmix64 seeds, so a regeneration that changes a byte is
a contract change (or an oracle bug) and `make vectors` fails on the diff.

    python3 tools/vectorgen.py [--out vectors]
"""

from __future__ import annotations

import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import oracle as o  # noqa: E402

SEED_VALID = 0x0B4D14_0001
SEED_INVALID = 0x0B4D14_0002
SEED_NODE = 0x0B4D14_0003
SEED_LAYOUT = 0x0B4D14_0004

# The bench corpus is the first BENCH_N random rows of valid.tsv: every runtime
# benchmarks the same snowflakes.
BENCH_N = 4096

V1_SNOW = 274557032793636864
V2_SNOW = 320636799581945856


def boundary_snows() -> list[int]:
    s = {0, 1, 61, 62, 3843, 3844, V1_SNOW, V2_SNOW, o.MAX_SNOW - 1, o.MAX_SNOW,
         1 << 22, (1 << 41) - 1, ((1 << 41) - 1) << 22, 1 << 62}
    for k in range(1, 11):
        p = 62**k
        s.update({p - 1, p, p + 1})
    s.update({62**6 * 162382637 - 1, 62**6 * 162382637, 62**6 * 162382637 + 503620799})
    return sorted(x for x in s if 0 <= x <= o.MAX_SNOW)


def valid_rows() -> list[str]:
    rng = o.SplitMix64(SEED_VALID)
    rows: list[tuple[bytes, int]] = []
    for _ in range(BENCH_N):
        rows.append((rng.ns(), rng.next() >> 1))
    for snow in boundary_snows():
        for ns in (b"USR", b"ABC", b"ZZZ", b"SES"):
            rows.append((ns, snow))
    out = []
    for ns, snow in rows:
        id_ = o.encode(ns, snow)
        assert isinstance(id_, bytes)
        ts, node, seq = o.fields(snow)
        out.append("\t".join([ns.decode(), str(snow), id_.decode(), str(o.hash32(snow)),
                              str(o.unix_ms(snow)), str(ts), str(node), str(seq)]))
    return out


def invalid_rows() -> list[str]:
    rng = o.SplitMix64(SEED_INVALID)
    seeds = [b"USR0KHTOWnGLuC", b"USR0NgWEfAEJfs", b"ABC00000000000", b"ZZZAzL8n0Y58m7"]
    cases: list[bytes] = [
        b"USRzzzzzzzzzzz", b"usr0KHTOWnGLuC", b"USR0KHTOWnGLu", b"USR0KHTOWnGLuCC",  # V-5
        b"USRAzL8n0Y58m8", b"USRAzL8n0Y58n0", b"USRB0000000000", b"USRa0000000000",
        b"US100000000000", b"U\x00R0KHTOWnGLuC", b"\xc3\x84\xc3\x96\xc3\x9c0KHTOWnG",
        "日本語のテスト".encode(), b"\xff" * 14, b"\x00" * 14, b"",
        # multi-fault precedence
        b"usr0KHTOWnGL!!",  # NAMESPACE beats CHARSET
        b"USRzzzzzzzzzz!",  # CHARSET beats RANGE
        b"usr0KHTOWnGLu",  # LENGTH beats NAMESPACE
        b"USR!zzzzzzzzzz",  # CHARSET beats RANGE (lex-high and off-alphabet)
        b"USR{0000000000",  # '{' sorts above 'z': CHARSET, not RANGE
        b"USR~0000000000",
    ]
    for seed in seeds:
        for n in range(0, 21):
            if n != o.LEN:
                cases.append((seed * 2)[:n])
        for pos in range(o.LEN):
            for bad in (0x00, 0x20, 0x21, 0x2F, 0x3A, 0x40, 0x5B, 0x60, 0x7B, 0x7F, 0x80, 0xFF):
                b = bytearray(seed)
                b[pos] = bad
                cases.append(bytes(b))
    # RANGE neighbourhood: bump each position of the max payload to every
    # higher alphabet char (all RANGE), plus random lexicographically-high
    # payloads that are valid base62 (value in [2^63, 62^11)).
    top = b"AzL8n0Y58m7"
    for pos in range(o.PAYLOAD_LEN):
        for c in o.ALPHABET:
            if c > top[pos]:
                cases.append(b"RNG" + top[:pos] + bytes([c]) + top[pos + 1:])
    for _ in range(64):
        wide = (rng.next() << 64) | rng.next()  # 62^11 > 2^64: draw 128 bits
        snow = 2**63 + wide % (62**11 - 2**63)
        digits = []
        for _ in range(o.PAYLOAD_LEN):
            snow, r = divmod(snow, 62)
            digits.append(o.ALPHABET[r])
        cases.append(rng.ns() + bytes(reversed(digits)))
    for _ in range(512):
        cases.append(rng.bytes(rng.below(21)))
    seen, out = set(), []
    for c in cases:
        r = o.decode(c)
        if isinstance(r, tuple) or c in seen:
            continue
        seen.add(c)
        out.append(f"{o.hexs(c)}\t{o.CLASS[r]}")
    return out


def encode_invalid_rows() -> list[str]:
    nss = [b"", b"U", b"US", b"USRR", b"USRRR", b"usr", b"UsR", b"US1", b"US ", b"US-", b"U\x00R",
           "ÄÖÜ".encode(), b"\xff\xff\xff", b"@AB", b"[AB", b"AB`", b"AB{"]
    snows = [0, 1, o.MAX_SNOW]
    bad_snows = [2**63, 2**63 + 1, o.U64 - 1, 3 << 62]
    out = []
    for ns in nss:
        for snow in snows + bad_snows:
            r = o.encode(ns, snow)
            assert r == o.NAMESPACE
            out.append(f"{o.hexs(ns)}\t{snow}\t{o.CLASS[r]}")
    for ns in (b"USR", b"ZZZ"):
        for snow in bad_snows:
            r = o.encode(ns, snow)
            assert r == o.RANGE
            out.append(f"{o.hexs(ns)}\t{snow}\t{o.CLASS[r]}")
    return out


def node_rows() -> list[str]:
    rng = o.SplitMix64(SEED_NODE)
    rows = [(b"hosta", 100), (b"hosta", 101), (b"hosta", 4242), (b"", 100), (b"", 101)]
    for host in (b"", b"hosta", b"hostb", b"brd14-prod-01", "хост".encode(), b"a" * 255):
        for pid in (0, 1, 7, 100, 4242, 65535, 4194304, 2**31 - 1):
            rows.append((host, pid))
    for _ in range(256):
        rows.append((rng.bytes(rng.below(40)), rng.below(2**31)))
    out, seen = [], set()
    for host, pid in rows:
        if (host, pid) in seen:
            continue
        seen.add((host, pid))
        out.append(f"{o.hexs(host)}\t{pid}\t{o.node_from(host, pid)}")
    return out


def layout_profiles() -> list[tuple[int, int, int]]:
    return [(n, s, 22 - n - s) for n in range(23) for s in range(23 - n)]


def layout_rows() -> list[str]:
    rng = o.SplitMix64(SEED_LAYOUT)
    out = []
    for n, s, m in layout_profiles():
        for snow in (0, V1_SNOW, o.MAX_SNOW, rng.next() >> 1, rng.next() >> 1, rng.next() >> 1):
            ts, node, seq, meta = o.layout_fields(n, s, m, snow)
            assert o.layout_pack(n, s, m, ts, node, seq, meta) == snow
            out.append(f"{n}\t{s}\t{m}\t{snow}\t{ts}\t{node}\t{seq}\t{meta}")
    return out


def layout_invalid_rows() -> list[str]:
    rows: list[tuple[str, tuple[int, ...]]] = []
    bad = [(10, 12, 1), (10, 11, 0), (23, 0, 0), (0, 0, 23), (22, 1, 0), (40, 0, 0), (7, 7, 7), (0, 0, 0)]
    for n, s, m in bad:
        rows.append(("L", (n, s, m, 0)))
        rows.append(("L", (n, s, m, 2**63)))  # LAYOUT before RANGE
        rows.append(("P", (n, s, m, 0, 0, 0, 0)))
        rows.append(("P", (n, s, m, 2**41, 0, 0, 0)))  # LAYOUT before RANGE
    for n, s, m in ((10, 12, 0), (6, 12, 4), (0, 0, 22), (22, 0, 0)):
        rows.append(("L", (n, s, m, 2**63)))
        rows.append(("L", (n, s, m, o.U64 - 1)))
        rows.append(("P", (n, s, m, 2**41, 0, 0, 0)))
        rows.append(("P", (n, s, m, 0, 2**n, 0, 0)))
        rows.append(("P", (n, s, m, 0, 0, 2**s, 0)))
        rows.append(("P", (n, s, m, 0, 0, 0, 2**m)))
        rows.append(("P", (n, s, m, o.U64 - 1, 0, 0, 0)))
    out = []
    for op, args in rows:
        r = o.layout_fields(*args) if op == "L" else o.layout_pack(*args)
        assert isinstance(r, o.Refused), (op, args)
        out.append(f"{op}\t" + "\t".join(map(str, args[:3])) + "\t" + ",".join(map(str, args[3:])) + f"\t{o.CLASS[r]}")
    return out


HEADER = "# generated by tools/vectorgen.py from tools/oracle.py -- do not edit; `make vectors` regenerates and diffs\n"


def write(path: pathlib.Path, columns: str, rows: list[str], note: str = "") -> None:
    text = HEADER + (f"# {note}\n" if note else "") + f"# {columns}\n" + "\n".join(rows) + "\n"
    path.write_text(text, encoding="utf-8", newline="\n")
    print(f"{path}: {len(rows)} rows")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(pathlib.Path(__file__).resolve().parent.parent / "vectors"))
    out = pathlib.Path(ap.parse_args().out)
    out.mkdir(parents=True, exist_ok=True)
    o.self_test()
    write(out / "valid.tsv", "ns\tsnow\tid\thash32\tunix_ms\tts\tnode\tseq", valid_rows(),
          f"rows 1..{BENCH_N} are the shared bench corpus (splitmix64 seed {SEED_VALID:#x}); the rest are boundaries")
    write(out / "invalid.tsv", "id_hex\tclass", invalid_rows(), "decode refusals; '-' is the empty input")
    write(out / "encode_invalid.tsv", "ns_hex\tsnow\tclass", encode_invalid_rows(),
          "encode refusals; snow may be >= 2^63")
    write(out / "node.tsv", "host_hex\tpid\tnode", node_rows(), "FNV-32a(host ++ decimal pid) & 1023")
    write(out / "layout.tsv", "n\ts\tm\tsnow\tts\tnode\tseq\tmeta", layout_rows(),
          "extension: layout profiles; every valid n+s+m=22; fields(snow) and pack(fields) == snow")
    write(out / "layout_invalid.tsv", "op\tn\ts\tm\targs\tclass", layout_invalid_rows(),
          "extension: layout refusals; op L args = snow, op P args = ts,node,seq,meta; LAYOUT before RANGE")


if __name__ == "__main__":
    main()
