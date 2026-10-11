// codec.ts — encode, decode and the derived reads, with exact 64-bit
// arithmetic and no BigInt on the hot path.
//
// A snowflake lives in [0, 2^63). A JS Number holds 53 bits exactly, so the
// value is carried as two u32 halves (hi, lo) and every intermediate product
// or sum is kept below 2^53, where IEEE doubles are integers. The one place a
// BigInt is touched is the boundary of the bigint-typed API: one
// DataView.setBigUint64 to split the input, one getBigUint64 to build the
// result. The parts APIs (ts/node/seq Numbers) never touch BigInt at all.
//
// docs/typescript.md carries the proofs; the comments here name the bounds.

import { ErrorCode, InvalidIdError, type ErrorCode as Code } from "./errors.ts";

/** The base62 alphabet, ASCII order: byte order == numeric order. */
export const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
/** 2024-01-01T00:00:00Z */
export const EPOCH_MS = 1_704_067_200_000;
/** 3-byte namespace + 11-byte payload. */
export const ID_LENGTH = 14;
/** 2^63 − 1, the largest encodable snowflake. */
export const MAX_SNOW = 9223372036854775807n;
/** base62(2^63 − 1). */
export const MAX_PAYLOAD = "AzL8n0Y58m7";
/** 2^41 − 1: the largest `ts` field. */
export const MAX_TS = 2199023255551;

// The arithmetic range guard: 2^63 − 1 = QA·62^6 + RB.
const QA = 162382637;
const RB = 503620799;

const P62_2 = 3844; // 62^2
const P62_4 = 14776336; // 62^4
const TWO_32 = 4294967296;
const TWO_22 = 4194304;
// 62^6 = A22·2^22 + B22, B22 < 2^22. Used to split a decoded (hi5, lo6) into ts and the low 22 bits.
const A22 = 13542;
const B22 = 970816;

// ── tables ──────────────────────────────────────────────────────────────────
/** CODE[d] = the ASCII code of digit d. */
const CODE = new Uint8Array(62);
/** DIGIT[c] = the digit value of ASCII code c, or -1. */
const DIGIT = new Int8Array(256).fill(-1);
/** PAIR_HI[p], PAIR_LO[p] = the two ASCII codes of pair value p in [0, 3844). */
const PAIR_HI = new Uint8Array(P62_2);
const PAIR_LO = new Uint8Array(P62_2);
for (let i = 0; i < 62; i++) {
  const c = ALPHABET.charCodeAt(i);
  CODE[i] = c;
  DIGIT[c] = i;
}
for (let p = 0; p < P62_2; p++) {
  PAIR_HI[p] = CODE[(p / 62) | 0]!;
  PAIR_LO[p] = CODE[p % 62]!;
}

// Scratch state. Module-level, never shared across async boundaries: every
// public function reads what it wrote before returning.
const view = new DataView(new ArrayBuffer(8));
/** The eleven payload digits as one leading digit and five pairs: [d0, p1, p2, p3, p4, p5]. */
const S = new Int32Array(6);
// The last successful parse: value of the first five digits and of the last six.
let h5 = 0;
let l6 = 0;

let encoder: TextEncoder | undefined;

// ── namespace ───────────────────────────────────────────────────────────────
function upper(c: number): boolean {
  return c >= 65 && c <= 90;
}

/** True when `ns` is exactly three characters of A-Z. */
export function isNamespace(ns: string): boolean {
  return ns.length === 3 && upper(ns.charCodeAt(0)) && upper(ns.charCodeAt(1)) && upper(ns.charCodeAt(2));
}

function requireNamespace(ns: string): void {
  if (!isNamespace(ns)) throw new InvalidIdError(ErrorCode.NAMESPACE);
}

