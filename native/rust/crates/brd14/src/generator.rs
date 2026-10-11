//! The snowflake generator and the minter seam (feature `std`).
//!
//! [`Generator`] mirrors the Go reference (and `EchoData.Snowflake`): one [`AtomicU64`] cell
//! holds the monotonic part `ts << 12 | seq` (ts relative to [`EPOCH_MS`]). Each mint
//! CAS-advances the cell to `max(now_part, last + 1)` and returns
//! `ts << 22 | node << 12 | seq`. Consequences, proven by the tests below:
//!
//! * strictly increasing within one generator under every clock regime, across threads;
//! * a burst past 4096 ids/ms borrows into the timestamp — no blocking, no sleeping;
//! * a backward clock step keeps minting off the logical clock — no duplicates.
//!
//! [`Generator::next`] is lock-free and allocation-free. The clock is injectable through
//! [`Clock`] (any `Fn() -> u64` returning Unix milliseconds is one), so the properties are
//! tested against frozen, stepping and regressing clocks rather than the wall clock.

use core::fmt;
use core::sync::atomic::{AtomicU64, Ordering};

use crate::{EPOCH_MS, Error, LEN, NODE_MAX, NS_LEN, SEQ_BITS, SEQ_MAX, TS_SHIFT, node_from};

/// A source of the current time in Unix milliseconds.
pub trait Clock {
    /// Milliseconds since 1970-01-01T00:00:00Z.
    fn unix_ms(&self) -> u64;
}

/// The wall clock (`std::time::SystemTime`). A clock set before 1970 reads as `0`.
#[derive(Debug, Clone, Copy, Default)]
pub struct SystemClock;

impl Clock for SystemClock {
    #[inline]
    fn unix_ms(&self) -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
    }
}

impl<F: Fn() -> u64> Clock for F {
    #[inline]
    fn unix_ms(&self) -> u64 {
        self()
    }
}

/// The monotonic part of an instant: `(unix_ms − EPOCH_MS) << 12`, `0` before the epoch.
#[inline]
fn now_part(unix_ms: u64) -> u64 {
    unix_ms.saturating_sub(EPOCH_MS) << SEQ_BITS
}

/// A lock-free snowflake minter for one node. See the [module docs](self).
pub struct Generator<C: Clock = SystemClock> {
    cell: AtomicU64,
    node: u64,
    clock: C,
}

impl Generator<SystemClock> {
    /// A generator on the wall clock for `node` (masked to `0..=1023`).
    pub fn new(node: u16) -> Self {
        Self::with_clock(node, SystemClock)
    }

    /// A generator on the wall clock for the coordination-free [`default_node`].
    pub fn with_default_node() -> Self {
        Self::new(default_node())
    }
}

impl<C: Clock> Generator<C> {
    /// A generator for `node` (masked to `0..=1023`) reading time from `clock`.
    pub fn with_clock(node: u16, clock: C) -> Self {
        let cell = AtomicU64::new(now_part(clock.unix_ms()));
        Generator { cell, node: (node & NODE_MAX) as u64, clock }
    }

    /// The 10-bit node id stamped into every snowflake.
    #[inline]
    pub fn node(&self) -> u16 {
        self.node as u16
    }

    /// Mint the next snowflake: strictly greater than every one this generator minted before.
    #[inline]
    pub fn next(&self) -> u64 {
        let v = self.advance(now_part(self.clock.unix_ms()));
        (v >> SEQ_BITS) << TS_SHIFT | self.node << SEQ_BITS | (v & SEQ_MAX as u64)
    }

    /// Mint the next snowflake and brand it under `ns` (speed core).
    #[inline]
    pub fn next_branded(&self, ns: &[u8; NS_LEN]) -> Result<[u8; LEN], Error> {
        crate::encode(ns, self.next())
    }

    /// CAS the cell forward to `max(cand, last + 1)` and return the new value.
    #[inline]
    fn advance(&self, cand: u64) -> u64 {
        let mut last = self.cell.load(Ordering::Relaxed);
        loop {
            let next = cand.max(last.wrapping_add(1));
            match self.cell.compare_exchange_weak(last, next, Ordering::AcqRel, Ordering::Relaxed) {
                Ok(_) => return next,
                Err(seen) => last = seen,
            }
        }
    }
}

impl<C: Clock> fmt::Debug for Generator<C> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let cell = self.cell.load(Ordering::Relaxed);
        f.debug_struct("Generator")
            .field("node", &self.node)
            .field("ts", &(cell >> SEQ_BITS))
            .field("seq", &(cell & SEQ_MAX as u64))
            .finish()
    }
}

