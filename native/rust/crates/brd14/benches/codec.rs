//! The brd14 bench (bench/README.md): encode, decode, hash32 and mint for each core over the
//! shared corpus — the first 4096 rows of vectors/valid.tsv, cycled in order inside the
//! timed loop — warm-up, ≥ 10 samples of ≥ 50 ms each, median and MAD, results into
//! `bench/results/rust-<variant>-<runtime>.json`.
//!
//! ```text
//! make bench                                   # pinned with taskset -c 2
//! cargo bench -p brd14 --features std --bench codec [-- <op-or-core filter>]
//! ```
//!
//! Environment: `BRD14_BENCH_SAMPLES` (default 15), `BRD14_BENCH_SAMPLE_MS` (default 60),
//! `BRD14_RUNTIME` (default `rustc-<version>` from `rustc --version`), `BRD14_VECTORS_DIR`,
//! `BRD14_BENCH_OUT` (default `<repo>/bench/results`).

use std::hint::black_box;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use brd14::{Error, Generator, LEN, NS_LEN, hash32, memory, speed};

const CORPUS: usize = 4096;

struct Corpus {
    ns: Vec<[u8; NS_LEN]>,
    snow: Vec<u64>,
    id: Vec<[u8; LEN]>,
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../..")
}

fn load_corpus() -> Corpus {
    let dir = std::env::var_os("BRD14_VECTORS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo_root().join("vectors"));
    let path = dir.join("valid.tsv");
    let text = std::fs::read_to_string(&path).unwrap_or_else(|e| {
        eprintln!("bench: the corpus is required: {}: {e}", path.display());
        std::process::exit(1);
    });
    let mut c = Corpus { ns: Vec::new(), snow: Vec::new(), id: Vec::new() };
    for line in text.lines().filter(|l| !l.is_empty() && !l.starts_with('#')).take(CORPUS) {
        let f: Vec<&str> = line.split('\t').collect();
        c.ns.push(f[0].as_bytes().try_into().expect("ns"));
        c.snow.push(f[1].parse().expect("snow"));
        c.id.push(f[2].as_bytes().try_into().expect("id"));
    }
    assert_eq!(c.snow.len(), CORPUS, "valid.tsv must hold {CORPUS} corpus rows");
    c
}

struct Stat {
    op: &'static str,
    median: f64,
    mad: f64,
    cv: f64,
    samples: usize,
}

fn median(v: &mut [f64]) -> f64 {
    v.sort_by(f64::total_cmp);
    let n = v.len();
    if n % 2 == 1 { v[n / 2] } else { (v[n / 2 - 1] + v[n / 2]) / 2.0 }
}

fn env_num(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Time `pass` (one pass = `CORPUS` ops over the whole corpus): warm up, calibrate the
/// passes per sample so a sample lasts at least `sample_ms`, then take the samples.
fn measure(op: &'static str, mut pass: impl FnMut() -> u64) -> Stat {
    let samples = env_num("BRD14_BENCH_SAMPLES", 15).max(10) as usize;
    let sample = Duration::from_millis(env_num("BRD14_BENCH_SAMPLE_MS", 60).max(50));
    let mut sink = 0u64;
    // warm-up and calibration in one: double the passes until one batch fills a sample
    let mut passes = 1u64;
    let warm_until = Instant::now() + Duration::from_millis(200);
    loop {
        let t = Instant::now();
        for _ in 0..passes {
            sink = sink.wrapping_add(pass());
        }
        if t.elapsed() >= sample && Instant::now() >= warm_until {
            break;
        }
        if t.elapsed() < sample {
            passes *= 2;
        }
    }
    let mut ns_per_op: Vec<f64> = (0..samples)
        .map(|_| {
            let t = Instant::now();
            for _ in 0..passes {
                sink = sink.wrapping_add(pass());
            }
            t.elapsed().as_nanos() as f64 / (passes * CORPUS as u64) as f64
        })
        .collect();
    black_box(sink);
    let mean = ns_per_op.iter().sum::<f64>() / samples as f64;
    let var = ns_per_op.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / samples as f64;
    let med = median(&mut ns_per_op);
    let mut dev: Vec<f64> = ns_per_op.iter().map(|x| (x - med).abs()).collect();
    Stat { op, median: med, mad: median(&mut dev), cv: var.sqrt() / mean, samples }
}

/// Generic over the core's functions, so each core is monomorphised and inlinable exactly
/// as at a real call site (a fn pointer would measure an indirect call instead).
fn bench_core<E, D>(c: &Corpus, encode: E, decode: D, filter: &dyn Fn(&str) -> bool) -> Vec<Stat>
where
    E: Fn(&[u8; NS_LEN], u64) -> Result<[u8; LEN], Error>,
    D: Fn(&[u8]) -> Result<([u8; NS_LEN], u64), Error>,
{
    let mut out = Vec::new();
    if filter("encode") {
        out.push(measure("encode", || {
            let mut acc = 0u64;
            for i in 0..CORPUS {
                let id = encode(black_box(&c.ns[i]), black_box(c.snow[i]));
                acc = acc.wrapping_add(black_box(id).map_or(0, |b| b[13] as u64));
            }
            acc
        }));
    }
    if filter("decode") {
        out.push(measure("decode", || {
            let mut acc = 0u64;
            for i in 0..CORPUS {
                let r = decode(black_box(&c.id[i]));
                acc = acc.wrapping_add(black_box(r).map_or(0, |(_, s)| s));
            }
            acc
        }));
    }
    if filter("hash32") {
        out.push(measure("hash32", || {
            let mut acc = 0u64;
            for i in 0..CORPUS {
                acc = acc.wrapping_add(black_box(hash32(black_box(c.snow[i]))) as u64);
            }
            acc
        }));
    }
    if filter("mint") {
        // the next branded id from a wall-clock generator: CAS + clock read + encode
        let g = Generator::new(7);
        out.push(measure("mint", || {
            let mut acc = 0u64;
            for i in 0..CORPUS {
                let id = encode(black_box(&c.ns[i]), g.next());
                acc = acc.wrapping_add(black_box(id).map_or(0, |b| b[13] as u64));
            }
            acc
        }));
    }
    out
}

fn runtime() -> String {
    if let Ok(r) = std::env::var("BRD14_RUNTIME") {
        return r;
    }
    let v = std::process::Command::new(std::env::var("RUSTC").unwrap_or_else(|_| "rustc".into()))
        .arg("--version")
        .current_dir(env!("CARGO_MANIFEST_DIR"))
        .output()
        .ok()
        .and_then(|o| String::from_utf8(o.stdout).ok())
        .and_then(|s| s.split_whitespace().nth(1).map(str::to_owned))
        .unwrap_or_else(|| "unknown".into());
    format!("rustc-{v}")
}

fn machine() -> String {
    std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|s| {
            s.lines()
                .find(|l| l.starts_with("model name"))
                .map(|l| l.split(':').nth(1).unwrap_or("").trim().to_owned())
        })
        .unwrap_or_else(|| std::env::consts::ARCH.into())
}

/// Pinned when the process may run on exactly one CPU (taskset -c N).
fn pinned() -> bool {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| {
            s.lines().find(|l| l.starts_with("Cpus_allowed_list:")).map(|l| l[18..].trim().to_owned())
        })
        .is_some_and(|cpus| !cpus.contains([',', '-']))
}

