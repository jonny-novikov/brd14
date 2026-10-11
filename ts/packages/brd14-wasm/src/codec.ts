// codec.ts — the brd14 API over the WebAssembly ABI.
//
// Every classification is the module's: this file maps JavaScript values onto the
// ABI's integers and bytes and maps its status codes back to the error classes of
// the pure package, so that `encode`, `decode`, `check`, `isValid` and `hash32`
// here return or throw exactly what `brd14` does for every input (the test suite
// checks that differentially). The batch entry points chunk at BATCH_MAX.
//
// How JavaScript values reach the ABI (docs/contract.md § The WebAssembly ABI):
//
//   namespace  a string → its UTF-8 bytes packed little-endian, `b0 | b1<<8 | b2<<16`.
//              Three ASCII chars pack directly (the hot path: bytes == chars). Anything
//              else is encoded first; three bytes pack as they are (a byte ≥ 0x80 is not
//              A-Z, so the module answers NAMESPACE), any other length sets the fourth
//              byte (1 << 24), which the module refuses as NAMESPACE. The loader never
//              judges a namespace itself.
//   snowflake  a bigint in [0, 2^63) → the same i64; anything outside → −1, which the
//              module refuses as RANGE after the namespace (the ABI's precedence). The
//              explicit mapping matters: a bigint ≥ 2^64 would otherwise wrap into range.
//   id         a string of 14 ASCII chars → its 14 bytes at io[0..14]; any other string
//              → its UTF-8 bytes (the contract classifies strings on those). Bytes are
//              copied as they are, `len` passed as is, up to the IO size; longer input is
//              LENGTH without a call (the module could not see it).
//   hash32     a bigint → ToBigInt64 wraps it modulo 2^64: the contract's "full u64".

import { ErrorCode, InvalidIdError, MAX_SNOW, type ErrorCode as Code, type RefusalCode } from "brd14";
import { BATCH_MAX, IO_LENGTH, abi, attach, io8, io64 } from "./module.ts";

const ID_LENGTH = 14;
/** The packed namespace of anything that is not three bytes: the fourth-byte rule. */
const NOT_THREE_BYTES = 1 << 24;

let encoder: TextEncoder | undefined;

function utf8(s: string): Uint8Array {
  encoder ??= new TextEncoder();
  return encoder.encode(s);
}

// ── mapping JS → ABI ────────────────────────────────────────────────────────
function packNsBytes(b: Uint8Array): number {
  return b.length === 3 ? b[0]! | (b[1]! << 8) | (b[2]! << 16) : NOT_THREE_BYTES;
}

/** The namespace as the ABI's packed i32. */
function packNs(ns: string): number {
  if (ns.length === 3) {
    const a = ns.charCodeAt(0);
    const b = ns.charCodeAt(1);
    const c = ns.charCodeAt(2);
    if ((a | b | c) < 128) return a | (b << 8) | (c << 16);
  }
  return packNsBytes(utf8(ns));
}

/** The snowflake as the ABI's i64: itself in [0, 2^63), −1 outside. */
function toI64(snow: bigint): bigint {
  return snow < 0n || snow > MAX_SNOW ? -1n : snow;
}

/** Copies `b` to io[0..] and decodes it; LENGTH without a call when it cannot fit. */
function decodeBytes(b: Uint8Array): bigint {
  if (b.length > IO_LENGTH) return -1n;
  io8.set(b);
  return abi.decode(b.length);
}

/** 14 ASCII chars go straight into the region; anything else is classified as UTF-8 bytes. */
function decodeString(id: string): bigint {
  if (id.length === ID_LENGTH) {
    let acc = 0;
    for (let i = 0; i < ID_LENGTH; i++) {
      const c = id.charCodeAt(i);
      acc |= c;
      io8[i] = c;
    }
    if (acc < 128) return abi.decode(ID_LENGTH);
  }
  return decodeBytes(utf8(id));
}

function decodeAny(id: string | Uint8Array): bigint {
  return typeof id === "string" ? decodeString(id) : decodeBytes(id);
}

/** The 14-char id at io[o..o+14) as one flat string. */
function idAt(o: number): string {
  return String.fromCharCode(
    io8[o]!,
    io8[o + 1]!,
    io8[o + 2]!,
    io8[o + 3]!,
    io8[o + 4]!,
    io8[o + 5]!,
    io8[o + 6]!,
    io8[o + 7]!,
    io8[o + 8]!,
    io8[o + 9]!,
    io8[o + 10]!,
    io8[o + 11]!,
    io8[o + 12]!,
    io8[o + 13]!,
  );
}

// ── single operations ───────────────────────────────────────────────────────
export interface Decoded {
  ns: string;
  snow: bigint;
}

/**
 * Brands a snowflake: `ns` must be three characters of A-Z, `snow` in [0, 2^63).
 * Precedence NAMESPACE, then RANGE, applied by the module. Allocates the result only.
 */
export function encode(ns: string, snow: bigint): string {
  attach();
  const status = abi.encode(packNs(ns), toI64(snow));
  if (status !== 0) throw new InvalidIdError(status as RefusalCode);
  return idAt(0);
}

