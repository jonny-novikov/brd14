"""parity.py — differential parity: every implementation vs the oracle.

Each tree ships a *shim* (docs/contract.md § Parity shim protocol). This driver
builds the shims, generates one deterministic request set — uniform values,
boundaries, every byte substituted at every position, every length 0..20,
multi-fault precedence probes — feeds each shim the requests it declares, and
diffs every response line against the oracle.

    python3 tools/parity.py                # all available shims
    python3 tools/parity.py --only go,c-   # name prefixes
    python3 tools/parity.py --require      # a missing shim is a failure (CI)
    python3 tools/parity.py --self-test    # the harness must pass the oracle and catch a mutant
    python3 tools/parity.py --serve-oracle # act as a shim (used by --self-test)

Stdlib only. Requests go through files, never pipes, so a slow shim cannot
deadlock the driver.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(HERE))
import oracle as o  # noqa: E402

SEED = 0x0B4D14_00FF


# ── the shim registry ───────────────────────────────────────────────────────
# name, tree to `make conform` in (or None), argv, extra env. A shim is
# "available" when its first argv element resolves (a file under ROOT, or a
# command on PATH) after the build step.
def registry() -> list[dict]:
    py_env = {"PYTHONPATH": str(ROOT / "python" / "src")}
    ex_ebin = "ex/echo_data/_build/prod/lib/echo_data/ebin"
    return [
        {"name": "go", "tree": "go", "argv": ["build/shims/go-conform"]},
        {"name": "c-speed", "tree": "native/c", "argv": ["native/c/build/conform-speed"]},
        {"name": "c-memory", "tree": "native/c", "argv": ["native/c/build/conform-memory"]},
        {"name": "rust-speed", "tree": "native/rust", "argv": ["native/rust/target/release/brd14-conform", "speed"]},
        {"name": "rust-memory", "tree": "native/rust", "argv": ["native/rust/target/release/brd14-conform", "memory"]},
        {"name": "python-3.14", "tree": None, "argv": ["python3.14", "python/conform.py"], "env": py_env},
        {"name": "python-3.14t", "tree": None, "argv": ["python3.14t", "-X", "gil=0", "python/conform.py"], "env": py_env},
        {"name": "python-3.12", "tree": None, "argv": ["python3.12", "python/conform.py"], "env": py_env},
        {"name": "ts-pure-node", "tree": "ts", "argv": ["node", "ts/conform/pure.ts"]},
        {"name": "ts-pure-bun", "tree": "ts", "argv": ["bun", "ts/conform/pure.ts"]},
        {"name": "ts-wasm-node", "tree": "ts", "argv": ["node", "ts/conform/wasm.ts"]},
        {"name": "ts-wasm-bun", "tree": "ts", "argv": ["bun", "ts/conform/wasm.ts"]},
        {"name": "sh-bash", "tree": None, "argv": ["bash", "scripts/brd.sh", "conform"]},
        {"name": "ex-pure", "tree": "ex", "argv": ["elixir", "-pa", ex_ebin, "ex/echo_data/conform.exs"],
         "env": {"ECHO_DATA_NATIVE": "0"}},
    ]


def available(shim: dict) -> bool:
    exe = shim["argv"][0]
    if "/" in exe:
        if not (ROOT / exe).exists():
            return False
    elif shutil.which(exe) is None:
        return False
    # interpreter shims: the script must exist too
    script = next((a for a in shim["argv"][1:] if a.endswith((".py", ".ts", ".exs"))), None)
    return script is None or (ROOT / script).exists()


# ── requests ────────────────────────────────────────────────────────────────
def requests(scale: int) -> list[str]:
    rng = o.SplitMix64(SEED)
    reqs: list[str] = []

    def E(ns: bytes, snow: int) -> None:
        reqs.append(f"E {o.hexs(ns)} {snow}")

    def D(id_: bytes) -> None:
        reqs.append(f"D {o.hexs(id_)}")

    boundaries = [0, 1, 61, 62, 3843, 3844, o.MAX_SNOW - 1, o.MAX_SNOW, 2**63, 2**63 + 1, o.U64 - 1,
                  1 << 22, (1 << 41) - 1, ((1 << 41) - 1) << 22]
    for k in range(1, 11):
        boundaries += [62**k - 1, 62**k, 62**k + 1]

    # E — valid, boundaries, hostile namespaces, out-of-range values
    for _ in range(4000 * scale):
        E(rng.ns(), rng.next() >> 1)
    for snow in boundaries:
        E(b"USR", snow)
    for _ in range(1000 * scale):
        E(rng.bytes(rng.below(6)), rng.next() >> rng.below(2))
    for _ in range(500 * scale):
        E(rng.ns(), 2**63 + rng.below(2**63))

    # D — valid ids, every byte at every position, lengths, range edges, noise
    for _ in range(4000 * scale):
        id_ = o.encode(rng.ns(), rng.next() >> 1)
        D(id_)
    for seed in (b"USR0KHTOWnGLuC", b"ZZZAzL8n0Y58m7", b"ABC00000000000", b"SESzzzzzzzzzzz"):
        for pos in range(o.LEN):
            for byte in range(256):
                b = bytearray(seed)
                b[pos] = byte
                D(bytes(b))
        for n in range(0, 21):
            D((seed * 2)[:n])
    top = o.encode(b"RNG", o.MAX_SNOW)
    for delta in range(-64, 65):
        v = o.MAX_SNOW + delta
        if v < 0:
            continue
        digits = []
        for _ in range(o.PAYLOAD_LEN):
            v, r = divmod(v, 62)
            digits.append(o.ALPHABET[r])
        if v == 0:
            D(top[:3] + bytes(reversed(digits)))
    for _ in range(1000 * scale):
        D(rng.bytes(rng.below(21)))
    for _ in range(500 * scale):  # multi-fault: lowercase ns + random payload bytes
        D(bytes(c | 0x20 for c in rng.ns()) + rng.bytes(11))

    # H, U, F — full u64 for the hash, domain values for the readers
    for k in boundaries:
        reqs.append(f"H {k}")
    for _ in range(2000 * scale):
        reqs.append(f"H {rng.next()}")
    for _ in range(1000 * scale):
        s = rng.next() >> 1
        reqs.append(f"U {s}")
        reqs.append(f"F {s}")
    for s in (0, 1, (1 << 22) - 1, 1 << 22, o.MAX_SNOW):
        reqs.append(f"U {s}")
        reqs.append(f"F {s}")

    # N — node derivation over arbitrary host bytes
    for host, pid in ((b"hosta", 100), (b"", 100), (b"", 0), ("хост".encode(), 2**31 - 1)):
        reqs.append(f"N {o.hexs(host)} {pid}")
    for _ in range(1000 * scale):
        reqs.append(f"N {o.hexs(rng.bytes(rng.below(48)))} {rng.below(2**31)}")
    return reqs


def answer(req: str, mutant: bool = False) -> str:
    """The oracle's response line for one request."""
    op, *args = req.split(" ")
    if op == "E":
        r = o.encode(o.unhex(args[0]), int(args[1]))
        if isinstance(r, int):
            return f"ERR {o.CLASS[r]}"
        if mutant:  # a pin-evading permutation: swap two alphabet chars
            r = r.replace(b"q", b"\x00").replace(b"r", b"q").replace(b"\x00", b"r")
        return f"OK {r.decode()}"
    if op == "D":
        r = o.decode(o.unhex(args[0]))
        return f"ERR {o.CLASS[r]}" if isinstance(r, int) else f"OK {r[0].decode()} {r[1]}"
    if op == "H":
        return f"OK {o.hash32(int(args[0]))}"
    if op == "U":
        return f"OK {o.unix_ms(int(args[0]))}"
    if op == "F":
        return "OK " + " ".join(map(str, o.fields(int(args[0]))))
    if op == "N":
        return f"OK {o.node_from(o.unhex(args[0]), int(args[1]))}"
    raise ValueError(f"unknown request {req!r}")


