"""run.py — the storage probe behind docs/articles/namespaces-and-storage.md.

Every number in that article is read from the results.json this script writes,
or is marked as cited. The probe is reproducible and self-cleaning: it starts
its own PostgreSQL 16 cluster and its own Redis 7 server in a temporary
directory, measures, and removes both.

    python3 tools/storage_probe/run.py                 # full run, N = 1,000,000
    python3 tools/storage_probe/run.py --n 20000       # quick smoke run
    python3 tools/storage_probe/run.py --only pg,redis # a subset of sections

Sections (each is skipped, with the reason recorded, when its binary is absent):

  pg      PostgreSQL 16: pg_column_size per type; heap and B-tree bytes per
          row for N rows of each id representation inserted in mint order;
          pageinspect heap and index tuple lengths (MAXALIGN); collation
          behaviour: "C" vs ICU ordering, a nondeterministic case-insensitive
          collation against a UNIQUE index, LIKE and index use.
  redis   Redis 7: MEMORY USAGE of a 14- vs 16-byte key, and used_memory per
          key over N keys of each width (jemalloc size classes).
  sqlite  SQLite via the sqlite3 module: database bytes per row for N rows as
          INTEGER PRIMARY KEY, TEXT/BLOB PRIMARY KEY WITHOUT ROWID (14 vs 16),
          and a rowid table with a TEXT PRIMARY KEY.
  memory  In-process strings, 14 vs 16 bytes: Go (gomem/), CPython 3.14 and
          3.14t (pymem.py), Node 24 and Bun (jsmem.js).

Standard library only. The id corpus is deterministic: N consecutive brd14
snowflakes from the contract's V-1 vector onward, 64 per millisecond on node
585 (the N-1 vector), branded USR; the 15- and 16-byte rows are the same
payloads in the reserved brd15 shape (4-letter namespace USER + payload) and
brd16 shape (USER + metadata digit A + payload).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import platform
import shutil
import socket
import sqlite3
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
PGBIN = os.environ.get("BRD14_PGBIN", "/usr/lib/postgresql/16/bin")

# Each section registers itself here as name -> (results key, probe function).
# A probe function takes (corpus, workdir) and returns a JSON-serialisable dict.
SECTIONS: dict[str, tuple[str, object]] = {}

# --------------------------------------------------------------------------- corpus

ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
EPOCH_MS = 1_704_067_200_000
V1_SNOW = 274557032793636864  # contract vector V-1: USR0KHTOWnGLuC
NODE = 585  # contract vector N-1: node_from("hosta", 100)
IDS_PER_MS = 64
NS3, NS4, META = "USR", "USER", "A"


def payload(snow: int) -> str:
    out = []
    for _ in range(11):
        snow, r = divmod(snow, 62)
        out.append(ALPHABET[r])
    return "".join(reversed(out))


def ns_index(ns: str) -> int:
    """A-Z letters as a base-26 number: USR -> 14005 (fits smallint)."""
    v = 0
    for ch in ns:
        v = v * 26 + (ord(ch) - ord("A"))
    return v


def snowflake(i: int) -> int:
    ts = (V1_SNOW >> 22) + i // IDS_PER_MS
    return (ts << 22) | (NODE << 12) | (i % IDS_PER_MS)


def uuid_packed(snow: int) -> str:
    """4-letter namespace (19 bits) | 6-bit metadata | 63-bit snowflake, in 128."""
    v = (ns_index(NS4) << 69) | (ALPHABET.index(META) << 63) | snow
    h = f"{v:032x}"
    return f"{h[:8]}-{h[8:12]}-{h[12:16]}-{h[16:20]}-{h[20:]}"


class Corpus:
    def __init__(self, n: int):
        t0 = time.time()
        self.n = n
        self.snows = [snowflake(i) for i in range(n)]
        self.id14 = [NS3 + payload(s) for s in self.snows]
        self.id15 = [NS4 + s[3:] for s in self.id14]  # the reserved brd15 shape
        self.id16 = [NS4 + META + s[3:] for s in self.id14]  # the reserved brd16 shape
        self.seconds = time.time() - t0

    def describe(self) -> dict:
        return {
            "n": self.n,
            "first_snowflake": self.snows[0],
            "last_snowflake": self.snows[-1],
            "first_id14": self.id14[0],
            "last_id14": self.id14[-1],
            "first_id15": self.id15[0],
            "first_id16": self.id16[0],
            "ids_per_ms": IDS_PER_MS,
            "node": NODE,
            "span_ms": (self.snows[-1] >> 22) - (self.snows[0] >> 22) + 1,
            "generation_seconds": round(self.seconds, 2),
            "brd15_shape": "4-letter namespace + 11-digit payload",
            "brd16_shape": "4-letter namespace + 1 metadata digit + 11-digit payload (namespace-adjacent placement)",
            "uuid_packing": "ns4 index (19 bits) << 69 | meta (6 bits) << 63 | snowflake (63 bits)",
        }


def ids62() -> list[tuple[int, str]]:
    """62 consecutive snowflakes whose last payload digit walks the whole alphabet."""
    base = (V1_SNOW // 62) * 62
    return [(s, NS3 + payload(s)) for s in range(base, base + 62)]


# --------------------------------------------------------------------------- helpers

def which(name: str) -> str | None:
    return shutil.which(name)


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def host_info() -> dict:
    mem_kb = None
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    mem_kb = int(line.split()[1])
    except OSError:
        pass
    return {
        "platform": platform.platform(),
        "machine": platform.machine(),
        "cpus": os.cpu_count(),
        "mem_total_mb": mem_kb // 1024 if mem_kb else None,
        "python": sys.version.split()[0],
    }


# --------------------------------------------------------------------------- PostgreSQL

PG_REPRESENTATIONS = [
    # name, column definition(s), expression over src
    ("bigint", "id bigint PRIMARY KEY", "snow"),
    ("text14", 'id text COLLATE "C" PRIMARY KEY', "id14"),
    ("text15", 'id text COLLATE "C" PRIMARY KEY', "id15"),
    ("text16", 'id text COLLATE "C" PRIMARY KEY', "id16"),
    ("varchar14", 'id varchar(14) COLLATE "C" PRIMARY KEY', "id14"),
    ("varchar16", 'id varchar(16) COLLATE "C" PRIMARY KEY', "id16"),
    ("char14", 'id char(14) COLLATE "C" PRIMARY KEY', "id14"),
    ("char16", 'id char(16) COLLATE "C" PRIMARY KEY', "id16"),
    ("bytea14", "id bytea PRIMARY KEY", "convert_to(id14, 'SQL_ASCII')"),
    ("bytea16", "id bytea PRIMARY KEY", "convert_to(id16, 'SQL_ASCII')"),
    ("uuid", "id uuid PRIMARY KEY", "u"),
    ("comp_char3", 'ns char(3) COLLATE "C" NOT NULL, snow bigint NOT NULL, PRIMARY KEY (ns, snow)', "left(id14, 3), snow"),
    ("comp_smallint", "ns smallint NOT NULL, snow bigint NOT NULL, PRIMARY KEY (ns, snow)", f"{ns_index(NS3)}::smallint, snow"),
    ("text14_icu", 'id text COLLATE "und-x-icu" PRIMARY KEY', "id14"),
]


class Postgres:
    def __init__(self, workdir: str):
        self.root = os.path.join(workdir, "pg")
        self.data = os.path.join(self.root, "data")
        self.sock = os.path.join(self.root, "sock")
        self.log: list[dict] = []
        self.as_pg = ["runuser", "-u", "postgres", "--"] if os.geteuid() == 0 else []

    def _own(self, path: str) -> None:
        if os.geteuid() == 0:
            shutil.chown(path, "postgres", "postgres")

    def start(self) -> None:
        # mkdtemp creates the work directory 0700; the postgres user must traverse it.
        os.chmod(os.path.dirname(self.root), 0o755)
        os.makedirs(self.data, mode=0o700)
        os.makedirs(self.sock)
        for p in (self.root, self.data, self.sock):
            self._own(p)
        r = run(self.as_pg + [f"{PGBIN}/initdb", "-D", self.data, "-U", "postgres",
                              "--auth=trust", "--locale=C.UTF-8", "--encoding=UTF8"])
        if r.returncode:
            raise RuntimeError(f"initdb failed: {r.stderr[-800:]}")
        opts = " ".join([
            "-c listen_addresses=''", f"-c unix_socket_directories={self.sock}",
            "-c fsync=off", "-c synchronous_commit=off", "-c full_page_writes=off",
            "-c shared_buffers=512MB", "-c maintenance_work_mem=256MB", "-c work_mem=128MB",
            "-c max_wal_size=4GB", "-c checkpoint_timeout=30min", "-c autovacuum=off",
            "-c wal_level=minimal", "-c max_wal_senders=0",
        ])
        r = run(self.as_pg + [f"{PGBIN}/pg_ctl", "-D", self.data, "-o", opts,
                              "-l", os.path.join(self.root, "postgres.log"), "-w", "start"])
        if r.returncode:
            raise RuntimeError(f"pg_ctl start failed: {r.stdout[-400:]} {r.stderr[-800:]}")

    def stop(self) -> None:
        if os.path.isdir(self.data):
            run(self.as_pg + [f"{PGBIN}/pg_ctl", "-D", self.data, "-w", "-m", "fast", "stop"])

    def sql(self, statement: str, *, label: str | None = None, stdin: str | None = None,
            expect_error: bool = False, keep: int = 4000) -> str:
        """Run one statement through psql; record it; return stdout (tuples only)."""
        t0 = time.time()
        r = subprocess.run(
            [f"{PGBIN}/psql", "-h", self.sock, "-U", "postgres", "-d", "postgres", "-X",
             "-v", "ON_ERROR_STOP=1", "-At", "-F", "|", "-c", statement],
            input=stdin, capture_output=True, text=True)
        out, err = r.stdout.rstrip("\n"), r.stderr.strip()
        self.log.append({
            "label": label or statement.split("\n")[0][:60],
            "sql": statement,
            "ok": r.returncode == 0,
            "seconds": round(time.time() - t0, 3),
            "output": out[:keep],
            "error": err[:keep] if err else None,
        })
        if r.returncode and not expect_error:
            raise RuntimeError(f"psql failed: {statement[:200]} -> {err[-800:]}")
        return err if (r.returncode and expect_error) else out


def probe_postgres(corpus: Corpus, workdir: str) -> dict:
    if not os.path.exists(f"{PGBIN}/initdb"):
        return {"skipped": f"{PGBIN}/initdb not found"}
    pg = Postgres(workdir)
    res: dict = {"bin": PGBIN}
    t_section = time.time()
    try:
        pg.start()
        res["version"] = pg.sql("SELECT version()", label="version")
        res["settings"] = dict(
            line.split("|", 1) for line in pg.sql(
                "SELECT name, setting FROM pg_settings WHERE name IN "
                "('block_size','shared_buffers','maintenance_work_mem','work_mem','fsync','autovacuum',"
                "'server_encoding','lc_collate','default_toast_compression')",
                label="settings").splitlines())
        res["collations_available"] = {
            "icu_count": int(pg.sql("SELECT count(*) FROM pg_collation WHERE collprovider = 'i'", label="icu collations")),
            "libc_en_US": pg.sql("SELECT string_agg(collname, ',') FROM pg_collation "
                                 "WHERE collprovider = 'c' AND collname LIKE 'en\\_US%'",
                                 label="libc en_US collations") or None,
            "database_collation": pg.sql(
                "SELECT datcollate || ' / ' || datctype FROM pg_database WHERE datname = current_database()",
                label="database collation"),
        }
        pg.sql("CREATE EXTENSION pageinspect", label="pageinspect")
        res["pageinspect_version"] = pg.sql("SELECT extversion FROM pg_extension WHERE extname = 'pageinspect'",
                                            label="pageinspect version")

        # --- the corpus, once, in mint order
        pg.sql('CREATE UNLOGGED TABLE src (snow bigint, id14 text COLLATE "C", id15 text COLLATE "C", '
               'id16 text COLLATE "C", u uuid)', label="src table")
        rows = "\n".join(f"{s}\t{a}\t{b}\t{c}\t{uuid_packed(s)}"
                         for s, a, b, c in zip(corpus.snows, corpus.id14, corpus.id15, corpus.id16)) + "\n"
        pg.sql("COPY src FROM STDIN", label="load corpus", stdin=rows)
        del rows
        pg.sql("ANALYZE src", label="analyze src")
        res["src_rows"] = int(pg.sql("SELECT count(*) FROM src", label="src count"))

        # --- pg_column_size: literals and stored values
        lit = pg.sql(
            "SELECT pg_column_size(274557032793636864::bigint), pg_column_size('USR0KHTOWnGLuC'::text), "
            "pg_column_size('USERA0KHTOWnGLuC'::text), pg_column_size('USR0KHTOWnGLuC'::char(14)), "
            "pg_column_size('USR0KHTOWnGLuC'::varchar(14)), pg_column_size('\\x5553523c4b48544f576e474c7543'::bytea), "
            "pg_column_size('00000000-0000-0000-0000-000000000000'::uuid), pg_column_size('USR'::char(3)), "
            "pg_column_size(14005::smallint)",
            label="pg_column_size of literals").split("|")
        res["column_size_literal"] = dict(zip(
            ["bigint", "text14", "text16", "char14", "varchar14", "bytea14", "uuid", "char3", "smallint"],
            map(int, lit)))
        res["column_size_literal_note"] = (
            "literals carry the 4-byte varlena header; a value stored in a heap tuple shorter than 127 bytes "
            "is converted to the 1-byte short header, which is what the per-table column_size below shows")

        # --- one table per representation, N rows inserted in mint order
        tables: dict[str, dict] = {}
        for name, cols, expr in PG_REPRESENTATIONS:
            t = f"t_{name}"
            pg.sql(f"CREATE TABLE {t} ({cols})", label=f"create {t}")
            t0 = time.time()
            pg.sql(f"INSERT INTO {t} SELECT {expr} FROM src ORDER BY snow", label=f"insert {t}")
            insert_s = time.time() - t0
            pg.sql(f"ANALYZE {t}", label=f"analyze {t}")
            heap, idx, total = map(int, pg.sql(
                f"SELECT pg_relation_size('{t}'), pg_relation_size('{t}_pkey'), pg_total_relation_size('{t}')",
                label=f"sizes {t}").split("|"))
            first_col = cols.split()[0]
            colsize = pg.sql(f"SELECT pg_column_size({first_col}), pg_column_size({t}.*) FROM {t} LIMIT 1",
                             label=f"stored column size {t}").split("|")
            heap_items = pg.sql(
                f"SELECT lp_len, count(*) FROM heap_page_items(get_raw_page('{t}', 0)) GROUP BY lp_len ORDER BY lp_len",
                label=f"heap tuple lengths {t}, page 0")
            metap = pg.sql(f"SELECT level, root FROM bt_metap('{t}_pkey')", label=f"bt_metap {t}").split("|")
            stats = pg.sql(
                f"SELECT type, live_items, avg_item_size, page_size, free_size FROM bt_page_stats('{t}_pkey', 1)",
                label=f"bt_page_stats {t} page 1").split("|")
            items = pg.sql(
                f"SELECT itemlen, count(*) FROM bt_page_items('{t}_pkey', 1) GROUP BY itemlen ORDER BY itemlen",
                label=f"bt_page_items lengths {t} page 1")
            tables[name] = {
                "ddl": f"CREATE TABLE {t} ({cols})",
                "insert": f"INSERT INTO {t} SELECT {expr} FROM src ORDER BY snow",
                "insert_seconds": round(insert_s, 2),
                "heap_bytes": heap, "index_bytes": idx, "total_bytes": total,
                "heap_bytes_per_row": round(heap / corpus.n, 2),
                "index_bytes_per_row": round(idx / corpus.n, 2),
                "total_bytes_per_row": round(total / corpus.n, 2),
                "column_size_stored": int(colsize[0]),
                "row_size_stored": int(colsize[1]),
                "heap_tuple_lp_len_page0": {k: int(v) for k, v in (l.split("|") for l in heap_items.splitlines())},
                "btree_level": int(metap[0]),
                "leaf_page1": {"type": stats[0], "live_items": int(stats[1]), "avg_item_size": int(stats[2]),
                               "page_size": int(stats[3]), "free_size": int(stats[4])},
                "index_itemlen_page1": {k: int(v) for k, v in (l.split("|") for l in items.splitlines())},
            }
        res["tables"] = tables

        # --- collation: ordering of 62 consecutive ids, "C" vs ICU
        values = ", ".join(f"({s}, '{i}')" for s, i in ids62())
        pg.sql('CREATE TABLE ids62 (snow bigint PRIMARY KEY, id text COLLATE "C" NOT NULL)', label="ids62 table")
        pg.sql(f"INSERT INTO ids62 VALUES {values}", label="ids62 rows")
        order = {}
        # "C" is bytewise; und/en are linguistic ICU root/English; en-US-u-va-posix is
        # ICU's code-point-order variant, shown as the contrast inside ICU itself.
        collations = ['"C"', '"und-x-icu"', '"en-x-icu"', '"en-US-u-va-posix-x-icu"']
        if res["collations_available"]["libc_en_US"]:
            collations.append('"' + res["collations_available"]["libc_en_US"].split(",")[0] + '"')
        for coll in collations:
            key = coll.strip('"')
            order[key] = {
                "first_16": pg.sql(f"SELECT string_agg(id, ' ' ORDER BY id COLLATE {coll}) FROM "
                                   f"(SELECT id FROM ids62 ORDER BY id COLLATE {coll} LIMIT 16) x",
                                   label=f"ids62 first 16 under {key}"),
                "matches_mint_order": pg.sql(
                    f"SELECT array_agg(id ORDER BY id COLLATE {coll}) = array_agg(id ORDER BY snow) FROM ids62",
                    label=f"ids62 order under {key} == mint order") == "t",
            }
        res["ordering_ids62"] = order
        res["ordering_ids62"]["mint_order_first_16"] = pg.sql(
            "SELECT string_agg(id, ' ' ORDER BY snow) FROM (SELECT id, snow FROM ids62 ORDER BY snow LIMIT 16) x",
            label="ids62 mint order")

        # --- collation at scale: rows out of mint order, and a MinFor range scan
        scale = {}
        for coll in ['"C"', '"und-x-icu"']:
            key = coll.strip('"')
            scale[key] = int(pg.sql(
                f"SELECT count(*) FROM (SELECT row_number() OVER (ORDER BY id14 COLLATE {coll}) AS by_text, "
                f"row_number() OVER (ORDER BY snow) AS by_mint FROM src) x WHERE by_text <> by_mint",
                label=f"rows whose text-order position differs from mint order, {key}"))
        mid = corpus.snows[corpus.n // 2]
        minfor = ((mid >> 22) << 22)  # MinFor(t) for the millisecond of the middle id
        lo = NS3 + payload(minfor)
        truth = int(pg.sql(f"SELECT count(*) FROM t_bigint WHERE id >= {minfor}", label="range scan truth (bigint)"))
        c_count = int(pg.sql(f"SELECT count(*) FROM t_text14 WHERE id >= '{lo}'", label='range scan, text COLLATE "C"'))
        icu_count = int(pg.sql(f"SELECT count(*) FROM t_text14_icu WHERE id >= '{lo}'",
                               label='range scan, text COLLATE "und-x-icu"'))
        plans = {}
        for t in ("t_text14", "t_text14_icu"):
            plans[t] = pg.sql(f"EXPLAIN (COSTS OFF) SELECT id FROM {t} WHERE id LIKE '{corpus.id14[0][:9]}%'",
                              label=f"EXPLAIN LIKE prefix on {t}")
        res["ordering_at_scale"] = {
            "rows_out_of_mint_order": scale,
            "minfor_range_scan": {"lower_bound": lo, "minfor_snowflake": minfor, "bigint_truth": truth,
                                  "text_C": c_count, "text_und_x_icu": icu_count},
            "like_prefix_plans": plans,
        }

        # --- a nondeterministic, case-insensitive ICU collation against UNIQUE
        ci = {}
        pg.sql("CREATE COLLATION ci (provider = icu, locale = 'und-u-ks-level2', deterministic = false)",
               label="create collation ci")
        ci["equal_under_ci"] = pg.sql("SELECT 'USR0KHTOWnGLuC' COLLATE ci = 'USR0KHTOWNGLUC'",
                                      label="case-folded ids equal under ci") == "t"
        ci["equal_under_C"] = pg.sql("SELECT 'USR0KHTOWnGLuC' COLLATE \"C\" = 'USR0KHTOWNGLUC'",
                                     label='case-folded ids equal under "C"') == "t"
        pg.sql("CREATE TABLE t_ci (id text COLLATE ci PRIMARY KEY)", label="t_ci table")
        pg.sql("INSERT INTO t_ci VALUES ('USR0KHTOWnGLuC')", label="t_ci first insert")
        ci["second_insert_error"] = pg.sql("INSERT INTO t_ci VALUES ('USR0KHTOWNGLUC')",
                                           label="t_ci second insert (case-folded)", expect_error=True)
        ci["distinct_ids62"] = dict(zip(
            ["under_C", "under_ci"],
            map(int, pg.sql('SELECT count(DISTINCT id COLLATE "C"), count(DISTINCT id COLLATE ci) FROM ids62',
                            label="distinct ids62 under C vs ci").split("|"))))
        ci["like_error"] = pg.sql("SELECT id FROM t_ci WHERE id LIKE 'USR%'", label="LIKE under ci", expect_error=True)
        res["nondeterministic_ci"] = ci

        # --- brd16: where the metadata digit sits decides what a range scan means
        three = [corpus.snows[0], mid, corpus.snows[-1]]
        adjacent = [f"INVC{m}{payload(s)}" for s in three for m in ("A", "B")]  # ns, meta, payload
        suffix = [f"INVC{payload(s)}{m}" for s in three for m in ("A", "B")]    # ns, payload, meta
        pg.sql('CREATE TABLE demo16_adjacent (id text COLLATE "C" PRIMARY KEY)', label="demo16_adjacent")
        pg.sql('CREATE TABLE demo16_suffix (id text COLLATE "C" PRIMARY KEY)', label="demo16_suffix")
        pg.sql("INSERT INTO demo16_adjacent VALUES " + ", ".join(f"('{i}')" for i in adjacent), label="demo16_adjacent rows")
        pg.sql("INSERT INTO demo16_suffix VALUES " + ", ".join(f"('{i}')" for i in suffix), label="demo16_suffix rows")
        p = payload(minfor)
        res["brd16_placement"] = {
            "snowflakes": three, "minfor_payload": p,
            "adjacent_byte_order": pg.sql("SELECT string_agg(id, ' ' ORDER BY id) FROM demo16_adjacent",
                                          label="demo16_adjacent byte order"),
            "suffix_byte_order": pg.sql("SELECT string_agg(id, ' ' ORDER BY id) FROM demo16_suffix",
                                        label="demo16_suffix byte order"),
            "since_minfor_expected": 4,
            "suffix_one_range": int(pg.sql(f"SELECT count(*) FROM demo16_suffix WHERE id >= 'INVC{p}'",
                                           label="suffix: one MinFor range")),
            "adjacent_naive_range": int(pg.sql(f"SELECT count(*) FROM demo16_adjacent WHERE id >= 'INVCA{p}'",
                                               label="adjacent: a naive single range")),
            "adjacent_one_range_per_metadata_value": int(pg.sql(
                f"SELECT count(*) FROM demo16_adjacent WHERE (id >= 'INVCA{p}' AND id < 'INVCB') OR id >= 'INVCB{p}'",
                label="adjacent: one range per metadata value")),
        }

        # --- mutable state next to the id, never inside it
        first, evt = corpus.id14[0], "EVT" + payload(corpus.snows[-1] + 1)
        pg.sql('CREATE TABLE invoices (id text COLLATE "C" PRIMARY KEY CHECK (length(id) = 14), '
               'deleted_at timestamptz)', label="invoices")
        pg.sql("INSERT INTO invoices SELECT id14, NULL FROM src ORDER BY snow", label="invoices rows")
        pg.sql("CREATE INDEX invoices_live ON invoices (id) WHERE deleted_at IS NULL", label="invoices_live")
        pg.sql(f"UPDATE invoices SET deleted_at = now() WHERE id = '{first}'", label="soft delete")
        pg.sql('CREATE TABLE tombstones (id text COLLATE "C" PRIMARY KEY, reason text NOT NULL, '
               'at timestamptz NOT NULL DEFAULT now())', label="tombstones")
        pg.sql(f"INSERT INTO tombstones (id, reason) VALUES ('{first}', 'customer request')", label="tombstone row")
        pg.sql('CREATE TABLE audit_events (event_id text COLLATE "C" PRIMARY KEY, subject text COLLATE "C" NOT NULL, '
               'kind text NOT NULL, at timestamptz NOT NULL DEFAULT now())', label="audit_events")
        pg.sql("CREATE INDEX audit_events_subject ON audit_events (subject, event_id)", label="audit_events_subject")
        pg.sql(f"INSERT INTO audit_events (event_id, subject, kind) VALUES ('{evt}', '{first}', 'deleted')",
               label="audit event")
        pg.sql("ANALYZE invoices", label="analyze invoices")
        recent = corpus.id14[max(0, corpus.n - 10_000)]  # "the live invoices among the newest 10,000"
        res["mutable_state_patterns"] = {
            "soft_deleted_id": first, "audit_event_id": evt,
            "live_rows": int(pg.sql("SELECT count(*) FROM invoices WHERE deleted_at IS NULL", label="live rows")),
            "live_range_lower_bound": recent,
            "live_range_plan": pg.sql(f"EXPLAIN (COSTS OFF) SELECT id FROM invoices WHERE deleted_at IS NULL AND id >= '{recent}'",
                                      label="EXPLAIN live range (partial index)"),
            "partial_index_bytes": int(pg.sql("SELECT pg_relation_size('invoices_live')", label="partial index size")),
            "history_of_deleted_id": pg.sql(
                f"SELECT kind || ' @ ' || at::date FROM audit_events WHERE subject = '{first}' ORDER BY event_id",
                label="history of the soft-deleted id"),
            "tombstone": pg.sql(f"SELECT reason FROM tombstones WHERE id = '{first}'", label="tombstone lookup"),
        }

        # --- a schema audit: id columns whose collation is not "C"
        res["collation_audit"] = pg.sql(
            "SELECT table_name || '.' || column_name || ' ' || data_type || ' ' || coalesce(collation_name, '(default)') "
            "FROM information_schema.columns WHERE table_schema = 'public' "
            "AND data_type IN ('text', 'character varying', 'character') "
            "AND (column_name = 'id' OR column_name LIKE '%\\_id') "
            "AND collation_name IS DISTINCT FROM 'C' ORDER BY table_name, column_name",
            label="collation audit of id columns").splitlines()
    finally:
        pg.stop()
        res["sql_log"] = pg.log
        res["seconds"] = round(time.time() - t_section, 1)
    return res


SECTIONS["pg"] = ("postgresql", probe_postgres)


# --------------------------------------------------------------------------- Redis

class RespClient:
    def __init__(self, port: int):
        self.sock = socket.create_connection(("127.0.0.1", port))
        self.rd = self.sock.makefile("rb")

    @staticmethod
    def encode(*args: str) -> bytes:
        parts = [f"*{len(args)}\r\n".encode()]
        for a in args:
            b = a.encode()
            parts.append(b"$%d\r\n%s\r\n" % (len(b), b))
        return b"".join(parts)

    def read(self):
        line = self.rd.readline()
        if not line:
            raise ConnectionError("redis closed the connection")
        kind, body = line[:1], line[1:-2]
        if kind == b"+":
            return body.decode()
        if kind == b":":
            return int(body)
        if kind == b"-":
            raise RuntimeError(body.decode())
        if kind == b"$":
            n = int(body)
            if n < 0:
                return None
            data = self.rd.read(n + 2)[:-2]
            return data.decode()
        if kind == b"*":
            return [self.read() for _ in range(int(body))]
        raise RuntimeError(f"unexpected reply {line!r}")

    def cmd(self, *args: str):
        self.sock.sendall(self.encode(*args))
        return self.read()

    def pipeline_set(self, keys: list[str], value: str, batch: int = 20000) -> None:
        for i in range(0, len(keys), batch):
            chunk = keys[i:i + batch]
            self.sock.sendall(b"".join(self.encode("SET", k, value) for k in chunk))
            for _ in chunk:
                self.read()

    def info(self, section: str) -> dict:
        out = {}
        for line in self.cmd("INFO", section).splitlines():
            if ":" in line and not line.startswith("#"):
                k, v = line.split(":", 1)
                out[k] = v
        return out

    def memory_stats(self) -> dict:
        flat = self.cmd("MEMORY", "STATS")
        return {flat[i]: flat[i + 1] for i in range(0, len(flat), 2)}

    def close(self) -> None:
        self.sock.close()


def probe_redis(corpus: Corpus, workdir: str) -> dict:
    exe = which("redis-server")
    if not exe:
        return {"skipped": "redis-server not on PATH"}
    port = free_port()
    rdir = os.path.join(workdir, "redis")
    os.makedirs(rdir)
    t_section = time.time()
    proc = subprocess.Popen([exe, "--port", str(port), "--bind", "127.0.0.1", "--save", "", "--appendonly", "no",
                             "--dir", rdir, "--daemonize", "no", "--loglevel", "warning"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    res: dict = {"command": f"redis-server --port {port} --save '' --appendonly no"}
    client = None
    try:
        for _ in range(100):
            try:
                client = RespClient(port)
                if client.cmd("PING") == "PONG":
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("redis did not come up")
        srv = client.info("server")
        res["version"] = srv.get("redis_version")
        res["arch_bits"] = srv.get("arch_bits")
        res["mem_allocator"] = client.info("memory").get("mem_allocator")

        # --- one key of each width, with small values
        single = {}
        for value, vlabel in (("1", "value '1' (shared integer object)"), ("v", "value 'v' (1-byte string)"),
                              ("payload!", "value 'payload!' (8-byte string)")):
            client.cmd("FLUSHALL")
            row = {}
            for key in (corpus.id14[0], corpus.id15[0], corpus.id16[0]):
                client.cmd("SET", key, value)
                row[f"key{len(key)}"] = {
                    "key": key, "memory_usage": client.cmd("MEMORY", "USAGE", key),
                    "value_encoding": client.cmd("OBJECT", "ENCODING", key),
                }
            single[vlabel] = row
        res["single_key"] = single

        # --- MEMORY USAGE as a function of key length: the allocator's steps
        client.cmd("FLUSHALL")
        sweep = {}
        for length in range(1, 49):
            key = (ALPHABET + ALPHABET)[:length]
            client.cmd("SET", key, "1")
            sweep[str(length)] = client.cmd("MEMORY", "USAGE", key)
        res["memory_usage_by_key_length"] = sweep

        # --- N keys of each width, value '1'
        bulk = {}
        for width, keys in ((14, corpus.id14), (15, corpus.id15), (16, corpus.id16)):
            client.cmd("FLUSHALL")
            before = int(client.info("memory")["used_memory"])
            t0 = time.time()
            client.pipeline_set(keys, "1")
            seconds = time.time() - t0
            mem = client.info("memory")
            after = int(mem["used_memory"])
            stats = client.memory_stats()
            bulk[f"width{width}"] = {
                "keys": client.cmd("DBSIZE"),
                "load_seconds": round(seconds, 1),
                "used_memory_before": before,
                "used_memory_after": after,
                "used_memory_delta_per_key": round((after - before) / corpus.n, 2),
                "memory_stats_keys_bytes_per_key": stats.get("keys.bytes-per-key"),
                "memory_stats_dataset_bytes_per_key": round(int(stats["dataset.bytes"]) / corpus.n, 2),
                "memory_stats_overhead_hashtable_main": stats.get("overhead.hashtable.main"),
                "memory_usage_first_key": client.cmd("MEMORY", "USAGE", keys[0]),
                "allocator_allocated": mem.get("allocator_allocated"),
                "allocator_frag_ratio": mem.get("allocator_frag_ratio"),
                "used_memory_peak": mem.get("used_memory_peak"),
            }
        res["bulk"] = bulk
    finally:
        try:
            if client:
                client.cmd("SHUTDOWN", "NOSAVE")
        except Exception:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
        if client:
            client.close()
        res["seconds"] = round(time.time() - t_section, 1)
    return res


SECTIONS["redis"] = ("redis", probe_redis)


# --------------------------------------------------------------------------- SQLite

SQLITE_VARIANTS = [
    # name, ddl, which column of the corpus goes in
    ("int_pk", "CREATE TABLE t (id INTEGER PRIMARY KEY)", "snow"),
    ("text14_rowid", "CREATE TABLE t (id TEXT PRIMARY KEY)", "id14"),
    ("text16_rowid", "CREATE TABLE t (id TEXT PRIMARY KEY)", "id16"),
    ("text14_worowid", "CREATE TABLE t (id TEXT PRIMARY KEY) WITHOUT ROWID", "id14"),
    ("text15_worowid", "CREATE TABLE t (id TEXT PRIMARY KEY) WITHOUT ROWID", "id15"),
    ("text16_worowid", "CREATE TABLE t (id TEXT PRIMARY KEY) WITHOUT ROWID", "id16"),
    ("blob14_worowid", "CREATE TABLE t (id BLOB PRIMARY KEY) WITHOUT ROWID", "blob14"),
    ("blob16_worowid", "CREATE TABLE t (id BLOB PRIMARY KEY) WITHOUT ROWID", "blob16"),
    ("comp_worowid", "CREATE TABLE t (ns TEXT NOT NULL, snow INTEGER NOT NULL, PRIMARY KEY (ns, snow)) WITHOUT ROWID", "comp"),
]


def probe_sqlite(corpus: Corpus, workdir: str) -> dict:
    sdir = os.path.join(workdir, "sqlite")
    os.makedirs(sdir)
    t_section = time.time()
    res: dict = {"sqlite_version": sqlite3.sqlite_version, "variants": {}}
    for name, ddl, source in SQLITE_VARIANTS:
        path = os.path.join(sdir, f"{name}.db")
        conn = sqlite3.connect(path)
        conn.execute("PRAGMA journal_mode = OFF")
        conn.execute("PRAGMA synchronous = OFF")
        conn.execute("PRAGMA cache_size = -262144")
        conn.execute(ddl)
        if source == "snow":
            rows = ((s,) for s in corpus.snows)
        elif source == "id14":
            rows = ((i,) for i in corpus.id14)
        elif source == "id15":
            rows = ((i,) for i in corpus.id15)
        elif source == "id16":
            rows = ((i,) for i in corpus.id16)
        elif source == "blob14":
            rows = ((i.encode("ascii"),) for i in corpus.id14)
        elif source == "blob16":
            rows = ((i.encode("ascii"),) for i in corpus.id16)
        else:
            rows = ((NS3, s) for s in corpus.snows)
        placeholders = "(?, ?)" if source == "comp" else "(?)"
        t0 = time.time()
        with conn:
            conn.executemany(f"INSERT INTO t VALUES {placeholders}", rows)
        seconds = time.time() - t0
        page_size = conn.execute("PRAGMA page_size").fetchone()[0]
        page_count = conn.execute("PRAGMA page_count").fetchone()[0]
        btrees = {}
        try:
            for bname, pages, payload_b, unused in conn.execute(
                    "SELECT name, count(*), sum(payload), sum(unused) FROM dbstat GROUP BY name ORDER BY name"):
                btrees[bname] = {"pages": pages, "payload_bytes": payload_b, "unused_bytes": unused}
        except sqlite3.OperationalError as e:
            btrees = {"unavailable": str(e)}
        count = conn.execute("SELECT count(*) FROM t").fetchone()[0]
        conn.close()
        size = os.path.getsize(path)
        res["variants"][name] = {
            "ddl": ddl, "rows": count, "insert_seconds": round(seconds, 2),
            "file_bytes": size, "page_size": page_size, "page_count": page_count,
            "bytes_per_row": round(size / corpus.n, 2), "btrees": btrees,
        }
        os.remove(path)
    res["seconds"] = round(time.time() - t_section, 1)
    return res


SECTIONS["sqlite"] = ("sqlite", probe_sqlite)


# --------------------------------------------------------------------------- in-process memory

def versions_env() -> dict:
    out = {}
    try:
        with open(os.path.join(ROOT, "scripts", "versions.env")) as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if "=" in line:
                    k, v = line.split("=", 1)
                    out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def probe_memory(corpus: Corpus, workdir: str) -> dict:
    n = corpus.n
    res: dict = {}
    t_section = time.time()
    env = dict(os.environ)
    ver = versions_env()
    if "GO_VERSION" in ver and "GOTOOLCHAIN" not in env:
        env["GOTOOLCHAIN"] = "go" + ver["GO_VERSION"]
    for extra in ("/opt/node24/bin", os.path.expanduser("~/.bun/bin")):
        if os.path.isdir(extra) and extra not in env.get("PATH", ""):
            env["PATH"] = extra + os.pathsep + env.get("PATH", "")
    # Runtime option variables (e.g. BUN_OPTIONS=--smol) would change what is
    # measured; the helpers run with the runtimes' defaults, and the probe says so.
    res["cleared_env"] = {k: env.pop(k) for k in ("BUN_OPTIONS", "NODE_OPTIONS") if k in env}

    # Go
    go = shutil.which("go", path=env["PATH"])
    if go:
        r = subprocess.run([go, "run", ".", "-n", str(n)], cwd=os.path.join(HERE, "gomem"),
                           capture_output=True, text=True, env=env)
        res["go"] = json.loads(r.stdout) if r.returncode == 0 else {"error": r.stderr[-800:]}
    else:
        res["go"] = {"skipped": "go not on PATH"}

    # CPython: every 3.14 interpreter present, plus the one running this script
    interpreters = []
    for name in ("python3.14", "python3.14t"):
        p = shutil.which(name, path=env["PATH"])
        if p:
            interpreters.append(p)
    if not interpreters:
        interpreters.append(sys.executable)
    cpython = {}
    for exe in interpreters:
        entry = {}
        for width in (14, 16):
            r = subprocess.run([exe, os.path.join(HERE, "pymem.py"), str(n), str(width)],
                               capture_output=True, text=True, env=env)
            if r.returncode:
                entry = {"error": r.stderr[-800:]}
                break
            d = json.loads(r.stdout)
            entry.setdefault("version", d["version"])
            entry.setdefault("free_threaded", d["free_threaded"])
            entry[f"width{width}"] = d["measurement"]
        cpython[os.path.basename(exe)] = entry
    res["cpython"] = cpython

    # Node and Bun
    for runtime, argv in (("node", ["node", "--expose-gc"]), ("bun", ["bun"])):
        exe = shutil.which(argv[0], path=env["PATH"])
        if not exe:
            res[runtime] = {"skipped": f"{argv[0]} not on PATH"}
            continue
        entry = {}
        for width in (14, 16):
            r = subprocess.run([exe] + argv[1:] + [os.path.join(HERE, "jsmem.js"), str(n), str(width)],
                               capture_output=True, text=True, env=env)
            if r.returncode:
                entry = {"error": r.stderr[-800:]}
                break
            d = json.loads(r.stdout)
            for k in ("version", "v8", "revision", "engine", "pointer_compression"):
                if k in d:
                    entry.setdefault(k, d[k])
            entry[f"width{width}"] = d["measurement"]
        res[runtime] = entry

    res["not_measured_here"] = {
        "beam": "no Erlang in this environment; the article cites the OTP efficiency guide",
        "valkey9": "not installed here; the article cites the Valkey blog, no numbers are invented",
        "mysql": "not installed here; the article cites the MySQL 8.0 reference manual",
    }
    res["seconds"] = round(time.time() - t_section, 1)
    return res


SECTIONS["memory"] = ("memory", probe_memory)


# --------------------------------------------------------------------------- main

def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--n", type=int, default=1_000_000, help="rows / keys / strings per representation")
    ap.add_argument("--only", default=",".join(SECTIONS), help="comma-separated sections")
    ap.add_argument("--out", default=os.path.join(HERE, "results.json"))
    args = ap.parse_args()
    sections = [s.strip() for s in args.only.split(",") if s.strip()]
    unknown = [s for s in sections if s not in SECTIONS]
    if unknown:
        ap.error(f"unknown section(s) {unknown}; available: {', '.join(SECTIONS)}")

    started = time.time()
    print(f"storage probe: n={args.n} sections={sections}", flush=True)
    corpus = Corpus(args.n)
    print(f"  corpus: {corpus.id14[0]} .. {corpus.id14[-1]} ({corpus.seconds:.1f}s)", flush=True)
    results: dict = {
        "schema": 1,
        "started_at": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds"),
        "command": "python3 tools/storage_probe/run.py" + (f" --n {args.n}" if args.n != 1_000_000 else ""),
        "host": host_info(),
        "corpus": corpus.describe(),
    }
    workdir = tempfile.mkdtemp(prefix="brd14-storage-probe-")
    try:
        for section in sections:
            key, fn = SECTIONS[section]
            print(f"  {section} ...", end="", flush=True)
            t0 = time.time()
            try:
                results[key] = fn(corpus, workdir)
                print(f" {time.time() - t0:.1f}s", flush=True)
            except Exception as e:  # keep the other sections' evidence
                results[key] = {"error": repr(e)}
                print(f" FAILED: {e!r}", flush=True)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    results["seconds_total"] = round(time.time() - started, 1)
    with open(args.out, "w") as f:
        json.dump(results, f, indent=1, sort_keys=False)
        f.write("\n")
    print(f"wrote {args.out} in {results['seconds_total']}s (temp dir removed: {not os.path.exists(workdir)})")
    return 0 if not any(isinstance(v, dict) and "error" in v for v in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