// ── encode: halves → digits ─────────────────────────────────────────────────
/**
 * Splits v = hi·2^32 + lo (hi < 2^31) into S. One long-division step by 3844
 * peels the low pair; the quotient q < 2^52 is then split at 62^4 into int32
 * work. Every intermediate is < 2^53 and every Math.floor is exact.
 */
function split(hi: number, lo: number): void {
  const qh = Math.floor(hi / P62_2); // < 2^31 / 3844 < 558,695
  const t = (hi - qh * P62_2) * TWO_32 + lo; // < 3844·2^32 < 2^44
  const ql = Math.floor(t / P62_2); // < 2^32
  S[5] = t - ql * P62_2; // the low pair: v mod 3844
  const q = qh * TWO_32 + ql; // floor(v / 3844) < 2^52
  const q1 = Math.floor(q / P62_4); // < 62^5 < 2^30: the top five digits
  const r1 = q - q1 * P62_4; // < 62^4: two pairs
  const a = (q1 / P62_2) | 0; // < 62^3
  S[2] = q1 - a * P62_2;
  const b = (a / P62_2) | 0; // < 62
  S[1] = a - b * P62_2;
  S[0] = b;
  const p = (r1 / P62_2) | 0; // < 3844
  S[4] = r1 - p * P62_2;
  S[3] = p;
}

function build(c0: number, c1: number, c2: number): string {
  return String.fromCharCode(
    c0,
    c1,
    c2,
    CODE[S[0]!]!,
    PAIR_HI[S[1]!]!,
    PAIR_LO[S[1]!]!,
    PAIR_HI[S[2]!]!,
    PAIR_LO[S[2]!]!,
    PAIR_HI[S[3]!]!,
    PAIR_LO[S[3]!]!,
    PAIR_HI[S[4]!]!,
    PAIR_LO[S[4]!]!,
    PAIR_HI[S[5]!]!,
    PAIR_LO[S[5]!]!,
  );
}

function writeInto(buf: Uint8Array, o: number, c0: number, c1: number, c2: number): void {
  buf[o] = c0;
  buf[o + 1] = c1;
  buf[o + 2] = c2;
  buf[o + 3] = CODE[S[0]!]!;
  buf[o + 4] = PAIR_HI[S[1]!]!;
  buf[o + 5] = PAIR_LO[S[1]!]!;
  buf[o + 6] = PAIR_HI[S[2]!]!;
  buf[o + 7] = PAIR_LO[S[2]!]!;
  buf[o + 8] = PAIR_HI[S[3]!]!;
  buf[o + 9] = PAIR_LO[S[3]!]!;
  buf[o + 10] = PAIR_HI[S[4]!]!;
  buf[o + 11] = PAIR_LO[S[4]!]!;
  buf[o + 12] = PAIR_HI[S[5]!]!;
  buf[o + 13] = PAIR_LO[S[5]!]!;
}

/** Loads the halves of a bigint already known to be in [0, 2^63). */
function loadHalves(snow: bigint): void {
  view.setBigUint64(0, snow);
}

function requireSnow(snow: bigint): void {
  if (snow < 0n || snow > MAX_SNOW) throw new InvalidIdError(ErrorCode.RANGE);
}

/** Validates the three fields and leaves (hi, lo) in the view. */
function partsToHalves(ts: number, node: number, seq: number): void {
  if (
    !(ts >= 0 && ts <= MAX_TS && Math.floor(ts) === ts) ||
    (node | 0) !== node ||
    node < 0 ||
    node > 1023 ||
    (seq | 0) !== seq ||
    seq < 0 ||
    seq > 4095
  ) {
    throw new InvalidIdError(ErrorCode.RANGE, "field out of width");
  }
  const hi = Math.floor(ts / 1024); // < 2^31
  view.setUint32(0, hi);
  view.setUint32(4, (ts - hi * 1024) * TWO_22 + node * 4096 + seq); // < 2^32
}

/**
 * Brands a snowflake: `ns` must be three characters of A-Z, `snow` in
 * [0, 2^63). Precedence NAMESPACE, then RANGE. Allocates the result string only.
 */