/// The host name as Go's `os.Hostname` reads it on Linux (`/proc/sys/kernel/hostname`),
/// falling back to `$HOSTNAME` / `$COMPUTERNAME`, else empty.
fn hostname() -> std::string::String {
    if let Ok(s) = std::fs::read_to_string("/proc/sys/kernel/hostname") {
        let s = s.trim_end_matches('\n');
        if !s.is_empty() {
            return s.into();
        }
    }
    std::env::var("HOSTNAME").or_else(|_| std::env::var("COMPUTERNAME")).unwrap_or_default()
}

/// A coordination-free node id: [`node_from`]`(hostname, pid)`, as Go's `DefaultNode`.
/// Reads the host name once (this allocates; minting does not).
pub fn default_node() -> u16 {
    node_from(hostname().as_bytes(), std::process::id())
}

/// Why [`Minter::mint`] refused: the gate's own error, unchanged, or a codec refusal.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MintError<E> {
    /// The gate refused the namespace; its error is passed through verbatim.
    Refused(E),
    /// The gate admitted the namespace but the codec refused it (shape or range).
    Invalid(Error),
}

impl<E: fmt::Display> fmt::Display for MintError<E> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MintError::Refused(e) => e.fmt(f),
            MintError::Invalid(e) => e.fmt(f),
        }
    }
}

impl<E: fmt::Debug + fmt::Display> core::error::Error for MintError<E> {}

/// The open gate: every namespace passes policy; the codec's shape check still applies.
pub fn allow_all(_: &[u8]) -> Result<(), core::convert::Infallible> {
    Ok(())
}

/// A [`Generator`] plus one policy decision (`docs/contract.md`, "The minter").
///
/// The gate runs **first**, on the raw namespace, and its refusal reaches the caller
/// unchanged; only an admitted namespace reaches `encode`, whose shape check still applies.
/// Pass [`allow_all`] for "no policy" — never "no validation".
pub struct Minter<'g, C: Clock, G> {
    generator: &'g Generator<C>,
    gate: G,
}

