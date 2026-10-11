//! brd14-conform — the parity shim (`docs/contract.md`, "Parity shim protocol").
//!
//! ```text
//! brd14-conform speed|memory < requests > responses
//! ```
//!
//! First line `HELLO rust <variant> EDHUFN`, then exactly one response line per request.
//! Diagnostics go to stderr only. `tools/parity.py` runs it as `rust-speed` and
//! `rust-memory` and diffs every line against the oracle.

use std::io::{self, BufRead, BufWriter, Write};
use std::process::ExitCode;

use brd14::{Error, LEN, NS_LEN};

type EncodeFn = fn(&[u8; NS_LEN], u64) -> Result<[u8; LEN], Error>;
type DecodeFn = fn(&[u8]) -> Result<([u8; NS_LEN], u64), Error>;

/// One core's codec entry points; the table-free helpers are shared by both cores.
struct Core {
    name: &'static str,
    encode: EncodeFn,
    decode: DecodeFn,
}

const SPEED: Core = Core { name: "speed", encode: brd14::speed::encode, decode: brd14::speed::decode };
const MEMORY: Core = Core { name: "memory", encode: brd14::memory::encode, decode: brd14::memory::decode };

/// `-` is the empty string; otherwise lowercase (or uppercase) hex pairs.
fn unhex(s: &str, buf: &mut Vec<u8>) -> Result<(), &'static str> {
    buf.clear();
    if s == "-" {
        return Ok(());
    }
    if s.len() % 2 != 0 {
        return Err("odd-length hex");
    }
    let nib = |c: u8| match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => Err("non-hex digit"),
    };
    for pair in s.as_bytes().chunks_exact(2) {
        buf.push(nib(pair[0])? << 4 | nib(pair[1])?);
    }
    Ok(())
}

fn arg<'a>(args: &mut impl Iterator<Item = &'a str>) -> Result<&'a str, &'static str> {
    args.next().ok_or("missing argument")
}

fn num<T: std::str::FromStr>(s: &str) -> Result<T, &'static str> {
    s.parse().map_err(|_| "bad integer")
}

/// Write the response to one request line.
fn respond(core: &Core, line: &str, buf: &mut Vec<u8>, out: &mut impl Write) -> Result<(), &'static str> {
    let mut args = line.split(' ');
    let op = args.next().unwrap_or("");
    let r = match op {
        "E" => {
            unhex(arg(&mut args)?, buf)?;
            let snow: u64 = num(arg(&mut args)?)?;
            // The Rust API takes &[u8; 3]: a namespace of any other length is NAMESPACE,
            // decided here before encode is reached (contract: namespace-first).
            match <[u8; NS_LEN]>::try_from(buf.as_slice()) {
                Ok(ns) => match (core.encode)(&ns, snow) {
                    Ok(id) => out.write_all(b"OK ").and_then(|_| out.write_all(&id)),
                    Err(e) => write!(out, "ERR {}", e.class()),
                },
                Err(_) => write!(out, "ERR {}", Error::Namespace.class()),
            }
        }
        "D" => {
            unhex(arg(&mut args)?, buf)?;
            match (core.decode)(buf) {
                Ok((ns, snow)) => out
                    .write_all(b"OK ")
                    .and_then(|_| out.write_all(&ns))
                    .and_then(|_| write!(out, " {snow}")),
                Err(e) => write!(out, "ERR {}", e.class()),
            }
        }
        "H" => write!(out, "OK {}", brd14::hash32(num(arg(&mut args)?)?)),
        "U" => write!(out, "OK {}", brd14::unix_ms(num(arg(&mut args)?)?)),
        "F" => {
            let (ts, node, seq) = brd14::fields(num(arg(&mut args)?)?);
            write!(out, "OK {ts} {node} {seq}")
        }
        "N" => {
            unhex(arg(&mut args)?, buf)?;
            let pid: u32 = num(arg(&mut args)?)?;
            write!(out, "OK {}", brd14::node_from(buf, pid))
        }
        _ => return Err("unknown operation"),
    };
    if args.next().is_some() {
        return Err("trailing arguments");
    }
    r.and_then(|_| out.write_all(b"\n")).map_err(|_| "stdout write failed")
}

fn main() -> ExitCode {
    let core = match std::env::args().nth(1).as_deref() {
        Some("speed") => &SPEED,
        Some("memory") => &MEMORY,
        _ => {
            eprintln!("usage: brd14-conform speed|memory < requests");
            return ExitCode::from(2);
        }
    };
    let mut out = BufWriter::with_capacity(1 << 16, io::stdout().lock());
    if writeln!(out, "HELLO rust {} EDHUFN", core.name).is_err() {
        return ExitCode::FAILURE;
    }
    let mut buf = Vec::with_capacity(64);
    let mut status = ExitCode::SUCCESS;
    for (n, line) in io::stdin().lock().lines().enumerate() {
        let Ok(line) = line else {
            eprintln!("brd14-conform: stdin read failed at line {}", n + 1);
            return ExitCode::FAILURE;
        };
        let line = line.trim_end_matches('\r');
        if line.is_empty() {
            continue;
        }
        if let Err(why) = respond(core, line, &mut buf, &mut out) {
            eprintln!("brd14-conform: line {}: {why}: {line:?}", n + 1);
            // keep the one-line-per-request invariant so the driver's diff stays aligned
            if writeln!(out, "ERR PROTOCOL").is_err() {
                return ExitCode::FAILURE;
            }
            status = ExitCode::FAILURE;
        }
    }
    if out.flush().is_err() {
        return ExitCode::FAILURE;
    }
    status
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run(core: &Core, line: &str) -> String {
        let (mut buf, mut out) = (Vec::new(), Vec::new());
        respond(core, line, &mut buf, &mut out).unwrap();
        String::from_utf8(out).unwrap()
    }

    #[test]
    fn protocol_lines() {
        for core in [&SPEED, &MEMORY] {
            assert_eq!(run(core, "E 555352 274557032793636864"), "OK USR0KHTOWnGLuC\n");
            assert_eq!(run(core, "E 5553 0"), "ERR NAMESPACE\n");
            assert_eq!(run(core, "E - 18446744073709551615"), "ERR NAMESPACE\n");
            assert_eq!(run(core, "E 555352 9223372036854775808"), "ERR RANGE\n");
            assert_eq!(run(core, "D 555352304e6757456641454a6673"), "OK USR 320636799581945856\n");
            assert_eq!(run(core, "D -"), "ERR LENGTH\n");
            assert_eq!(run(core, "H 274557032793636864"), "OK 234878118\n");
            assert_eq!(run(core, "U 274557032793636864"), "OK 1769526697641\n");
            assert_eq!(run(core, "F 274557032793636864"), "OK 65459497641 0 0\n");
            assert_eq!(run(core, "N 686f737461 100"), "OK 585\n");
            assert_eq!(run(core, "N - 101"), "OK 559\n");
        }
    }

    #[test]
    fn malformed_requests_are_reported() {
        let (mut buf, mut out) = (Vec::new(), Vec::new());
        for bad in ["X 1", "E 55 x", "E 5", "D 5", "D zz", "H", "H 1 2", "N - -1"] {
            assert!(respond(&SPEED, bad, &mut buf, &mut out).is_err(), "{bad}");
        }
    }
}