export function encode(ns: string, snow: bigint): string {
  requireNamespace(ns);
  requireSnow(snow);
  loadHalves(snow);
  split(view.getUint32(0), view.getUint32(4));
  return build(ns.charCodeAt(0), ns.charCodeAt(1), ns.charCodeAt(2));
}

/**
 * Brands the snowflake `ts<<22 | node<<12 | seq` from its fields, without a
 * BigInt. Each field must be an integer within its width (41, 10, 12 bits);
 * otherwise RANGE.
 */
export function encodeParts(ns: string, ts: number, node: number, seq: number): string {
  requireNamespace(ns);
  partsToHalves(ts, node, seq);
  split(view.getUint32(0), view.getUint32(4));
  return build(ns.charCodeAt(0), ns.charCodeAt(1), ns.charCodeAt(2));
}

/**
 * Writes the 14 ASCII bytes of `encode(ns, snow)` at `buf[offset..offset+14)`
 * with no string allocation. Throws a RangeError when the buffer is too short.
 */
export function encodeInto(buf: Uint8Array, offset: number, ns: string, snow: bigint): void {
  if (!(offset >= 0 && offset + ID_LENGTH <= buf.length)) {
    throw new RangeError("brd14: encodeInto needs 14 bytes at offset");
  }
  requireNamespace(ns);
  requireSnow(snow);
  loadHalves(snow);
  split(view.getUint32(0), view.getUint32(4));
  writeInto(buf, offset, ns.charCodeAt(0), ns.charCodeAt(1), ns.charCodeAt(2));
}

/** `encodeInto` from fields: no BigInt and no string. */
export function encodePartsInto(buf: Uint8Array, offset: number, ns: string, ts: number, node: number, seq: number): void {
  if (!(offset >= 0 && offset + ID_LENGTH <= buf.length)) {
    throw new RangeError("brd14: encodePartsInto needs 14 bytes at offset");
  }
  requireNamespace(ns);
  partsToHalves(ts, node, seq);
  split(view.getUint32(0), view.getUint32(4));
  writeInto(buf, offset, ns.charCodeAt(0), ns.charCodeAt(1), ns.charCodeAt(2));
}

// ── decode: digits → (h5, l6) → fields / halves ─────────────────────────────
/**
 * Classifies 14 bytes and, on OK, leaves the first-five-digit value in h5 and
 * the last-six-digit value in l6. Precedence LENGTH, NAMESPACE, CHARSET, RANGE.
 */
function parseBytes(b: Uint8Array): Code {
  if (b.length !== ID_LENGTH) return ErrorCode.LENGTH;
  if (!(upper(b[0]!) && upper(b[1]!) && upper(b[2]!))) return ErrorCode.NAMESPACE;
  let h = 0;
  for (let i = 3; i < 8; i++) {
    const d = DIGIT[b[i]!]!;
    if (d < 0) return ErrorCode.CHARSET;
    h = h * 62 + d; // < 62^5 < 2^30
  }
  let l = 0;
  for (let i = 8; i < 14; i++) {
    const d = DIGIT[b[i]!]!;
    if (d < 0) return ErrorCode.CHARSET;
    l = l * 62 + d; // < 62^6 < 2^36
  }
  if (h > QA || (h === QA && l > RB)) return ErrorCode.RANGE;
  h5 = h;
  l6 = l;
  return ErrorCode.OK;
}

/**
 * The cold path for strings: the contract classifies on the UTF-8 bytes, so a
 * string that is not 14 ASCII characters is encoded first. Lone surrogates
 * encode as U+FFFD (three bytes), per the Encoding standard.
 */
function classifyString(id: string): Code {
  encoder ??= new TextEncoder();
  return parseBytes(encoder.encode(id));
}

