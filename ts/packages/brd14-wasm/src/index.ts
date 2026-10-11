// brd14-wasm — a 14-byte branded identity: time-ordered, coordination-free,
// carrying its own type. The Rust core compiled to WebAssembly, embedded in this
// package and instantiated synchronously at import. The contract is
// docs/contract.md; the ABI this package drives is its WebAssembly section.
//
// The codec operations (encode, decode, check, isValid, hash32 and the batches)
// run inside the module. The error classes, the generator and the minter, and the
// table-free readers (unixMs, fields, minFor, snowFromParts, nodeFrom) are the pure
// package's, re-exported, so the two packages throw the same classes and a
// `Generator` feeds either `encode`.

export {
  BatchInvalidIdError,
  check,
  checkMany,
  decode,
  decodeMany,
  decodeManyInto,
  encode,
  encodeMany,
  encodeManyInto,
  hash32,
  isValid,
  type Decoded,
  type Ids,
  type Snowflakes,
} from "./codec.ts";
export { BATCH_MAX, IO_LENGTH, IO_PTR, abi, memory, wasmModule, type Abi } from "./module.ts";
export { WASM_BYTE_LENGTH, WASM_CORE, WASM_SHA256 } from "./wasm-bytes.ts";
export {
  ALPHABET,
  EPOCH_MS,
  ErrorClass,
  ErrorCode,
  Generator,
  ID_LENGTH,
  InvalidIdError,
  MAX_PAYLOAD,
  MAX_SNOW,
  MAX_TS,
  Minter,
  NamespaceRefusedError,
  allowAll,
  denyAll,
  fields,
  isNamespace,
  minFor,
  nodeFrom,
  snowFromParts,
  unixMs,
  type Clock,
  type ErrorClassName,
  type Gate,
  type Minted,
  type Parts,
  type RefusalCode,
} from "brd14";
