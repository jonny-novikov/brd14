//! Differential properties: the speed core, the memory core and an independent reference
//! (u128 Horner sums, `position()` lookups, a numeric range guard — none of the cores'
//! tricks) must agree byte for byte.

use brd14::{ALPHABET, Error, LEN, MAX_SNOW, NS_LEN, memory, node_from, speed};

type Encode = fn(&[u8; NS_LEN], u64) -> Result<[u8; LEN], Error>;
type Decode = fn(&[u8]) -> Result<([u8; NS_LEN], u64), Error>;
const CORES: [(&str, Encode, Decode); 2] =
    [("speed", speed::encode, speed::decode), ("memory", memory::encode, memory::decode)];

/// Scale a loop count down under Miri, which interprets every instruction.
const fn scaled(n: usize, miri: usize) -> usize {
    if cfg!(miri) { miri } else { n }
}

/// The oracle's deterministic stream (tools/oracle.py `SplitMix64`).
struct SplitMix64(u64);

impl SplitMix64 {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n // bias is irrelevant for a property test
    }
    fn ns(&mut self) -> [u8; 3] {
        [0; 3].map(|_| b'A' + self.below(26) as u8)
    }
}

fn ref_ns_ok(ns: &[u8]) -> bool {
    ns.len() == NS_LEN && ns.iter().all(u8::is_ascii_uppercase)
}

fn ref_encode(ns: &[u8], snow: u64) -> Result<Vec<u8>, Error> {
    if !ref_ns_ok(ns) {
        return Err(Error::Namespace);
    }
    if snow > MAX_SNOW {
        return Err(Error::Range);
    }
    let mut digits = Vec::new();
    let mut v = snow as u128;
    for _ in 0..11 {
        digits.push(ALPHABET[(v % 62) as usize]);
        v /= 62;
    }
    assert_eq!(v, 0);
    digits.reverse();
    Ok([ns, &digits].concat())
}

fn ref_decode(id: &[u8]) -> Result<([u8; 3], u64), Error> {
    if id.len() != LEN {
        return Err(Error::Length);
    }
    if !ref_ns_ok(&id[..3]) {
        return Err(Error::Namespace);
    }
    let mut v: u128 = 0;
    for &b in &id[3..] {
        let Some(d) = ALPHABET.iter().position(|&c| c == b) else { return Err(Error::Charset) };
        v = v * 62 + d as u128;
    }
    if v > MAX_SNOW as u128 {
        return Err(Error::Range);
    }
    Ok((id[..3].try_into().unwrap(), v as u64))
}

/// Encode through both cores and the reference; all three must agree.
fn check_encode(ns: &[u8], snow: u64) -> Result<Vec<u8>, Error> {
    let want = ref_encode(ns, snow);
    let ns3: [u8; 3] = ns.try_into().unwrap();
    for (core, encode, _) in CORES {
        assert_eq!(encode(&ns3, snow).map(|b| b.to_vec()), want, "{core} encode({ns:?}, {snow})");
    }
    want
}

fn check_decode(id: &[u8]) -> Result<([u8; 3], u64), Error> {
    let want = ref_decode(id);
    for (core, _, decode) in CORES {
        assert_eq!(decode(id), want, "{core} decode({id:?})");
    }
    want
}

#[test]
fn every_byte_at_every_position() {
    // Exhaustive 256-value classification at each of the 14 positions, around four seeds
    // that sit at the corners of the domain (the parity driver's seeds).
    let seeds: &[&[u8; 14]] = if cfg!(miri) {
        &[b"ZZZAzL8n0Y58m7"]
    } else {
        &[b"USR0KHTOWnGLuC", b"ZZZAzL8n0Y58m7", b"ABC00000000000", b"SESzzzzzzzzzzz"]
    };
    for seed in seeds {
        for pos in 0..LEN {
            for byte in 0..=255u8 {
                let mut id = **seed;
                id[pos] = byte;
                let got = check_decode(&id);
                if pos >= NS_LEN {
                    // every seed is otherwise well-formed: the payload byte alone decides CHARSET
                    assert_eq!(got == Err(Error::Charset), !ALPHABET.contains(&byte), "{id:?}");
                }
            }
        }
    }
}