def serve_oracle(mutant: bool) -> None:
    out = sys.stdout
    out.write(f"HELLO oracle {'mutant' if mutant else 'python'} EDHUFN\n")
    for line in sys.stdin:
        line = line.rstrip("\n")
        if line:
            out.write(answer(line, mutant) + "\n")


# ── running ─────────────────────────────────────────────────────────────────
def build(trees: set[str]) -> None:
    for tree in sorted(trees):
        mk = ROOT / tree / "Makefile"
        if mk.exists() and "conform:" in mk.read_text():
            print(f"build: make -C {tree} conform", file=sys.stderr)
            subprocess.run(["make", "-s", "-C", str(ROOT / tree), "conform"], check=True)


def run_shim(shim: dict, reqs: list[str], expected: list[str], workdir: pathlib.Path) -> dict:
    env = {**os.environ, **shim.get("env", {})}
    argv = [str(ROOT / a) if "/" in a and (ROOT / a).exists() and i == 0 else a
            for i, a in enumerate(shim["argv"])]
    hello = subprocess.run(argv, cwd=ROOT, env=env, input="", capture_output=True, text=True, timeout=120)
    first = hello.stdout.splitlines()[0] if hello.stdout else ""
    if not first.startswith("HELLO "):
        return {"name": shim["name"], "status": "BROKEN", "detail": f"no HELLO line: {first!r} {hello.stderr[-400:]!r}"}
    parts = first.split()
    ops = set(parts[3]) if len(parts) > 3 else set("EDHUFN")
    idx = [i for i, r in enumerate(reqs) if r[0] in ops]
    req_file = workdir / f"{shim['name']}.req"
    resp_file = workdir / f"{shim['name']}.resp"
    req_file.write_text("".join(reqs[i] + "\n" for i in idx))
    t0 = time.perf_counter()
    with req_file.open() as fin, resp_file.open("w") as fout:
        proc = subprocess.run(argv, cwd=ROOT, env=env, stdin=fin, stdout=fout, stderr=subprocess.PIPE,
                              text=True, timeout=1800)
    dt = time.perf_counter() - t0
    lines = resp_file.read_text().splitlines()
    got = lines[1:] if lines and lines[0].startswith("HELLO ") else lines
    mismatches = []
    for j, i in enumerate(idx):
        g = got[j] if j < len(got) else "<missing>"
        if g != expected[i]:
            mismatches.append({"request": reqs[i], "want": expected[i], "got": g})
    extra = max(0, len(got) - len(idx))
    ok = proc.returncode == 0 and not mismatches and extra == 0
    return {"name": shim["name"], "impl": parts[1], "variant": parts[2], "ops": "".join(sorted(ops)),
            "requests": len(idx), "mismatches": len(mismatches), "extra_lines": extra,
            "exit": proc.returncode, "seconds": round(dt, 3), "status": "PASS" if ok else "FAIL",
            "first": mismatches[:20], "stderr": proc.stderr[-400:] if proc.returncode else ""}


