"""champ_oracle.py — the branded champ (docs/structures/spec.md) as an executable specification.

Written from docs/structures/spec.md alone, never from an implementation, so agreement with it is
evidence. Obviously correct over fast: plain Python lists, a full copy of every node on the
write path, the masks recomputed from scratch in the invariant check.

    python3 tools/champ_oracle.py            # self-test (model, invariants, a mutant)

Every implementation replays vectors/champ.tsv (written by tools/vectorgen.py) and must
reproduce each row's size and shape digest.
"""

from __future__ import annotations

import sys
from dataclasses import dataclass, field

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import oracle as o  # noqa: E402

U64 = 2**64
MAX_LEVEL = 7  # levels 0..6 route by 5-bit fragments; level 7 is the collision list
C = 0xFF51AFD7ED558CCD
C_INV = pow(C, -1, U64)


def fragment(h: int, level: int) -> int:
    return (h >> (5 * level)) & 31


def popcount(x: int) -> int:
    return bin(x).count("1")


@dataclass
class Bitmap:
    datamap: int = 0
    nodemap: int = 0
    data: list[tuple[int, object]] = field(default_factory=list)  # ordered by bit
    children: list["Node"] = field(default_factory=list)  # ordered by bit


@dataclass
class Collision:
    pairs: list[tuple[int, object]]


Node = Bitmap | Collision
EMPTY = Bitmap()


# ── operations ──────────────────────────────────────────────────────────────
def get(node: Node, key: int, h: int, level: int = 0):
    if isinstance(node, Collision):
        for k, v in node.pairs:
            if k == key:
                return True, v
        return False, None
    b = 1 << fragment(h, level)
    if node.datamap & b:
        k, v = node.data[popcount(node.datamap & (b - 1))]
        return (True, v) if k == key else (False, None)
    if node.nodemap & b:
        return get(node.children[popcount(node.nodemap & (b - 1))], key, h, level + 1)
    return False, None


def merge(k1: int, v1, k2: int, v2, level: int) -> Node:
    """(k1, v1) is the stored pair, (k2, v2) the new one."""
    if level >= MAX_LEVEL:
        return Collision([(k1, v1), (k2, v2)])
    f1, f2 = fragment(o.hash32(k1), level), fragment(o.hash32(k2), level)
    if f1 == f2:
        return Bitmap(0, 1 << f1, [], [merge(k1, v1, k2, v2, level + 1)])
    pairs = [(k1, v1), (k2, v2)] if f1 < f2 else [(k2, v2), (k1, v1)]
    return Bitmap((1 << f1) | (1 << f2), 0, pairs, [])


def put(node: Node, key: int, value, h: int, level: int = 0, prepend: bool = True) -> Node:
    if isinstance(node, Collision):
        pairs = list(node.pairs)
        for i, (k, _) in enumerate(pairs):
            if k == key:
                pairs[i] = (key, value)  # replace in place
                return Collision(pairs)
        return Collision([(key, value)] + pairs if prepend else pairs + [(key, value)])
    b = 1 << fragment(h, level)
    if node.datamap & b:
        i = popcount(node.datamap & (b - 1))
        k0, v0 = node.data[i]
        data = list(node.data)
        if k0 == key:
            data[i] = (key, value)
            return Bitmap(node.datamap, node.nodemap, data, list(node.children))
        del data[i]
        child = merge(k0, v0, key, value, level + 1)
        children = list(node.children)
        children.insert(popcount(node.nodemap & (b - 1)), child)
        return Bitmap(node.datamap ^ b, node.nodemap | b, data, children)
    if node.nodemap & b:
        j = popcount(node.nodemap & (b - 1))
        children = list(node.children)
        children[j] = put(children[j], key, value, h, level + 1, prepend)
        return Bitmap(node.datamap, node.nodemap, list(node.data), children)
    data = list(node.data)
    data.insert(popcount(node.datamap & (b - 1)), (key, value))
    return Bitmap(node.datamap | b, node.nodemap, data, list(node.children))


