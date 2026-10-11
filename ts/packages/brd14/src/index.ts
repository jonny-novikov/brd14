// brd14 — a 14-byte branded identity: time-ordered, coordination-free, carrying
// its own type. Pure TypeScript, exact 64-bit arithmetic without BigInt on the
// hot path. The contract is docs/contract.md; this module implements all of it.

export {
  ALPHABET,
  EPOCH_MS,
  ID_LENGTH,
  MAX_PAYLOAD,
  MAX_SNOW,
  MAX_TS,
  check,
  decode,
  decodePartsInto,
  encode,
  encodeInto,
  encodeParts,
  encodePartsInto,
  fields,
  hash32,
  hash32Parts,
  isNamespace,
  isValid,
  minFor,
  nodeFrom,
  snowFromParts,
  unixMs,
  type Decoded,
  type DecodedParts,
  type Parts,
} from "./codec.ts";
export {
  ErrorClass,
  ErrorCode,
  InvalidIdError,
  NamespaceRefusedError,
  type ErrorClassName,
  type RefusalCode,
} from "./errors.ts";
export { Generator, type Clock } from "./generator.ts";
export { Minter, allowAll, denyAll, type Gate, type Minted } from "./minter.ts";
