// naive.ts — the in-language oracle: the contract written the obvious way, on
// BigInt, sharing no arithmetic with src/codec.ts. The tests check the fast
// path against it on random inputs; the bench uses it as the baseline the
// hi/lo design is measured against.

import { ErrorCode, InvalidIdError, type RefusalCode } from "brd14";

const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const EPOCH_MS = 1_704_067_200_000n;
const MAX = (1n << 63n) - 1n;
const DIGIT = new Map<number, bigint>();
for (let i = 0; i < 62; i++) DIGIT.set(ALPHABET.charCodeAt(i), BigInt(i));

const encoder = new TextEncoder();

function nsOk(b: Uint8Array): boolean {
  return b.length === 3 && [...b].every((c) => c >= 65 && c <= 90);
}

export function naiveEncode(ns: string, snow: bigint): string {
  if (!nsOk(encoder.encode(ns))) throw new InvalidIdError(ErrorCode.NAMESPACE);
  if (snow < 0n || snow > MAX) throw new InvalidIdError(ErrorCode.RANGE);
  let v = snow;
  let payload = "";
  for (let i = 0; i < 11; i++) {
    payload = ALPHABET[Number(v % 62n)] + payload;
    v /= 62n;
  }
  return ns + payload;
}

/** The refusal class of a byte string, or 0. */
export function naiveCheck(id: string | Uint8Array): ErrorCode {
  const b = typeof id === "string" ? encoder.encode(id) : id;
  if (b.length !== 14) return ErrorCode.LENGTH;
  if (!nsOk(b.subarray(0, 3))) return ErrorCode.NAMESPACE;
  let v = 0n;
  for (let i = 3; i < 14; i++) {
    const d = DIGIT.get(b[i]!);
    if (d === undefined) return ErrorCode.CHARSET;
    v = v * 62n + d;
  }
  return v > MAX ? ErrorCode.RANGE : ErrorCode.OK;
}

export function naiveDecode(id: string | Uint8Array): { ns: string; snow: bigint } {
  const b = typeof id === "string" ? encoder.encode(id) : id;
  const code = naiveCheck(b);
  if (code !== ErrorCode.OK) throw new InvalidIdError(code as RefusalCode);
  let v = 0n;
  for (let i = 3; i < 14; i++) v = v * 62n + DIGIT.get(b[i]!)!;
  return { ns: String.fromCharCode(b[0]!, b[1]!, b[2]!), snow: v };
}

export function naiveHash32(k: bigint): number {
  k = BigInt.asUintN(64, k);
  k ^= k >> 33n;
  k = BigInt.asUintN(64, k * 0xff51afd7ed558ccdn);
  k ^= k >> 33n;
  return Number(k & 0xffffffffn);
}

export function naiveUnixMs(snow: bigint): number {
  return Number((snow >> 22n) + EPOCH_MS);
}

export function naiveFields(snow: bigint): { ts: number; node: number; seq: number } {
  return { ts: Number(snow >> 22n), node: Number((snow >> 12n) & 1023n), seq: Number(snow & 4095n) };
}

export function naiveCompose(ts: number, node: number, seq: number): bigint {
  return (BigInt(ts) << 22n) | (BigInt(node) << 12n) | BigInt(seq);
}

export function naiveNodeFrom(host: Uint8Array, pid: number): number {
  let h = 0x811c9dc5n;
  for (const c of [...host, ...encoder.encode(String(pid))]) {
    h ^= BigInt(c);
    h = (h * 0x01000193n) & 0xffffffffn;
  }
  return Number(h & 1023n);
}