def delete(node: Node, key: int, h: int, level: int = 0) -> Node:
    if isinstance(node, Collision):
        pairs = [(k, v) for k, v in node.pairs if k != key]
        if len(pairs) == len(node.pairs):
            return node
        return Collision(pairs) if pairs else EMPTY
    b = 1 << fragment(h, level)
    if node.datamap & b:
        i = popcount(node.datamap & (b - 1))
        if node.data[i][0] != key:
            return node
        data = list(node.data)
        del data[i]
        return Bitmap(node.datamap ^ b, node.nodemap, data, list(node.children))
    if node.nodemap & b:
        j = popcount(node.nodemap & (b - 1))
        child = delete(node.children[j], key, h, level + 1)
        lone = _lone_pair(child)
        if lone is not None:  # collapse: pull the survivor up inline
            data = list(node.data)
            data.insert(popcount(node.datamap & (b - 1)), lone)
            children = list(node.children)
            del children[j]
            return Bitmap(node.datamap | b, node.nodemap ^ b, data, children)
        children = list(node.children)
        children[j] = child
        return Bitmap(node.datamap, node.nodemap, list(node.data), children)
    return node


def _lone_pair(node: Node):
    if isinstance(node, Collision):
        return node.pairs[0] if len(node.pairs) == 1 else None
    if node.nodemap == 0 and popcount(node.datamap) == 1:
        return node.data[0]
    return None


def items(node: Node):
    if isinstance(node, Collision):
        yield from node.pairs
        return
    yield from node.data
    for child in node.children:
        yield from items(child)


# ── shape digest: FNV-1a-64 over the preorder serialization ─────────────────
def serialize(node: Node, out: bytearray) -> None:
    if isinstance(node, Collision):
        out += b"\x43" + len(node.pairs).to_bytes(4, "little")
        for k, _ in node.pairs:
            out += k.to_bytes(8, "little")
        return
    out += b"\x4e" + node.datamap.to_bytes(4, "little") + node.nodemap.to_bytes(4, "little")
    for k, _ in node.data:
        out += k.to_bytes(8, "little")
    for child in node.children:
        serialize(child, out)


def fnv1a64(data: bytes) -> int:
    h = 0xCBF29CE484222325
    for byte in data:
        h = ((h ^ byte) * 0x100000001B3) % U64
    return h


def digest(node: Node) -> str:
    buf = bytearray()
    serialize(node, buf)
    return f"{fnv1a64(bytes(buf)):016x}"


# ── the trie as a whole ─────────────────────────────────────────────────────
class Champ:
    """One namespace's trie with its size; `prepend=False` is the append mutant."""

    def __init__(self, prepend: bool = True) -> None:
        self.root: Node = EMPTY
        self.size = 0
        self.prepend = prepend

    def get(self, key: int):
        return get(self.root, key, o.hash32(key))

    def put(self, key: int, value) -> None:
        if not self.get(key)[0]:
            self.size += 1
        self.root = put(self.root, key, value, o.hash32(key), 0, self.prepend)

    def delete(self, key: int) -> None:
        if self.get(key)[0]:
            self.size -= 1
        self.root = delete(self.root, key, o.hash32(key))

    def digest(self) -> str:
        return digest(self.root)


# ── programs: explicit and SplitMix64 streams ───────────────────────────────
def stream_program(seed: int, ops: int, keys: int) -> tuple[list[int], list[tuple[str, int]]]:
    """The pool and the program for a `stream` row, per docs/structures/spec.md."""
    rng = o.SplitMix64(seed ^ 0xD1B54A32D192ED03)
    pool = [rng.next() >> 1 for _ in range(keys)]
    rng = o.SplitMix64(seed)
    program = []
    for _ in range(ops):
        r = rng.next()
        k = pool[(r & 0xFFFFFFFF) % keys]
        program.append(("-" if r >> 62 == 3 else "+", k))
    return pool, program