/** The string fast path: 14 ASCII characters; anything else defers to the byte classifier. */
function parseString(id: string): Code {
  if (id.length !== ID_LENGTH) return classifyString(id);
  if (!(upper(id.charCodeAt(0)) && upper(id.charCodeAt(1)) && upper(id.charCodeAt(2)))) return classifyString(id);
  let h = 0;
  for (let i = 3; i < 8; i++) {
    const c = id.charCodeAt(i);
    const d = c < 128 ? DIGIT[c]! : -1;
    if (d < 0) return classifyString(id);
    h = h * 62 + d;
  }
  let l = 0;
  for (let i = 8; i < 14; i++) {
    const c = id.charCodeAt(i);
    const d = c < 128 ? DIGIT[c]! : -1;
    if (d < 0) return classifyString(id);
    l = l * 62 + d;
  }
  // All ASCII and 14 long: the bytes are the characters, so RANGE is final.
  if (h > QA || (h === QA && l > RB)) return ErrorCode.RANGE;
  h5 = h;
  l6 = l;
  return ErrorCode.OK;
}

function parse(id: string | Uint8Array): Code {
  return typeof id === "string" ? parseString(id) : parseBytes(id);
}

// After a successful parse: the fields of v = h5·62^6 + l6.
let pTs = 0;
let pLow22 = 0;

/** v = h5·(A22·2^22 + B22) + l6 → ts = h5·A22 + floor(w/2^22), low22 = w mod 2^22, w = h5·B22 + l6 < 2^51. */
function fieldsFromParse(): void {
  const w = h5 * B22 + l6;
  const wq = Math.floor(w / TWO_22);
  pLow22 = w - wq * TWO_22;
  pTs = h5 * A22 + wq; // ≤ 2^41 − 1
}

/** Leaves the halves of ts·2^22 + low22 in the view. */
function fieldsToHalves(ts: number, low22: number): void {
  const hi = Math.floor(ts / 1024);
  view.setUint32(0, hi);
  view.setUint32(4, (ts - hi * 1024) * TWO_22 + low22);
}

function nsOf(id: string | Uint8Array): string {
  return typeof id === "string" ? id.substring(0, 3) : String.fromCharCode(id[0]!, id[1]!, id[2]!);
}

export interface Decoded {
  ns: string;
  snow: bigint;
}

/** The three fields of a snowflake. */
export interface Parts {
  /** milliseconds since the epoch, 41 bits */
  ts: number;
  /** 10 bits */
  node: number;
  /** 12 bits */
  seq: number;
}

export interface DecodedParts extends Parts {
  ns: string;
}

/**
 * The inverse of `encode`. Total: throws `InvalidIdError` and nothing else for
 * every string or byte input. Strings are classified on their UTF-8 bytes.
 */
export function decode(id: string | Uint8Array): Decoded {
  const code = parse(id);
  if (code !== ErrorCode.OK) throw new InvalidIdError(code);
  fieldsFromParse();
  fieldsToHalves(pTs, pLow22);
  return { ns: nsOf(id), snow: view.getBigUint64(0) };
}

/**
 * Decodes into `out` without a BigInt: `out.ns`, `out.ts`, `out.node`,
 * `out.seq`. Returns `out`. The namespace string is the only allocation.
 */
export function decodePartsInto<T extends DecodedParts>(id: string | Uint8Array, out: T): T {
  const code = parse(id);
  if (code !== ErrorCode.OK) throw new InvalidIdError(code);
  fieldsFromParse();
  out.ns = nsOf(id);
  out.ts = pTs;
  out.node = pLow22 >>> 12;
  out.seq = pLow22 & 4095;
  return out;
}

/** The contract class of `id`: 0 (OK) or the refusal code. Never throws. */
export function check(id: string | Uint8Array): Code {
  return parse(id);
}

export function isValid(id: string | Uint8Array): boolean {
  return parse(id) === ErrorCode.OK;
}

