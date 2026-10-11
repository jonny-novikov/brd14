"""doclint.py — the KAN documentation contract, checked.

Every page of the documentation corpus must carry:

  * YAML frontmatter with the fields in this order: id, slug, type, version, path, title, summary,
    tags, group, language, audience. `id` is a brd14 id in the KAN namespace (decoded and range-
    checked by the oracle, unique across the corpus); `slug` is unique; `type` is one of
    instructions | index | example | aus | guide; `version` is a quoted "major.minor"; `path` is
    the page's real repository path; `tags` and `audience` are non-empty lists of strings.
  * `<a id="toc"></a>` followed by an "In this document" list whose entries link the page's own
    explicit anchors — one per `##` section, each section preceded by `<a id="…"></a>`.
  * A navigation line linking the documentation index (`docs/index.md#toc`), except on the index.
  * Links that resolve: every relative path exists, every fragment names an anchor in its target
    (an explicit `<a id>` or a heading's GitHub slug).

The corpus is docs/**, the root README/AGENTS/CLAUDE and bench/README.md. Package READMEs
(go/, python/, ts/packages/*, ex/echo_data/, native/**) are rendered by registries — pkg.go.dev,
npm, PyPI, Hex — and stay plain Markdown; their links are still checked.

    python3 tools/doclint.py            # the whole corpus; exit 1 on any finding
    python3 tools/doclint.py FILE...    # just these
"""

from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "tools"))
import oracle as o  # noqa: E402

FIELDS = ["id", "slug", "type", "version", "path", "title", "summary", "tags", "group", "language", "audience"]
TYPES = {"instructions", "index", "example", "aus", "guide"}
CORPUS_GLOBS = ["docs/**/*.md", "README.md", "AGENTS.md", "CLAUDE.md", "bench/README.md"]
LINKS_ONLY_GLOBS = ["go/README.md", "python/README.md", "ts/packages/*/README.md", "ex/echo_data/README.md"]
INDEX = ROOT / "docs" / "index.md"


def corpus() -> list[pathlib.Path]:
    seen: list[pathlib.Path] = []
    for g in CORPUS_GLOBS:
        for p in sorted(ROOT.glob(g)):
            if p not in seen:
                seen.append(p)
    return seen


def links_only() -> list[pathlib.Path]:
    return [p for g in LINKS_ONLY_GLOBS for p in sorted(ROOT.glob(g))]


def strip_code(text: str) -> str:
    text = re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)
    return re.sub(r"`[^`\n]*`", "", text)


def gh_slug(heading: str) -> str:
    s = re.sub(r"`", "", heading.strip().lower())
    s = re.sub(r"[^\w\- ]", "", s)
    return s.replace(" ", "-")


def anchors(path: pathlib.Path, _cache: dict = {}) -> set[str]:
    if path not in _cache:
        text = path.read_text(encoding="utf-8")
        ids = set(re.findall(r'<a id="([^"]+)"', text))
        unfenced = re.sub(r"^```.*?^```", "", text, flags=re.S | re.M)  # headings keep inline code
        ids |= {gh_slug(h) for h in re.findall(r"^#{1,6} (.+)$", unfenced, re.M)}
        _cache[path] = ids
    return _cache[path]


def parse_frontmatter(text: str) -> tuple[list[tuple[str, str]], str] | None:
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return None
    pairs = []
    for line in m.group(1).splitlines():
        k, sep, v = line.partition(":")
        if not sep:
            pairs.append(("", line))
            continue
        pairs.append((k.strip(), v.strip()))
    return pairs, text[m.end():]


def scalar(v: str) -> str | None:
    m = re.fullmatch(r'"((?:[^"\\]|\\.)*)"', v)
    return m.group(1) if m else None


def str_list(v: str) -> list[str] | None:
    m = re.fullmatch(r"\[(.*)\]", v)
    if not m:
        return None
    items = re.findall(r'"((?:[^"\\]|\\.)*)"\s*(?:,|$)', m.group(1).strip())
    return items or None