#[test]
fn the_62_digit_mapping() {
    for d in 0..62u64 {
        for (core, encode, decode) in CORES {
            let id = encode(b"DIG", d).unwrap();
            assert_eq!(id[13], ALPHABET[d as usize], "{core}");
            assert!(id[3..13].iter().all(|&c| c == b'0'), "{core}");
            assert_eq!(decode(&id), Ok((*b"DIG", d)), "{core}");
            // the same digit at every payload position it can occupy
            let mut place = 1u64;
            for k in 0..11 {
                if let Some(v) = d.checked_mul(place).filter(|&v| v <= MAX_SNOW) {
                    let id = encode(b"DIG", v).unwrap();
                    assert_eq!(id[13 - k], ALPHABET[d as usize], "{core} d={d} k={k}");
                }
                place = place.saturating_mul(62);
            }
        }
    }
}

#[test]
fn splitmix_roundtrips_speed_equals_memory() {
    let n = scaled(1_000_000, 300);
    let mut rng = SplitMix64(0x0B4D_1400_0001);
    for _ in 0..n {
        let ns = rng.ns();
        let x = rng.next() >> 1;
        let a = speed::encode(&ns, x).unwrap();
        let b = memory::encode(&ns, x).unwrap();
        assert_eq!(a, b, "encode({ns:?}, {x})");
        assert_eq!(speed::decode(&a), Ok((ns, x)));
        assert_eq!(memory::decode(&a), Ok((ns, x)));
    }
    // and the upper half of u64 is RANGE in both, never a wrong id
    for _ in 0..scaled(100_000, 50) {
        let x = rng.next() | 1 << 63;
        assert_eq!(speed::encode(b"RNG", x), Err(Error::Range));
        assert_eq!(memory::encode(b"RNG", x), Err(Error::Range));
    }
}

#[test]
fn reference_agreement_on_random_values() {
    let mut rng = SplitMix64(7);
    for _ in 0..scaled(50_000, 100) {
        let snow = rng.next() >> rng.below(64);
        let ns = rng.ns();
        let id = check_encode(&ns, snow);
        if let Ok(id) = id {
            assert_eq!(check_decode(&id), Ok((ns, snow)));
        }
    }
}

#[test]
fn boundaries() {
    let mut values = vec![0, 1, 61, 62, 3843, 3844, MAX_SNOW - 1, MAX_SNOW, 1 << 63, (1 << 63) + 1, u64::MAX];
    values.extend([1 << 22, (1 << 41) - 1, ((1u64 << 41) - 1) << 22]);
    for k in 1..=10u32 {
        let p = 62u64.pow(k);
        values.extend([p - 1, p, p + 1]);
    }
    // the split point and the arithmetic guard's corner (QA, RB)
    let p6 = 62u64.pow(6);
    let (qa, rb) = (memory::QA as u64, memory::RB);
    values.extend([p6 - 1, p6, qa * p6, qa * p6 + rb, qa * p6 + rb + 1, (qa - 1) * p6 + p6 - 1]);
    for &v in &values {
        let id = check_encode(b"USR", v);
        assert_eq!(id.is_ok(), v <= MAX_SNOW, "{v}");
        if let Ok(id) = id {
            assert_eq!(check_decode(&id), Ok((*b"USR", v)));
        }
    }
    // decode across the top: every payload within 64 of base62(2^63 - 1), both sides
    for delta in -64i128..=64 {
        let v = MAX_SNOW as i128 + delta;
        let mut digits = [b'0'; 11];
        let mut x = v as u128;
        for d in digits.iter_mut().rev() {
            *d = ALPHABET[(x % 62) as usize];
            x /= 62;
        }
        let id = [&b"RNG"[..], &digits].concat();
        let want = if delta <= 0 { Ok((*b"RNG", v as u64)) } else { Err(Error::Range) };
        assert_eq!(check_decode(&id), want, "{v}");
    }
    assert_eq!(check_decode(b"USRAzL8n0Y58m7"), Ok((*b"USR", MAX_SNOW)));
    assert_eq!(check_decode(b"USRAzL8n0Y58m8"), Err(Error::Range));
    assert_eq!(check_decode(b"USRB0000000000"), Err(Error::Range));
    assert_eq!(check_decode(b"USRzzzzzzzzzzz"), Err(Error::Range));
}