/**
 * The inverse of `encode`. Total: throws `InvalidIdError` and nothing else for every
 * string or byte input. Strings are classified on their UTF-8 bytes. The one BigInt
 * allocated is the result, which is the module's return value itself.
 */
export function decode(id: string | Uint8Array): Decoded {
  attach();
  const r = decodeAny(id);
  if (r < 0n) throw new InvalidIdError(Number(-r) as RefusalCode);
  return { ns: String.fromCharCode(io8[0]!, io8[1]!, io8[2]!), snow: r };
}

/** The contract class of `id`: 0 (OK) or the refusal code. Never throws. */
export function check(id: string | Uint8Array): Code {
  attach();
  const r = decodeAny(id);
  return r < 0n ? (Number(-r) as Code) : ErrorCode.OK;
}

export function isValid(id: string | Uint8Array): boolean {
  attach();
  return decodeAny(id) >= 0n;
}

/** fmix64's first half over the full u64: `k` is taken modulo 2^64. */
export function hash32(k: bigint): number {
  return abi.hash32(k) >>> 0;
}

// ── batches ─────────────────────────────────────────────────────────────────
/**
 * A batch of snowflakes. A `BigInt64Array` is copied into the module in one `set`;
 * a `BigUint64Array` likewise (its values ≥ 2^63 land as negative i64, which the
 * module refuses as RANGE); an array of bigints is mapped element by element.
 */
export type Snowflakes = BigInt64Array | BigUint64Array | readonly bigint[];

/** A batch of ids: an array of strings, or `n × 14` bytes laid end to end. */
export type Ids = readonly string[] | Uint8Array;

/**
 * What a batch operation throws: the class of the first invalid item and its index.
 * It is an `InvalidIdError` (same `name`, `code`, `className`), so one handler covers
 * both the single and the batch API.
 */
export class BatchInvalidIdError extends InvalidIdError {
  /** The position of the first invalid item in the input batch. */
  readonly index: number;

  constructor(code: RefusalCode, index: number) {
    super(code, `batch item ${index}`);
    this.index = index;
  }
}

/** The namespace, packed, after the module has admitted it (an `encode` of 0). */
function requireNs(ns: string): number {
  const packed = packNs(ns);
  const status = abi.encode(packed, 0n);
  if (status !== 0) throw new InvalidIdError(status as RefusalCode);
  return packed;
}

/** Loads `snows[base .. base+k)` into io64[0..k). */
function loadSnows(snows: Snowflakes, base: number, k: number): void {
  if (snows instanceof BigInt64Array || snows instanceof BigUint64Array) {
    io64.set(snows.subarray(base, base + k));
  } else {
    for (let i = 0; i < k; i++) io64[i] = toI64(snows[base + i]!);
  }
}

/**
 * Encodes every snowflake under `ns`; the result holds one id per input, in order.
 * The namespace is checked first, even for an empty batch, as `encode` would (NAMESPACE);
 * the first snowflake outside [0, 2^63) throws a `BatchInvalidIdError` (RANGE) naming
 * its index. Internally chunked at BATCH_MAX (2,978).
 */
export function encodeMany(ns: string, snows: Snowflakes): string[] {
  attach();
  const packed = requireNs(ns);
  const n = snows.length;
  const out = new Array<string>(n);
  for (let base = 0; base < n; base += BATCH_MAX) {
    const k = Math.min(BATCH_MAX, n - base);
    loadSnows(snows, base, k);
    const m = abi.encode_many(packed, k);
    if (m !== k) throw new BatchInvalidIdError(ErrorCode.RANGE, base + m);
    for (let i = 0, o = 8 * k; i < k; i++, o += ID_LENGTH) out[base + i] = idAt(o);
  }
  return out;
}

/**
 * `encodeMany` without strings: writes the `14 × n` id bytes at `out[offset..]` and
 * returns the number of bytes written. Throws a `RangeError` when the buffer is too
 * short, and the same errors as `encodeMany`; on a RANGE refusal every id before the
 * refused index has already been written.
 */
export function encodeManyInto(ns: string, snows: Snowflakes, out: Uint8Array, offset = 0): number {
  attach();
  const n = snows.length;
  if (!(offset >= 0 && offset + ID_LENGTH * n <= out.length)) {
    throw new RangeError("brd14-wasm: encodeManyInto needs 14 × n bytes at offset");
  }
  const packed = requireNs(ns);
  for (let base = 0; base < n; base += BATCH_MAX) {
    const k = Math.min(BATCH_MAX, n - base);
    loadSnows(snows, base, k);
    const m = abi.encode_many(packed, k);
    out.set(io8.subarray(8 * k, 8 * k + ID_LENGTH * m), offset + ID_LENGTH * base);
    if (m !== k) throw new BatchInvalidIdError(ErrorCode.RANGE, base + m);
  }
  return ID_LENGTH * n;
}

/** The number of ids in a batch; a byte batch must be whole ids. */
function countIds(ids: Ids): number {
  if (typeof ids === "object" && ids instanceof Uint8Array) {
    if (ids.length % ID_LENGTH !== 0) throw new RangeError("brd14-wasm: a byte batch must be a multiple of 14 bytes");
    return ids.length / ID_LENGTH;
  }
  return ids.length;
}