// ── hash32 ──────────────────────────────────────────────────────────────────
const M_LO = 0xed558ccd;
const M_HI = 0xff51afd7;
const M_LO_0 = M_LO & 0xffff; // 0x8ccd
const M_LO_1 = M_LO >>> 16; // 0xed55

/**
 * MurmurHash3 fmix64, first half, on the u64 (hi, lo). `k >> 33` only touches
 * the low word (lo ^= hi >>> 1); the 64×64→64 multiply is Math.imul for the
 * low words plus an exact 32×32→64 high word from a 16-bit split.
 */
export function hash32Parts(hi: number, lo: number): number {
  hi >>>= 0;
  lo = (lo ^ (hi >>> 1)) >>> 0;
  const a0 = lo & 0xffff;
  const a1 = lo >>> 16;
  const low = a0 * M_LO_0; // < 2^32
  const mid = a1 * M_LO_0 + a0 * M_LO_1 + (low >>> 16); // < 2^33 + 2^16
  const mulhi = a1 * M_LO_1 + Math.floor(mid / 65536); // the exact high word of lo·M_LO
  const rLo = Math.imul(lo, M_LO) >>> 0;
  const rHi = (mulhi + (Math.imul(lo, M_HI) >>> 0) + (Math.imul(hi, M_LO) >>> 0)) >>> 0;
  return (rLo ^ (rHi >>> 1)) >>> 0;
}

/** `hash32` over the full u64: `k` is taken modulo 2^64. */
export function hash32(k: bigint): number {
  view.setBigUint64(0, k);
  return hash32Parts(view.getUint32(0), view.getUint32(4));
}

// ── derived reads ───────────────────────────────────────────────────────────
function loadDomain(snow: bigint): void {
  requireSnow(snow);
  view.setBigUint64(0, snow);
}

/** The mint instant: `(snow >> 22) + EPOCH_MS`. */
export function unixMs(snow: bigint): number {
  loadDomain(snow);
  return view.getUint32(0) * 1024 + (view.getUint32(4) >>> 22) + EPOCH_MS;
}

/** The ts/node/seq fields of a snowflake. */
export function fields(snow: bigint): Parts {
  loadDomain(snow);
  const lo = view.getUint32(4);
  return { ts: view.getUint32(0) * 1024 + (lo >>> 22), node: (lo >>> 12) & 1023, seq: lo & 4095 };
}

/** `ts<<22 | node<<12 | seq` as a bigint, from fields within their widths. */
export function snowFromParts(ts: number, node: number, seq: number): bigint {
  partsToHalves(ts, node, seq);
  return view.getBigUint64(0);
}

/** The smallest snowflake mintable at or after `ms`: the half-open lower bound for time-range scans. */
export function minFor(ms: number): bigint {
  const ts = ms - EPOCH_MS;
  if (!(ts >= 0 && ts <= MAX_TS && Math.floor(ts) === ts)) {
    throw new InvalidIdError(ErrorCode.RANGE, "instant outside the epoch window");
  }
  return snowFromParts(ts, 0, 0);
}

/**
 * FNV-32a over `host bytes ++ ASCII-decimal(pid)`, masked to 10 bits. A string
 * host hashes its UTF-8 bytes; an empty host hashes the pid alone.
 */
export function nodeFrom(host: string | Uint8Array, pid: number): number {
  if (!Number.isSafeInteger(pid) || pid < 0) throw new RangeError("brd14: pid must be a non-negative integer");
  let h = 0x811c9dc5 | 0;
  if (typeof host === "string") {
    encoder ??= new TextEncoder();
    host = encoder.encode(host);
  }
  for (let i = 0; i < host.length; i++) {
    h = Math.imul(h ^ host[i]!, 0x01000193);
  }
  const digits = String(pid);
  for (let i = 0; i < digits.length; i++) {
    h = Math.imul(h ^ digits.charCodeAt(i), 0x01000193);
  }
  return h & 1023;
}
