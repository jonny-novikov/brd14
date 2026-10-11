//! The frozen corpus (`vectors/*.tsv`, generated from `tools/oracle.py`) against both cores.
//!
//! The repository's `vectors/` directory is found through `CARGO_MANIFEST_DIR`. When it is
//! absent (a published crate) every test here **skips**; when it is absent but
//! `BRD14_REQUIRE_VECTORS=1` is set (root Makefile, CI) every test **fails**.
//! `BRD14_VECTORS_DIR` overrides the location.

use std::path::PathBuf;

use brd14::{Error, LEN, NS_LEN, fields, hash32, memory, min_for, node_from, speed, unix_ms};

type Encode = fn(&[u8; NS_LEN], u64) -> Result<[u8; LEN], Error>;
type Decode = fn(&[u8]) -> Result<([u8; NS_LEN], u64), Error>;
const CORES: [(&str, Encode, Decode); 2] =
    [("speed", speed::encode, speed::decode), ("memory", memory::encode, memory::decode)];

/// Rows of `vectors/<name>` (comments and blank lines dropped), or `None` to skip.
fn rows(name: &str) -> Option<Vec<Vec<String>>> {
    let dir = std::env::var_os("BRD14_VECTORS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../vectors"));
    if !dir.is_dir() {
        if std::env::var("BRD14_REQUIRE_VECTORS").as_deref() == Ok("1") {
            panic!("vectors/ not found at {} and BRD14_REQUIRE_VECTORS=1", dir.display());
        }
        eprintln!("SKIP {name}: vectors/ not found at {}", dir.display());
        return None;
    }
    let path = dir.join(name);
    let mut bytes = std::fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    if cfg!(miri) {
        // Miri interprets every instruction and is here for UB, not coverage (the native
        // run reads every row): keep the first 8 KiB, cut at a line boundary.
        let cut = bytes[..bytes.len().min(8192)].iter().rposition(|&b| b == b'\n').map_or(0, |i| i + 1);
        bytes.truncate(cut);
    }
    let text = String::from_utf8(bytes).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    let rows: Vec<Vec<String>> = text
        .lines()
        .filter(|l| !l.is_empty() && !l.starts_with('#'))
        .map(|l| l.split('\t').map(str::to_owned).collect())
        .collect();
    assert!(!rows.is_empty(), "{name} has no data rows");
    Some(rows)
}

/// `-` is the empty byte string; otherwise lowercase hex.
fn unhex(s: &str) -> Vec<u8> {
    if s == "-" {
        return Vec::new();
    }
    assert!(s.len() % 2 == 0, "odd hex {s:?}");
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn class(e: Error) -> &'static str {
    e.class()
}

#[test]
fn valid_rows_both_cores() {
    let Some(rows) = rows("valid.tsv") else { return };
    if !cfg!(miri) {
        assert!(rows.len() >= 4096, "the bench corpus needs 4096 rows, found {}", rows.len());
    }
    for r in &rows {
        let [ns, snow, id, h, ms, ts, node, seq] = &r[..] else { panic!("bad row {r:?}") };
        let ns: [u8; 3] = ns.as_bytes().try_into().unwrap();
        let snow: u64 = snow.parse().unwrap();
        for (core, encode, decode) in CORES {
            assert_eq!(encode(&ns, snow).as_ref().map(|b| &b[..]), Ok(id.as_bytes()), "{core} encode {r:?}");
            assert_eq!(decode(id.as_bytes()), Ok((ns, snow)), "{core} decode {r:?}");
        }
        assert_eq!(hash32(snow).to_string(), *h, "hash32 {r:?}");
        assert_eq!(unix_ms(snow).to_string(), *ms, "unix_ms {r:?}");
        let (t, n, s) = fields(snow);
        assert_eq!((t.to_string(), n.to_string(), s.to_string()), (ts.clone(), node.clone(), seq.clone()));
        assert_eq!(min_for(unix_ms(snow)), t << 22, "min_for {r:?}");
    }
}

#[test]
fn decode_refusals_both_cores() {
    let Some(rows) = rows("invalid.tsv") else { return };
    for r in &rows {
        let [id, want] = &r[..] else { panic!("bad row {r:?}") };
        let id = unhex(id);
        for (core, _, decode) in CORES {
            assert_eq!(decode(&id).map_err(class), Err(want.as_str()), "{core} decode {r:?}");
        }
    }
}

#[test]
fn encode_refusals_both_cores() {
    let Some(rows) = rows("encode_invalid.tsv") else { return };
    for r in &rows {
        let [ns, snow, want] = &r[..] else { panic!("bad row {r:?}") };
        let ns = unhex(ns);
        let snow: u64 = snow.parse().unwrap();
        for (core, encode, _) in CORES {
            // A typed API takes &[u8; 3]; any other length is NAMESPACE before encode.
            let got = match <[u8; NS_LEN]>::try_from(ns.as_slice()) {
                Ok(ns) => encode(&ns, snow).map_err(class),
                Err(_) => Err("NAMESPACE"),
            };
            assert_eq!(got.map(|_| ()), Err(want.as_str()), "{core} encode {r:?}");
        }
    }
}

#[test]
fn node_rows() {
    let Some(rows) = rows("node.tsv") else { return };
    for r in &rows {
        let [host, pid, want] = &r[..] else { panic!("bad row {r:?}") };
        let got = node_from(&unhex(host), pid.parse().unwrap());
        assert_eq!(got.to_string(), *want, "node_from {r:?}");
    }
}