def check_links(path: pathlib.Path, body: str, problems: list[str]) -> None:
    rel = path.relative_to(ROOT)
    for m in re.finditer(r"\]\(([^)\s]+)\)", strip_code(body)):
        link = m.group(1)
        if re.match(r"[a-z]+:", link):
            continue
        target_s, _, frag = link.partition("#")
        target = (path.parent / target_s).resolve() if target_s else path
        if not target.exists():
            problems.append(f"{rel}: link to a missing path: {link}")
        elif frag and target.suffix == ".md" and frag not in anchors(target):
            problems.append(f"{rel}: link to a missing anchor: {link}")


def check_page(path: pathlib.Path, ids: dict, slugs: dict, problems: list[str]) -> None:
    rel = path.relative_to(ROOT)
    text = path.read_text(encoding="utf-8")
    parsed = parse_frontmatter(text)
    if parsed is None:
        problems.append(f"{rel}: no YAML frontmatter")
        return
    pairs, body = parsed
    keys = [k for k, _ in pairs]
    if keys != FIELDS:
        problems.append(f"{rel}: frontmatter fields {keys} — want exactly {FIELDS}, in order")
        return
    fm = dict(pairs)
    for k in ("id", "slug", "type", "version", "path", "title", "summary", "group", "language"):
        if not scalar(fm[k]):
            problems.append(f"{rel}: frontmatter {k} must be a non-empty double-quoted string")
    for k in ("tags", "audience"):
        if str_list(fm[k]) is None:
            problems.append(f'{rel}: frontmatter {k} must be a non-empty list of quoted strings')
    id_ = scalar(fm["id"]) or ""
    r = o.decode(id_.encode())
    if isinstance(r, int):
        problems.append(f"{rel}: id {id_!r} is not a valid brd14 id ({o.CLASS[r]})")
    elif r[0] != b"KAN":
        problems.append(f"{rel}: id {id_!r} is not in the KAN namespace")
    if id_ in ids:
        problems.append(f"{rel}: id {id_} also identifies {ids[id_]}")
    ids[id_] = rel
    slug = scalar(fm["slug"]) or ""
    if slug in slugs:
        problems.append(f"{rel}: slug {slug} also names {slugs[slug]}")
    slugs[slug] = rel
    if (scalar(fm["type"]) or "") not in TYPES:
        problems.append(f"{rel}: type must be one of {sorted(TYPES)}")
    if not re.fullmatch(r"\d+\.\d+", scalar(fm["version"]) or ""):
        problems.append(f'{rel}: version must be a quoted "major.minor"')
    if scalar(fm["path"]) != str(rel):
        problems.append(f"{rel}: path says {fm['path']}")

    # toc, explicit anchors, contents
    if '<a id="toc"></a>' not in body:
        problems.append(f'{rel}: no <a id="toc"></a>')
        return
    after_toc = body.split('<a id="toc"></a>', 1)[1]
    m = re.search(r"\n## In this document\n\n((?:- \[.*\]\(#[^)]+\)\n)+)", after_toc)
    if not m:
        problems.append(f'{rel}: <a id="toc"></a> is not followed by an "## In this document" list')
        return
    listed = re.findall(r"\]\(#([^)]+)\)", m.group(1))
    sections = []
    lines = strip_code(after_toc[m.end():]).split("\n")
    for i, line in enumerate(lines):
        if line.startswith("## "):
            prev = next((lines[j] for j in range(i - 1, -1, -1) if lines[j].strip()), "")
            a = re.fullmatch(r'<a id="([^"]+)"></a>', prev.strip())
            if not a:
                problems.append(f"{rel}: section {line!r} has no explicit <a id> anchor before it")
            else:
                sections.append(a.group(1))
    if listed != sections:
        problems.append(f"{rel}: contents {listed} != section anchors {sections}")
    if path != INDEX and not re.search(r"\]\((?:\.\./)*(?:docs/)?index\.md#toc\)", body):
        problems.append(f"{rel}: no navigation link to the documentation index (index.md#toc)")
    check_links(path, body, problems)


def main(argv: list[str]) -> int:
    pages = [ROOT / a for a in argv] if argv else corpus()
    problems: list[str] = []
    ids: dict = {}
    slugs: dict = {}
    for p in pages:
        check_page(p.resolve(), ids, slugs, problems)
    if not argv:
        for p in links_only():
            check_links(p, p.read_text(encoding="utf-8"), problems)
    for line in problems:
        print(line)
    print(f"doclint: {len(pages)} pages, {len(problems)} finding(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
