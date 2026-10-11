/* bench.c — micro-benchmarks for one C core, per bench/README.md.
 *
 *   bench-<variant> <vectors-dir> <results-dir>
 *   make bench          (both cores, pinned with taskset -c 2 when available)
 *
 * Corpus: the first 4096 data rows of vectors/valid.tsv; encode and hash32
 * take the snow column, decode the id column. Every timed loop cycles through
 * all 4096 rows in order, so no branch predictor can memorise one input (the
 * memory core's decode has no data-dependent branch, the speed core's
 * table loads do depend on the bytes — the corpus keeps both honest).
 *
 * Sampling: the iteration count is calibrated (doubling, a whole number of
 * corpus passes) until one sample takes >= 50 ms; the calibration runs double
 * as warmup, plus one discarded full sample. Then 15 samples; ns_per_op is the
 * median, mad_ns the median absolute deviation, cv_pct the coefficient of
 * variation (stdev / mean). Results above 5% CV are noisy (bench/README.md).
 *
 * Sink: every result is folded into an accumulator that is stored to a
 * volatile after each sample, so no call can be deleted as dead. The core is
 * a separate object (no LTO), so the calls cannot be inlined either: what is
 * measured is the ABI call a consumer makes.
 *
 * Output: a table on stdout and <results-dir>/c-<variant>-<runtime>.json,
 * runtime e.g. "gcc-13.3"; the core's flags are recorded in "cflags".
 */
#define _POSIX_C_SOURCE 200809L
#include "branded_id.h"
#include "../test/support.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifndef VARIANT
#define VARIANT "unknown"
#endif
#ifndef CORE_CFLAGS
#define CORE_CFLAGS ""
#endif

#define CORPUS 4096u
#define SAMPLES 15
#define MIN_SAMPLE_NS 50000000.0 /* 50 ms */

static char ns_col[CORPUS][BRANDED_NS_LEN];
static char id_col[CORPUS][BRANDED_LEN];
static uint64_t snow_col[CORPUS];
static volatile uint64_t sink;

enum op { OP_ENCODE, OP_DECODE, OP_HASH32, OP_COUNT };
static const char *const op_name[OP_COUNT] = {"encode", "decode", "hash32"};

static double now_ns(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e9 + (double)ts.tv_nsec;
}

/* One timed run of `iters` ops (a multiple of CORPUS); returns elapsed ns. */
static double run(enum op op, size_t iters) {
  uint64_t acc = 0;
  double t0 = now_ns();
  switch (op) {
    case OP_ENCODE: {
      char out[BRANDED_LEN];
      for (size_t i = 0; i < iters; i++) {
        size_t r = i & (CORPUS - 1u);
        acc += (uint64_t)branded_encode(ns_col[r], snow_col[r], out);
        acc += (unsigned char)out[13];
      }
      break;
    }
    case OP_DECODE: {
      char ns[BRANDED_NS_LEN];
      uint64_t v = 0;
      for (size_t i = 0; i < iters; i++) {
        size_t r = i & (CORPUS - 1u);
        acc += (uint64_t)branded_decode(id_col[r], BRANDED_LEN, ns, &v);
        acc += v ^ (unsigned char)ns[0];
      }
      break;
    }
    case OP_HASH32:
      for (size_t i = 0; i < iters; i++) acc += branded_hash32(snow_col[i & (CORPUS - 1u)]);
      break;
    default:
      break;
  }
  double dt = now_ns() - t0;
  sink = acc;
  return dt;
}

static int cmp_double(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

static double median(double *v, size_t n) {
  qsort(v, n, sizeof *v, cmp_double);
  return n % 2u ? v[n / 2u] : (v[n / 2u - 1u] + v[n / 2u]) / 2.0;
}

typedef struct {
  double ns_per_op, mad_ns, cv_pct;
  size_t iters;
} result;

static result measure(enum op op) {
  size_t iters = CORPUS;
  while (run(op, iters) < MIN_SAMPLE_NS && iters < ((size_t)1 << 40)) iters *= 2u;
  run(op, iters); /* one more discarded sample at the final size */

  double s[SAMPLES], dev[SAMPLES], mean = 0, var = 0;
  for (int i = 0; i < SAMPLES; i++) {
    s[i] = run(op, iters) / (double)iters;
    mean += s[i] / SAMPLES;
  }
  for (int i = 0; i < SAMPLES; i++) var += (s[i] - mean) * (s[i] - mean) / (SAMPLES - 1);
  result r;
  r.iters = iters;
  r.ns_per_op = median(s, SAMPLES);
  for (int i = 0; i < SAMPLES; i++) dev[i] = fabs(s[i] - r.ns_per_op);
  r.mad_ns = median(dev, SAMPLES);
  r.cv_pct = mean > 0 ? 100.0 * sqrt(var) / mean : 0;
  return r;
}

/* Reads the first CORPUS data rows of valid.tsv. 1 = ok, 0 = absent, -1 = bad. */
static int load(const char *dir) {
  char path[4096], line[512];
  if (snprintf(path, sizeof path, "%s/valid.tsv", dir) >= (int)sizeof path) return -1;
  FILE *f = fopen(path, "rb");
  if (!f) return 0;
  unsigned rows = 0;
  while (rows < CORPUS && fgets(line, sizeof line, f)) {
    if (line[0] == '#' || line[0] == '\n') continue;
    char *ns = line, *snow = strchr(ns, '\t'), *id = snow ? strchr(snow + 1, '\t') : NULL;
    char *end = id ? strchr(id + 1, '\t') : NULL;
    if (!end || snow - ns != 3 || end - id - 1 != BRANDED_LEN ||
        !brd_parse_u64(snow + 1, (size_t)(id - snow - 1), &snow_col[rows])) {
      fclose(f);
      return -1;
    }
    memcpy(ns_col[rows], ns, 3);
    memcpy(id_col[rows], id + 1, BRANDED_LEN);
    rows++;
  }
  fclose(f);
  return rows == CORPUS ? 1 : -1;
}

static void machine(char *out, size_t cap) {
  snprintf(out, cap, "unknown");
  FILE *f = fopen("/proc/cpuinfo", "r");
  if (!f) return;
  char line[512];
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, "model name", 10) == 0) {
      char *v = strchr(line, ':');
      if (v) {
        v += 1 + (v[1] == ' ');
        v[strcspn(v, "\n")] = '\0';
        snprintf(out, cap, "%s", v);
      }
      break;
    }
  }
  fclose(f);
}

