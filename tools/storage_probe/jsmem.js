// jsmem.js: heap bytes per distinct string of one width, on Node and Bun.
//
// Run by tools/storage_probe/run.py once per runtime and per width, so the
// readings of one width never reuse memory the other freed:
//   node --expose-gc jsmem.js <n> <width>
//   bun jsmem.js <n> <width>
// It prints one JSON object on stdout.
//
// Method: a warm-up allocates and drops n/10 strings so the heap's own growth
// is not in the delta. An Array of n slots is then filled with null, so the
// array's storage is in the baseline. Every slot gets a fresh, flat, one-byte
// string of the requested width (String.fromCharCode over Latin-1 codes builds
// a sequential string, never a cons/rope). A full GC runs before each reading.
//
// Readings: process.memoryUsage().heapUsed on both runtimes (the engine's own
// accounting of its heap); on Bun also bun:jsc heapStats(), whose heapSize
// counts JSC cells plus "extra memory" that JSC reports for string character
// buffers; and RSS, the only allocator-inclusive figure, which also carries
// allocator slack.

const ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
const isBun = typeof Bun !== "undefined";

function fullGC() {
  if (isBun) {
    Bun.gc(true);
  } else if (typeof globalThis.gc === "function") {
    globalThis.gc();
    globalThis.gc();
  } else {
    throw new Error("run node with --expose-gc");
  }
}

async function heapStats() {
  if (!isBun) return null;
  const { heapStats } = await import("bun:jsc");
  const s = heapStats();
  return { heapSize: s.heapSize, extraMemorySize: s.extraMemorySize, objectCount: s.objectCount };
}

function makeString(i, width) {
  const codes = new Array(width);
  let v = i;
  for (let j = width - 1; j >= 0; j--) {
    codes[j] = ALPHABET.charCodeAt(v % 62);
    v = Math.floor(v / 62);
  }
  return String.fromCharCode.apply(null, codes);
}

async function measure(width, n) {
  let warm = new Array(Math.floor(n / 10));
  for (let i = 0; i < warm.length; i++) warm[i] = makeString(i, width);
  warm = null;
  const keep = new Array(n).fill(null);
  fullGC();
  const m0 = process.memoryUsage();
  const h0 = await heapStats();
  for (let i = 0; i < n; i++) keep[i] = makeString(i, width);
  fullGC();
  const m1 = process.memoryUsage();
  const h1 = await heapStats();
  const out = {
    width,
    n,
    heap_used_delta: m1.heapUsed - m0.heapUsed,
    heap_used_per_string: (m1.heapUsed - m0.heapUsed) / n,
    rss_delta: m1.rss - m0.rss,
    rss_per_string: (m1.rss - m0.rss) / n,
    sample: keep[n - 1],
    sample_length: keep[n - 1].length,
  };
  if (h0 && h1) {
    out.jsc_heap_size_delta = h1.heapSize - h0.heapSize;
    out.jsc_heap_size_per_string = (h1.heapSize - h0.heapSize) / n;
    out.jsc_extra_memory_delta = h1.extraMemorySize - h0.extraMemorySize;
    out.jsc_extra_memory_per_string = (h1.extraMemorySize - h0.extraMemorySize) / n;
    out.jsc_object_count_delta = h1.objectCount - h0.objectCount;
  }
  if (keep.length !== n) throw new Error("unreachable"); // keeps `keep` live past the readings
  return out;
}

async function main() {
  const n = parseInt(process.argv[2] || "1000000", 10);
  const width = parseInt(process.argv[3] || "14", 10);
  const info = isBun
    ? { runtime: "bun", version: Bun.version, revision: Bun.revision, engine: "JavaScriptCore" }
    : {
        runtime: "node",
        version: process.version,
        v8: process.versions.v8,
        engine: "V8",
        pointer_compression: process.config.variables.v8_enable_pointer_compression === 1,
      };
  const measurement = await measure(width, n);
  process.stdout.write(JSON.stringify({ ...info, measurement }) + "\n");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
