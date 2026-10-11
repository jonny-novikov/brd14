// errors.ts — the contract's error classes as plain, erasable TypeScript.
//
// No `enum`: Node's type stripping and Bun run these sources unbuilt, and an
// enum is not erasable. `ErrorCode` is a frozen const object whose values are
// the C ABI's `branded_status` numbers, and the type of the same name is the
// union of those numbers.

/** The contract's status codes (docs/contract.md § Errors and precedence). */
export const ErrorCode = Object.freeze({
  OK: 0,
  /** decode input is not exactly 14 bytes */
  LENGTH: 1,
  /** namespace is not exactly 3 bytes of A-Z */
  NAMESPACE: 2,
  /** a payload byte is outside the alphabet */
  CHARSET: 3,
  /** value outside [0, 2^63) */
  RANGE: 4,
} as const);

export type ErrorCode = (typeof ErrorCode)[keyof typeof ErrorCode];

/** A refusal code: every `ErrorCode` except `OK`. */
export type RefusalCode = Exclude<ErrorCode, 0>;

/** The class names, indexed by code — the spelling the vectors and the parity protocol use. */
export const ErrorClass = Object.freeze(["OK", "LENGTH", "NAMESPACE", "CHARSET", "RANGE"] as const);

export type ErrorClassName = (typeof ErrorClass)[number];

/**
 * The one error the codec throws. `code` is the contract class; `name` is
 * "InvalidIdError". Policy refusals (see `NamespaceRefusedError`) are
 * deliberately not this class: a malformed id and a brand that is not yours
 * to mint are different facts.
 */
export class InvalidIdError extends Error {
  readonly code: RefusalCode;

  constructor(code: RefusalCode, detail?: string) {
    super(`brd14: invalid id (${ErrorClass[code]})${detail === undefined ? "" : `: ${detail}`}`);
    this.name = "InvalidIdError";
    this.code = code;
  }

  /** The contract class name, e.g. "RANGE". */
  get className(): ErrorClassName {
    return ErrorClass[this.code];
  }
}

/**
 * What `denyAll` throws. Not an `InvalidIdError`, so a consumer can tell
 * "this brand is not yours to mint" from "this is not a branded id". A real
 * policy should throw its own error with its own detail; the Minter passes
 * whatever a gate throws to the caller unchanged.
 */
export class NamespaceRefusedError extends Error {
  readonly ns: string;

  constructor(ns: string) {
    super(`brd14: namespace ${JSON.stringify(ns)} refused by policy`);
    this.name = "NamespaceRefusedError";
    this.ns = ns;
  }
}