#[test]
fn byte_order_is_numeric_order() {
    // V-7: every alphabet index in the low digit, plus carries and the top
    let mut snows: Vec<u64> = (0..62).collect();
    snows.extend([62, 3843, 3844, 1 << 22, MAX_SNOW]);
    for (core, encode, _) in CORES {
        let ids: Vec<_> = snows.iter().map(|&s| encode(b"SES", s).unwrap()).collect();
        assert!(ids.windows(2).all(|w| w[0] < w[1]), "{core}");
    }
    let mut rng = SplitMix64(11);
    let mut pairs: Vec<(u64, [u8; 14])> = (0..scaled(20_000, 50))
        .map(|_| rng.next() >> 1)
        .map(|s| (s, speed::encode(b"ORD", s).unwrap()))
        .collect();
    pairs.sort_by_key(|p| p.1);
    assert!(pairs.windows(2).all(|w| w[0].0 <= w[1].0));
}

#[test]
fn precedence_multi_fault() {
    // encode: NAMESPACE beats RANGE, for every bad-namespace shape
    for ns in [b"usr", b"US\0", b"\xff\xff\xff", b"U1R", b"[[[", b"@@@"] {
        for snow in [1 << 63, u64::MAX] {
            for (core, encode, _) in CORES {
                assert_eq!(encode(ns, snow), Err(Error::Namespace), "{core} {ns:?}");
            }
        }
    }
    // decode: LENGTH beats everything
    for n in (0..=40).filter(|&n| n != LEN) {
        assert_eq!(check_decode(&vec![b'!'; n]), Err(Error::Length));
        assert_eq!(check_decode(&b"usrzzzzzzzzz!!!!!!!!!!!!!!!!!"[..n.min(29)]).err(), Some(Error::Length));
    }
    // NAMESPACE beats CHARSET and RANGE; CHARSET beats RANGE
    assert_eq!(check_decode(b"usr0KHTOWnGL!!"), Err(Error::Namespace));
    assert_eq!(check_decode(b"usrzzzzzzzzzzz"), Err(Error::Namespace));
    assert_eq!(check_decode(b"USRzzzzzzzzzz!"), Err(Error::Charset));
    assert_eq!(check_decode(b"USR!zzzzzzzzzz"), Err(Error::Charset));
    // the parity driver's multi-fault probe: lowercase namespace + random payload bytes
    let mut rng = SplitMix64(0x0B4D_14FF);
    for _ in 0..scaled(20_000, 50) {
        let mut id = [0u8; 14];
        let ns = rng.ns();
        id[..3].copy_from_slice(&ns.map(|c| c | 0x20));
        id[3..].iter_mut().for_each(|b| *b = rng.next() as u8);
        assert_eq!(check_decode(&id), Err(Error::Namespace));
        // and with the namespace repaired, CHARSET or RANGE or OK, all agreeing
        id[..3].copy_from_slice(&ns);
        let _ = check_decode(&id);
    }
}

#[test]
fn decode_is_total_on_noise() {
    let mut rng = SplitMix64(0xDEC0DE);
    for _ in 0..scaled(100_000, 100) {
        let n = rng.below(21) as usize;
        let id: Vec<u8> = (0..n).map(|_| rng.next() as u8).collect();
        let _ = check_decode(&id);
    }
}

#[test]
fn node_from_matches_an_allocating_reference() {
    fn reference(host: &[u8], pid: u32) -> u16 {
        let mut h: u32 = 0x811C_9DC5;
        for &b in host.iter().chain(pid.to_string().as_bytes()) {
            h ^= b as u32;
            h = h.wrapping_mul(0x0100_0193);
        }
        (h & 1023) as u16
    }
    let mut rng = SplitMix64(0x0DE);
    for pid in [0, 1, 9, 10, 99, 100, 4242, u32::MAX] {
        assert_eq!(node_from(b"hosta", pid), reference(b"hosta", pid));
    }
    for _ in 0..scaled(20_000, 50) {
        let host: Vec<u8> = (0..rng.below(48)).map(|_| rng.next() as u8).collect();
        let pid = rng.next() as u32;
        assert_eq!(node_from(&host, pid), reference(&host, pid));
    }
}
