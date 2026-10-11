// module.test.ts — facts about the embedded module and the loader: the bytes
// behind the base64 are the module the build script hashed; it imports nothing;
// its exports are exactly the ABI plus memory, with the right arities; its memory
// is fixed; the IO region is aligned and inside it; the views are the memory.

import { describe, expect, test } from "vitest";
import { createHash } from "node:crypto";
import { BATCH_MAX, IO_LENGTH, IO_PTR, WASM_BYTE_LENGTH, WASM_CORE, WASM_SHA256, abi, memory, wasmModule } from "brd14-wasm";
import { WASM_BASE64 } from "../src/wasm-bytes.ts";

const ABI: Record<string, number> = { io_ptr: 0, encode: 2, decode: 1, hash32: 1, encode_many: 2, decode_many: 1 };

function fromBase64(s: string): Uint8Array {
  const bin = atob(s);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

describe("the embedded bytes", () => {
  test("decode with atob to the recorded length and SHA-256", () => {
    const bytes = fromBase64(WASM_BASE64);
    expect(bytes.length).toBe(WASM_BYTE_LENGTH);
    expect(createHash("sha256").update(bytes).digest("hex")).toBe(WASM_SHA256);
    expect(bytes.subarray(0, 8)).toEqual(new Uint8Array([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00])); // "\0asm" v1
  });
  test("name a core, and the module is small", () => {
    expect(["speed", "memory"]).toContain(WASM_CORE);
    expect(WASM_BYTE_LENGTH).toBeLessThan(16384);
    expect(WASM_BYTE_LENGTH).toBeGreaterThan(1024);
  });
  test("compile again to a module with the same shape (the loader did this once, synchronously)", () => {
    const again = new WebAssembly.Module(fromBase64(WASM_BASE64));
    expect(WebAssembly.Module.exports(again).map((e) => e.name).sort()).toEqual(WebAssembly.Module.exports(wasmModule).map((e) => e.name).sort());
  });
});

describe("the module", () => {
  test("imports nothing", () => {
    expect(WebAssembly.Module.imports(wasmModule)).toEqual([]);
  });
  test("exports exactly the ABI plus memory, with the right kinds and arities", () => {
    const exports = WebAssembly.Module.exports(wasmModule);
    expect(exports.map((e) => e.name).sort()).toEqual([...Object.keys(ABI), "memory"].sort());
    for (const e of exports) expect(e.kind).toBe(e.name === "memory" ? "memory" : "function");
    for (const [name, arity] of Object.entries(ABI)) {
      const f = (abi as unknown as Record<string, unknown>)[name];
      expect(typeof f).toBe("function");
      expect((f as (...args: unknown[]) => unknown).length).toBe(arity);
    }
    expect(abi.memory).toBe(memory);
    expect(memory).toBeInstanceOf(WebAssembly.Memory);
  });
  test("memory is three 64 KiB pages, fixed: grow fails and byteLength never changes", () => {
    const before = memory.buffer.byteLength;
    expect(before).toBe(3 * 65536);
    expect(() => memory.grow(1)).toThrow(RangeError);
    expect(memory.grow(0)).toBe(3);
    expect(memory.buffer.byteLength).toBe(before);
    const view = new Uint8Array(memory.buffer);
    abi.encode(0x525355, 1n);
    abi.decode_many(BATCH_MAX);
    expect(view.byteLength).toBe(before); // not detached
    expect(memory.buffer.byteLength).toBe(before);
  });
  test("the IO region is 16-byte aligned and inside the memory, above the stack", () => {
    expect(IO_LENGTH).toBe(65536);
    expect(IO_PTR).toBe(abi.io_ptr());
    expect(IO_PTR % 16).toBe(0);
    expect(IO_PTR).toBeGreaterThanOrEqual(65536); // the 64 KiB stack comes first
    expect(IO_PTR + IO_LENGTH).toBeLessThanOrEqual(memory.buffer.byteLength);
  });
  test("the raw exports follow the ABI's conventions on the region", () => {
    const io = new Uint8Array(memory.buffer, IO_PTR, IO_LENGTH);
    expect(abi.encode(0x525355, 274557032793636864n)).toBe(0); // "USR" packed little-endian
    expect(new TextDecoder().decode(io.subarray(0, 14))).toBe("USR0KHTOWnGLuC");
    expect(abi.decode(14)).toBe(274557032793636864n);
    expect(abi.decode(13)).toBe(-1n);
    expect(abi.encode(0x525355 | (0x41 << 24), 1n)).toBe(2); // the fourth-byte rule
    expect(abi.encode(0x525355, -1n)).toBe(4);
    expect(abi.encode(0x727375, -1n)).toBe(2); // "usr": NAMESPACE before RANGE
    expect(abi.hash32(274557032793636864n) >>> 0).toBe(234878118);
    expect(abi.hash32(-1n) >>> 0).toBe(2225773772);
  });
});