def describe(req: str) -> str:
    op, *args = req.split(" ")
    if op == "D":
        return f"{req}   ({o.unhex(args[0])!r})"
    if op == "E":
        return f"{req}   (ns={o.unhex(args[0])!r})"
    if op == "N":
        return f"{req}   (host={o.unhex(args[0])!r})"
    return req


def report(results: list[dict]) -> None:
    print(f"\n{'shim':<16} {'impl/variant':<20} {'ops':<7} {'requests':>9} {'mismatch':>9} {'req/s':>10}  status")
    for r in results:
        if r["status"] in ("MISSING", "BROKEN"):
            print(f"{r['name']:<16} {'':<20} {'':<7} {'':>9} {'':>9} {'':>10}  {r['status']} {r.get('detail', '')}")
            continue
        rate = r["requests"] / r["seconds"] if r["seconds"] else 0
        print(f"{r['name']:<16} {r['impl'] + '/' + r['variant']:<20} {r['ops']:<7} {r['requests']:>9} "
              f"{r['mismatches']:>9} {rate:>10.0f}  {r['status']}")
        for m in r["first"]:
            print(f"    {describe(m['request'])}\n      want {m['want']}\n      got  {m['got']}")
        if r.get("stderr"):
            print(f"    stderr: {r['stderr']}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma-separated shim name prefixes")
    ap.add_argument("--scale", type=int, default=1, help="request volume multiplier")
    ap.add_argument("--require", action="store_true", help="fail when a registered shim is unavailable")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--json", default="", help="write the result matrix as JSON")
    ap.add_argument("--self-test", action="store_true")
    ap.add_argument("--serve-oracle", action="store_true")
    ap.add_argument("--mutant", action="store_true")
    a = ap.parse_args()

    if a.serve_oracle:
        serve_oracle(a.mutant)
        return 0

    o.self_test()
    reqs = requests(a.scale)
    expected = [answer(r) for r in reqs]
    print(f"parity: {len(reqs)} requests (seed {SEED:#x}, scale {a.scale})", file=sys.stderr)

    if a.self_test:
        me = [sys.executable, str(HERE / "parity.py"), "--serve-oracle"]
        shims = [{"name": "oracle", "tree": None, "argv": me},
                 {"name": "oracle-mutant", "tree": None, "argv": me + ["--mutant"]}]
    else:
        prefixes = [p for p in a.only.split(",") if p]
        shims = [s for s in registry() if not prefixes or any(s["name"].startswith(p) for p in prefixes)]
        if not a.no_build:
            build({s["tree"] for s in shims if s["tree"]})

    results = []
    with tempfile.TemporaryDirectory(prefix="brd14-parity-") as tmp:
        for s in shims:
            if not available(s):
                results.append({"name": s["name"], "status": "MISSING"})
                continue
            results.append(run_shim(s, reqs, expected, pathlib.Path(tmp)))
    report(results)
    if a.json:
        pathlib.Path(a.json).parent.mkdir(parents=True, exist_ok=True)
        pathlib.Path(a.json).write_text(json.dumps({"seed": SEED, "scale": a.scale, "requests": len(reqs),
                                                    "results": results}, indent=2))

    if a.self_test:
        good, bad = results
        if good["status"] != "PASS" or bad["status"] != "FAIL" or bad["mismatches"] == 0:
            print("\nself-test FAILED: the harness must pass the oracle and catch the mutant", file=sys.stderr)
            return 1
        print(f"\nself-test ok: oracle passes, mutant caught on {bad['mismatches']} requests", file=sys.stderr)
        return 0

    failed = [r for r in results if r["status"] in ("FAIL", "BROKEN") or (a.require and r["status"] == "MISSING")]
    passed = [r for r in results if r["status"] == "PASS"]
    print(f"\nparity: {len(passed)} pass, {len(failed)} fail, "
          f"{sum(r['status'] == 'MISSING' for r in results)} missing", file=sys.stderr)
    return 1 if failed or not passed else 0


if __name__ == "__main__":
    sys.exit(main())