/* Pinned iff this process may run on exactly one CPU (taskset -c N). */
static int pinned(void) {
  FILE *f = fopen("/proc/self/status", "r");
  if (!f) return 0;
  char line[512];
  int one = 0;
  while (fgets(line, sizeof line, f)) {
    if (strncmp(line, "Cpus_allowed_list:", 18) == 0) {
      char *v = line + 18 + strspn(line + 18, " \t");
      v[strcspn(v, "\n")] = '\0';
      one = *v && strpbrk(v, ",-") == NULL;
      break;
    }
  }
  fclose(f);
  return one;
}

/* A JSON string literal (quotes, backslashes and control bytes escaped). */
static void json_str(FILE *f, const char *s) {
  fputc('"', f);
  for (; *s; s++) {
    unsigned char c = (unsigned char)*s;
    if (c == '"' || c == '\\') fprintf(f, "\\%c", c);
    else if (c < 0x20) fprintf(f, "\\u%04x", c);
    else fputc(c, f);
  }
  fputc('"', f);
}

static void runtime(char *out, size_t cap) {
#if defined(__clang__)
  snprintf(out, cap, "clang-%d.%d", __clang_major__, __clang_minor__);
#elif defined(__GNUC__)
  snprintf(out, cap, "gcc-%d.%d", __GNUC__, __GNUC_MINOR__);
#else
  snprintf(out, cap, "cc");
#endif
}

int main(int argc, char **argv) {
  const char *dir = argc > 1 ? argv[1] : "../../vectors";
  const char *results = argc > 2 ? argv[2] : "../../bench/results";
  const char *req = getenv("BRD14_REQUIRE_VECTORS");

  int ok = load(dir);
  if (ok == 0) {
    if (req && strcmp(req, "1") == 0) {
      fprintf(stderr, "FAIL bench c-%s: %s/valid.tsv not found and BRD14_REQUIRE_VECTORS=1\n", VARIANT, dir);
      return 1;
    }
    printf("SKIP bench c-%s: %s not present\n", VARIANT, dir);
    return 0;
  }
  if (ok < 0) {
    fprintf(stderr, "FAIL bench c-%s: %s/valid.tsv has fewer than %u well-formed rows\n", VARIANT, dir, CORPUS);
    return 1;
  }

  char rt[64], cpu[256];
  runtime(rt, sizeof rt);
  machine(cpu, sizeof cpu);
  int pin = pinned();

  result r[OP_COUNT];
  printf("c-%s (%s %s), %s, %s\n", VARIANT, rt, CORE_CFLAGS, cpu, pin ? "pinned" : "NOT pinned");
  printf("  %-8s %10s %8s %7s %12s\n", "op", "ns/op", "mad", "cv%", "iters/sample");
  for (int op = 0; op < OP_COUNT; op++) {
    r[op] = measure((enum op)op);
    printf("  %-8s %10.2f %8.3f %6.2f%s %12zu\n", op_name[op], r[op].ns_per_op, r[op].mad_ns, r[op].cv_pct,
           r[op].cv_pct > 5.0 ? "!" : " ", r[op].iters);
  }

  char path[4096];
  if (snprintf(path, sizeof path, "%s/c-%s-%s.json", results, VARIANT, rt) >= (int)sizeof path) return 1;
  FILE *f = fopen(path, "w");
  if (!f) {
    fprintf(stderr, "bench c-%s: cannot write %s\n", VARIANT, path);
    return 1;
  }
  fprintf(f, "{\n  \"impl\": \"c\",\n  \"variant\": \"%s\",\n  \"runtime\": \"%s\",\n", VARIANT, rt);
  fputs("  \"cflags\": ", f);
  json_str(f, CORE_CFLAGS);
  fputs(",\n  \"machine\": ", f);
  json_str(f, cpu);
  fprintf(f, ",\n  \"pinned\": %s,\n", pin ? "true" : "false");
  fprintf(f, "  \"corpus\": \"vectors/valid.tsv rows 1..%u\",\n  \"results\": [\n", CORPUS);
  for (int op = 0; op < OP_COUNT; op++)
    fprintf(f,
            "    {\"op\": \"%s\", \"ns_per_op\": %.3f, \"mad_ns\": %.3f, \"samples\": %d, \"cv_pct\": %.2f, "
            "\"iters_per_sample\": %zu, \"allocs_per_op\": 0, \"bytes_per_op\": 0}%s\n",
            op_name[op], r[op].ns_per_op, r[op].mad_ns, SAMPLES, r[op].cv_pct, r[op].iters,
            op + 1 < OP_COUNT ? "," : "");
  fprintf(f, "  ]\n}\n");
  if (fclose(f) != 0) return 1;
  printf("  -> %s\n", path);
  return 0;
}