def parse_program(text: str) -> list[tuple[str, int]]:
    return [(step[0], int(step[1:])) for step in text.split(",")]


def run(program: list[tuple[str, int]], prepend: bool = True) -> tuple[Champ, dict[int, int]]:
    """Replays a program; the value put by step i is i. Returns the trie and its model."""
    champ, model = Champ(prepend), {}
    for i, (op, k) in enumerate(program):
        if op == "+":
            champ.put(k, i)
            model[k] = i
        else:
            champ.delete(k)
            model.pop(k, None)
    return champ, model


# ── constructing keys by hash (f is a bijection on 64 bits) ─────────────────
def _g(y: int) -> int:
    return y ^ (y >> 33)


def f(k: int) -> int:
    return _g((C * _g(k)) % U64)


def f_inv(y: int) -> int:
    return _g((C_INV * _g(y)) % U64)


def keys_with_hash(low32: int, count: int, start: int = 1) -> list[int]:
    """`count` distinct keys below 2^63 whose hash32 is exactly `low32`."""
    out, hi = [], start
    while len(out) < count:
        k = f_inv((hi << 32) | low32)
        if k <= o.MAX_SNOW:
            out.append(k)
        hi += 1
    return out


# ── self-test ───────────────────────────────────────────────────────────────
def check_invariants(node: Node, level: int = 0) -> int:
    """Asserts the canonical form below the root; returns the entry count."""
    if isinstance(node, Collision):
        assert level == MAX_LEVEL and len(node.pairs) >= 2, (level, node)
        assert len({o.hash32(k) for k, _ in node.pairs}) == 1
        return len(node.pairs)
    assert node.datamap & node.nodemap == 0
    assert popcount(node.datamap) == len(node.data) and popcount(node.nodemap) == len(node.children)
    bits = [i for i in range(32) if node.datamap >> i & 1]
    assert [fragment(o.hash32(k), level) for k, _ in node.data] == bits
    n = len(node.data) + sum(check_invariants(c, level + 1) for c in node.children)
    if level > 0:
        assert not (node.nodemap == 0 and len(node.data) <= 1), ("not canonical", level, node)
    return n


def self_test() -> None:
    # f really is hash32's 64-bit core, and f_inv inverts it.
    for k in (0, 1, 274557032793636864, o.MAX_SNOW, 0xDEADBEEF):
        assert f(k) % 2**32 == o.hash32(k) and f_inv(f(k)) == k
    # A stream against the dict model, with the canonical form checked after every step.
    pool, program = stream_program(42, 3000, 400)
    champ, model = Champ(), {}
    for i, (op, k) in enumerate(program):
        if op == "+":
            champ.put(k, i)
            model[k] = i
        else:
            champ.delete(k)
            model.pop(k, None)
        assert check_invariants(champ.root) == champ.size == len(model)
    for k in pool:
        assert champ.get(k) == ((True, model[k]) if k in model else (False, None))
    # Full-hash collisions: prepend on a new key, replace in place, collapse on delete.
    a, b, c = keys_with_hash(0x12345678, 3)
    t, _ = run([("+", a), ("+", b), ("+", c)])
    node = t.root
    while isinstance(node, Bitmap):
        node = node.children[0]
    assert [k for k, _ in node.pairs] == [c, a, b]
    t, model = run([("+", a), ("+", b), ("+", c), ("+", b)])
    assert t.get(b) == (True, 3) and t.size == 3
    t, _ = run([("+", a), ("+", b), ("-", a)])
    assert isinstance(t.root, Bitmap) and t.root.data == [(b, 1)] and t.root.nodemap == 0
    # The append mutant must be caught by the triple-collision digest.
    good, _ = run([("+", a), ("+", b), ("+", c)])
    bad, _ = run([("+", a), ("+", b), ("+", c)], prepend=False)
    assert good.digest() != bad.digest()


if __name__ == "__main__":
    self_test()
    print("champ_oracle: self-test ok (model, canonical form, collisions, append mutant caught)")
