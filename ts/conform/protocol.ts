// protocol.ts — the parity shim protocol (docs/contract.md § Parity shim
// protocol), shared by every TypeScript shim: pure.ts here, wasm.ts next to it.
//
// A shim reads every request from stdin, answers one line per request, and
// writes once. `serve` owns the framing (HELLO line, request parsing, the
// ERR <CLASS> mapping of InvalidIdError) so a shim is just the six handlers.
//
// Runs unbuilt on both runtimes: `node ts/conform/pure.ts`, `bun ts/conform/pure.ts`.

import { readFileSync, readSync } from "node:fs";
import { ErrorClass, InvalidIdError } from "brd14";

/** The six request letters, in the order HELLO lists them. */
export const OPS = "EDHUFN";

/**
 * Each handler returns the payload after "OK ". An `InvalidIdError` thrown by a
 * handler becomes `ERR <CLASS>`; any other exception is a shim bug and aborts.
 */
export interface Handlers {
  /** `E <ns_hex> <snow>`: the 14-char id. `snow` may be anything in [0, 2^64). */
  E?: (ns: Uint8Array, snow: bigint) => string;
  /** `D <id_hex>`: "<ns> <snow>". */
  D?: (id: Uint8Array) => string;
  /** `H <k>`: the hash, k in [0, 2^64). */
  H?: (k: bigint) => number;
  /** `U <snow>`: unix_ms. */
  U?: (snow: bigint) => number;
  /** `F <snow>`: "<ts> <node> <seq>". */
  F?: (snow: bigint) => string;
  /** `N <host_hex> <pid>`: the node id. */
  N?: (host: Uint8Array, pid: number) => number;
}

/** Hex as the protocol writes it: lowercase, "-" for empty. */
export function unhex(s: string): Uint8Array {
  if (s === "-") return new Uint8Array(0);
  const out = new Uint8Array(s.length >>> 1);
  for (let i = 0; i < out.length; i++) {
    out[i] = Number.parseInt(s.substr(i * 2, 2), 16);
  }
  return out;
}

export function hexs(b: Uint8Array): string {
  if (b.length === 0) return "-";
  let s = "";
  for (let i = 0; i < b.length; i++) s += b[i]!.toString(16).padStart(2, "0");
  return s;
}

/**
 * Bytes → a string with one char per byte (Latin-1). A namespace is three
 * bytes of A-Z, so any byte ≥ 128 becomes a non-ASCII char the codec refuses
 * the same way, and the length is preserved.
 */
export function latin1(b: Uint8Array): string {
  let s = "";
  for (let i = 0; i < b.length; i++) s += String.fromCharCode(b[i]!);
  return s;
}

/** Reads all of stdin (a redirected file or a pipe) synchronously. */
export function readStdin(): string {
  try {
    return readFileSync(0, "utf8");
  } catch (e) {
    if ((e as NodeJS.ErrnoException).code === "EAGAIN") {
      // A non-blocking stdin: retry until the writer closes it.
      return readStdinSlow();
    }
    throw e;
  }
}

function readStdinSlow(): string {
  const chunks: Buffer[] = [];
  const buf = Buffer.alloc(1 << 16);
  for (;;) {
    let n: number;
    try {
      n = readSync(0, buf, 0, buf.length, null);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "EAGAIN") continue;
      throw e;
    }
    if (n === 0) break;
    chunks.push(Buffer.from(buf.subarray(0, n)));
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** Answers every request line of `input` and returns the response lines, HELLO first. */
export function respond(impl: string, variant: string, handlers: Handlers, input: string): string[] {
  const ops = [...OPS].filter((op) => handlers[op as keyof Handlers] !== undefined).join("");
  const out: string[] = [`HELLO ${impl} ${variant} ${ops}`];
  const lines = input.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (line.length === 0) continue;
    out.push(answer(handlers, line));
  }
  return out;
}

function answer(h: Handlers, line: string): string {
  const sp1 = line.indexOf(" ");
  const op = sp1 < 0 ? line : line.substring(0, sp1);
  const rest = sp1 < 0 ? "" : line.substring(sp1 + 1);
  try {
    switch (op) {
      case "E": {
        const sp = rest.indexOf(" ");
        return `OK ${h.E!(unhex(rest.substring(0, sp)), BigInt(rest.substring(sp + 1)))}`;
      }
      case "D":
        return `OK ${h.D!(unhex(rest))}`;
      case "H":
        return `OK ${h.H!(BigInt(rest))}`;
      case "U":
        return `OK ${h.U!(BigInt(rest))}`;
      case "F":
        return `OK ${h.F!(BigInt(rest))}`;
      case "N": {
        const sp = rest.indexOf(" ");
        return `OK ${h.N!(unhex(rest.substring(0, sp)), Number(rest.substring(sp + 1)))}`;
      }
      default:
        throw new Error(`unknown request ${JSON.stringify(line)}`);
    }
  } catch (e) {
    if (e instanceof InvalidIdError) return `ERR ${ErrorClass[e.code]}`;
    throw e;
  }
}

/** The shim main: stdin → stdout, one write, diagnostics to stderr. */
export function serve(impl: string, variant: string, handlers: Handlers): void {
  let lines: string[];
  try {
    lines = respond(impl, variant, handlers, readStdin());
  } catch (e) {
    process.stderr.write(`${impl} ${variant} shim: ${e instanceof Error ? e.stack ?? e.message : String(e)}\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write(lines.join("\n") + "\n");
}