/**
 * Loads `ids[base .. base+k)` into io[0..14k). A string that is not 14 bytes of UTF-8
 * cannot be given to the module (its input is exactly 14n bytes), and is LENGTH by the
 * contract's precedence; its slot is zeroed and its index pushed to `lengthFaults`, so
 * the caller can override the module's answer for it.
 */
function loadIds(ids: Ids, base: number, k: number, lengthFaults: number[]): void {
  if (ids instanceof Uint8Array) {
    io8.set(ids.subarray(ID_LENGTH * base, ID_LENGTH * (base + k)));
    return;
  }
  for (let i = 0, o = 0; i < k; i++, o += ID_LENGTH) {
    const s = ids[base + i]!;
    if (s.length === ID_LENGTH) {
      let acc = 0;
      for (let j = 0; j < ID_LENGTH; j++) {
        const c = s.charCodeAt(j);
        acc |= c;
        io8[o + j] = c;
      }
      if (acc < 128) continue;
    }
    const b = utf8(s);
    if (b.length === ID_LENGTH) {
      io8.set(b, o);
    } else {
      io8.fill(0, o, o + ID_LENGTH);
      lengthFaults.push(i);
    }
  }
}

/** The index within the chunk of the first negative result at io[off..], or k. */
function firstRefusal(off: number, k: number): number {
  for (let i = 0, p = off + 7; i < k; i++, p += 8) {
    if (io8[p]! & 0x80) return i;
  }
  return k;
}

/**
 * Decodes `ids[base .. base+k)`, writes the module's results to `out[at..at+k)` and
 * returns the chunk index of the first invalid id, or k.
 */
function decodeChunk(ids: Ids, base: number, k: number, out: BigInt64Array, at: number, faults: number[]): number {
  faults.length = 0;
  loadIds(ids, base, k, faults);
  abi.decode_many(k);
  const off = (ID_LENGTH * k + 7) & ~7;
  out.set(io64.subarray(off >> 3, (off >> 3) + k), at);
  for (let i = 0; i < faults.length; i++) out[at + faults[i]!] = -1n;
  const bad = firstRefusal(off, k);
  return faults.length > 0 && faults[0]! < bad ? faults[0]! : bad;
}

/**
 * Decodes every id; the result holds one snowflake per input, in order (the
 * namespaces are the first three characters of the inputs). The first invalid id
 * throws a `BatchInvalidIdError` with its class and index; the ids after it are not
 * decoded. Internally chunked at BATCH_MAX (2,978).
 */
export function decodeMany(ids: Ids): BigInt64Array {
  attach();
  const n = countIds(ids);
  const out = new BigInt64Array(n);
  const faults: number[] = [];
  for (let base = 0; base < n; base += BATCH_MAX) {
    const k = Math.min(BATCH_MAX, n - base);
    const bad = decodeChunk(ids, base, k, out, base, faults);
    if (bad < k) throw new BatchInvalidIdError(Number(-out[base + bad]!) as RefusalCode, base + bad);
  }
  return out;
}

/**
 * The status form of `decodeMany`: never throws for invalid ids. Writes the module's
 * own convention at `out[offset + i]` — the snowflake (≥ 0), or `−code` (−1..−4) for
 * an invalid id — for every input, and returns the index of the first invalid id, or
 * −1 when all are valid. Throws a `RangeError` when `out` is too short.
 */
export function decodeManyInto(ids: Ids, out: BigInt64Array, offset = 0): number {
  attach();
  const n = countIds(ids);
  if (!(offset >= 0 && offset + n <= out.length)) {
    throw new RangeError("brd14-wasm: decodeManyInto needs n slots at offset");
  }
  const faults: number[] = [];
  let first = -1;
  for (let base = 0; base < n; base += BATCH_MAX) {
    const k = Math.min(BATCH_MAX, n - base);
    const bad = decodeChunk(ids, base, k, out, offset + base, faults);
    if (bad < k && first < 0) first = base + bad;
  }
  return first;
}

/**
 * The class of every id, as `check` would report it, without a BigInt: `0` (OK) or
 * the refusal code per input. Never throws for invalid ids.
 */
export function checkMany(ids: Ids): Uint8Array {
  attach();
  const n = countIds(ids);
  const codes = new Uint8Array(n);
  const faults: number[] = [];
  for (let base = 0; base < n; base += BATCH_MAX) {
    const k = Math.min(BATCH_MAX, n - base);
    faults.length = 0;
    loadIds(ids, base, k, faults);
    abi.decode_many(k);
    const off = (ID_LENGTH * k + 7) & ~7;
    // a refusal is a small negative i64: sign bit set, code = 256 − low byte
    for (let i = 0, p = off; i < k; i++, p += 8) {
      if (io8[p + 7]! & 0x80) codes[base + i] = 256 - io8[p]!;
    }
    for (let i = 0; i < faults.length; i++) codes[base + faults[i]!] = ErrorCode.LENGTH;
  }
  return codes;
}
