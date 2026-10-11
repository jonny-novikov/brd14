// webassembly.d.ts — the slice of the WebAssembly JavaScript API this package uses.
//
// Neither lib.es2023 nor @types/node declares the `WebAssembly` namespace (lib.dom
// and bun-types do), and pulling the whole DOM into a Node package for three classes
// is the wrong trade. This ambient declaration is a compile-time input only: tsc does
// not copy hand-written .d.ts files to dist/, so a consumer of the published package
// brings its own WebAssembly types (lib.dom, bun-types), as with any wasm package.

declare namespace WebAssembly {
  interface ModuleImportDescriptor {
    module: string;
    name: string;
    kind: string;
  }

  interface ModuleExportDescriptor {
    name: string;
    kind: string;
  }

  /** A compiled module. Synchronous compilation; throws `CompileError` on bad bytes. */
  class Module {
    constructor(bytes: BufferSource);
    static imports(module: Module): ModuleImportDescriptor[];
    static exports(module: Module): ModuleExportDescriptor[];
  }

  /** An instantiated module; `exports` holds its functions and memory. */
  class Instance {
    constructor(module: Module, importObject?: Record<string, Record<string, unknown>>);
    readonly exports: Record<string, unknown>;
  }

  /** Linear memory. `grow` throws `RangeError` when the maximum is reached. */
  class Memory {
    readonly buffer: ArrayBuffer;
    grow(delta: number): number;
  }
}