impl<'g, C: Clock, G, E> Minter<'g, C, G>
where
    G: Fn(&[u8]) -> Result<(), E>,
{
    /// A minter over `generator`, governed by `gate`.
    pub fn new(generator: &'g Generator<C>, gate: G) -> Self {
        Minter { generator, gate }
    }

    /// Gate `ns`, then brand the next snowflake under it.
    pub fn mint(&self, ns: &[u8]) -> Result<[u8; LEN], MintError<E>> {
        self.mint_snowflake(ns).map(|(id, _)| id)
    }

    /// As [`mint`](Self::mint), also returning the snowflake behind the id.
    pub fn mint_snowflake(&self, ns: &[u8]) -> Result<([u8; LEN], u64), MintError<E>> {
        (self.gate)(ns).map_err(MintError::Refused)?;
        let ns: &[u8; NS_LEN] = ns.try_into().map_err(|_| MintError::Invalid(Error::Namespace))?;
        let snow = self.generator.next();
        crate::encode(ns, snow).map(|id| (id, snow)).map_err(MintError::Invalid)
    }

    /// The underlying generator: the ungated path, named so every bypass reads as one.
    pub fn generator(&self) -> &'g Generator<C> {
        self.generator
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{decode, fields, unix_ms};
    use std::sync::Arc;
    use std::sync::atomic::AtomicU64;
    use std::vec::Vec;

    /// A clock the test moves by hand.
    fn manual(start: u64) -> (Arc<AtomicU64>, impl Fn() -> u64 + Send + Sync) {
        let t = Arc::new(AtomicU64::new(start));
        let c = Arc::clone(&t);
        (t, move || c.load(Ordering::SeqCst))
    }

    const T0: u64 = EPOCH_MS + 1_000_000;

    #[test]
    fn layout_and_first_mint() {
        let (_, clock) = manual(T0);
        let g = Generator::with_clock(5, clock);
        let s = g.next();
        // the cell starts at now_part, so the first mint in the same ms is seq 1 (as Go)
        assert_eq!(fields(s), (1_000_000, 5, 1));
        assert_eq!(unix_ms(s), T0);
        assert!(s < 1 << 63);
    }

    #[test]
    fn node_is_masked_and_stamped() {
        let (_, clock) = manual(T0);
        let g = Generator::with_clock(0xFFFF, clock);
        assert_eq!(g.node(), 1023);
        for _ in 0..100 {
            assert_eq!(fields(g.next()).1, 1023);
        }
    }

    #[test]
    fn burst_borrows_into_the_timestamp() {
        let (_, clock) = manual(T0);
        let g = Generator::with_clock(7, clock);
        let n = if cfg!(miri) { 4_200 } else { 50_000 };
        let mut prev = 0;
        for k in 1..=n as u64 {
            let s = g.next();
            assert!(s > prev, "not strictly increasing at mint {k}");
            prev = s;
            // a frozen clock: mint k is the cell's k-th successor of ts0 << 12
            let (ts, node, seq) = fields(s);
            assert_eq!((ts, node, seq), (1_000_000 + k / 4096, 7, (k % 4096) as u16));
        }
    }

    #[test]
    fn forward_step_resets_the_sequence() {
        let (t, clock) = manual(T0);
        let g = Generator::with_clock(1, clock);
        g.next();
        g.next();
        t.store(T0 + 10, Ordering::SeqCst);
        assert_eq!(fields(g.next()), (1_000_010, 1, 0));
        assert_eq!(fields(g.next()), (1_000_010, 1, 1));
    }

    #[test]
    fn backward_step_keeps_minting_off_the_logical_clock() {
        let (t, clock) = manual(T0);
        let g = Generator::with_clock(2, clock);
        let before = g.next();
        t.store(T0 - 5_000, Ordering::SeqCst); // the wall clock jumps back 5 s
        let mut prev = before;
        for _ in 0..10_000 {
            let s = g.next();
            assert!(s > prev);
            prev = s;
        }
        // still on the logical clock, which the burst pushed past T0
        assert!(fields(prev).0 >= 1_000_000);
        t.store(T0 + 60_000, Ordering::SeqCst); // the wall clock overtakes again
        assert_eq!(fields(g.next()), (1_060_000, 2, 0));
    }

    #[test]
    fn pre_epoch_clock_still_mints() {
        let (_, clock) = manual(0);
        let g = Generator::with_clock(3, clock);
        assert_eq!(fields(g.next()), (0, 3, 1));
        assert_eq!(fields(g.next()), (0, 3, 2));
    }

    #[test]
    fn concurrent_mints_are_unique_and_per_thread_increasing() {
        let (threads, per) = if cfg!(miri) { (3, 40) } else { (4, 25_000) };
        let (_, clock) = manual(T0); // frozen: every id comes from the borrow path
        let g = Arc::new(Generator::with_clock(9, clock));
        let handles: Vec<_> = (0..threads)
            .map(|_| {
                let g = Arc::clone(&g);
                std::thread::spawn(move || {
                    let v: Vec<u64> = (0..per).map(|_| g.next()).collect();
                    assert!(v.windows(2).all(|w| w[0] < w[1]));
                    v
                })
            })
            .collect();
        let mut all: Vec<u64> = handles.into_iter().flat_map(|h| h.join().unwrap()).collect();
        all.sort_unstable();
        all.dedup();
        assert_eq!(all.len(), threads * per);
        // a frozen clock and no gaps: exactly the first threads*per successors of the cell
        let first = fields(all[0]);
        assert_eq!(first, (1_000_000, 9, 1));
    }

    #[test]
    fn wall_clock_generator() {
        let g = Generator::new(42);
        let before = SystemClock.unix_ms();
        let a = g.next();
        let b = g.next();
        let after = SystemClock.unix_ms();
        assert!(a < b);
        // a may sit 1 ms ahead of its wall instant only through the seq borrow
        assert!(unix_ms(a) >= before && unix_ms(a) <= after + 1);
        let id = g.next_branded(b"USR").unwrap();
        let (ns, s) = decode(&id).unwrap();
        assert_eq!(&ns, b"USR");
        assert!(s > b);
        assert_eq!(g.next_branded(b"usr"), Err(Error::Namespace));
    }

    #[test]
    fn default_node_is_node_from_host_and_pid() {
        assert_eq!(default_node(), node_from(hostname().as_bytes(), std::process::id()));
        assert!(Generator::with_default_node().node() <= NODE_MAX);
        let dbg = std::format!("{:?}", Generator::with_clock(4, || T0));
        assert!(dbg.contains("node: 4"), "{dbg}");
    }

    #[test]
    fn minter_is_gate_first() {
        let (_, clock) = manual(T0);
        let g = Generator::with_clock(1, clock);
        let census = |ns: &[u8]| if ns == b"USR" || ns == b"usr" { Ok(()) } else { Err("not in the census") };
        let m = Minter::new(&g, census);
        let (id, snow) = m.mint_snowflake(b"USR").unwrap();
        assert_eq!(decode(&id), Ok((*b"USR", snow)));
        // the gate's refusal arrives unchanged, before any shape check
        assert_eq!(m.mint(b"log"), Err(MintError::Refused("not in the census")));
        assert_eq!(m.mint(b"TOOLONG"), Err(MintError::Refused("not in the census")));
        // admitted by policy, refused by the codec
        assert_eq!(m.mint(b"usr"), Err(MintError::Invalid(Error::Namespace)));
        let open = Minter::new(&g, allow_all);
        assert!(open.mint(b"ZZZ").is_ok());
        assert_eq!(open.mint(b"ZZ"), Err(MintError::Invalid(Error::Namespace)));
        assert!(open.generator().next() > snow);
        assert_eq!(std::format!("{}", MintError::<&str>::Refused("nope")), "nope");
    }
}