fn json_str(s: &str) -> String {
    let mut o = String::from("\"");
    for ch in s.chars() {
        match ch {
            '"' => o.push_str("\\\""),
            '\\' => o.push_str("\\\\"),
            c if (c as u32) < 0x20 => o.push_str(&format!("\\u{:04x}", c as u32)),
            c => o.push(c),
        }
    }
    o.push('"');
    o
}

fn write_json(variant: &str, runtime: &str, stats: &[Stat]) -> PathBuf {
    let dir = std::env::var_os("BRD14_BENCH_OUT")
        .map(PathBuf::from)
        .unwrap_or_else(|| repo_root().join("bench/results"));
    std::fs::create_dir_all(&dir).expect("create bench/results");
    let file = format!("rust-{variant}-{}.json", runtime.replace(['/', ' '], "-"));
    let results: Vec<String> = stats
        .iter()
        .map(|s| {
            format!(
                "    {{\"op\": {}, \"ns_per_op\": {:.3}, \"mad_ns\": {:.3}, \"cv\": {:.4}, \"samples\": {}, \"allocs_per_op\": 0, \"bytes_per_op\": 0}}",
                json_str(s.op),
                s.median,
                s.mad,
                s.cv,
                s.samples
            )
        })
        .collect();
    let body = format!(
        "{{\n  \"impl\": \"rust\",\n  \"variant\": {},\n  \"runtime\": {},\n  \"machine\": {},\n  \"pinned\": {},\n  \"corpus\": \"vectors/valid.tsv rows 1..4096\",\n  \"results\": [\n{}\n  ]\n}}\n",
        json_str(variant),
        json_str(runtime),
        json_str(&machine()),
        pinned(),
        results.join(",\n")
    );
    let path = dir.canonicalize().unwrap_or(dir).join(file);
    std::fs::write(&path, body).expect("write bench json");
    path
}

fn main() {
    // cargo passes --bench; anything else that is not a flag filters cores and ops
    let filters: Vec<String> = std::env::args().skip(1).filter(|a| !a.starts_with("--")).collect();
    let corpus = load_corpus();
    let runtime = runtime();
    println!("brd14 bench — {} — {} — pinned: {}", runtime, machine(), pinned());
    for variant in ["speed", "memory"] {
        let keep = |op: &str| filters.is_empty() || filters.iter().any(|f| f == op || f == variant);
        if !filters.is_empty() && !["encode", "decode", "hash32", "mint"].iter().any(|op| keep(op)) {
            continue;
        }
        let stats = match variant {
            "speed" => bench_core(&corpus, speed::encode, speed::decode, &keep),
            _ => bench_core(&corpus, memory::encode, memory::decode, &keep),
        };
        println!("\n{variant:<7} {:<8} {:>10} {:>8} {:>7} {:>8}", "op", "ns/op", "mad", "cv%", "samples");
        for s in &stats {
            let noisy = if s.cv > 0.05 { "  (noisy)" } else { "" };
            println!(
                "{variant:<7} {:<8} {:>10.2} {:>8.2} {:>7.1} {:>8}{noisy}",
                s.op,
                s.median,
                s.mad,
                s.cv * 100.0,
                s.samples
            );
        }
        if filters.is_empty() {
            println!("-> {}", write_json(variant, &runtime, &stats).display());
        }
    }
}
