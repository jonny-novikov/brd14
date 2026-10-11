/* test_props.c — properties of every C core, checked differentially.
 *
 *   test_props [roundtrips]        default 10,000,000
 *
 * All cores are linked into this one binary (cores.h). Their objects are the
 * very ones the shims and consumers link, with the four ABI symbols renamed by
 * objcopy (branded_encode -> speed_branded_encode, ...), so what is tested
 * here is the shipped machine code, not a re-compilation. A third core,
 * memory_noint128, is the memory source built with BRANDED_NO_INT128: the
 * portable mulhi path, which no shipped build on this host would otherwise
 * exercise.
 *
 * Every answer of every core is compared with the reference model in
 * support.h (one u64 divmod per digit, a linear alphabet search, an
 * overflow-checked Horner range guard — none of the cores' techniques), and
 * with each other. Sections:
 *
 *   literals    V-1..V-6, E-1, E-2 and the oracle's precedence asserts
 *   digits      all 62 digit<->char mappings at every payload position
 *   bytes       every byte value at every position of several seeds:
 *               classification exact, all cores identical
 *   lengths     every length 0..64
 *   boundaries  62^k edges, the (QA, RB) guard from both sides, the max
 *               payload's neighbourhood, V-7 ordering
 *   precedence  multi-fault inputs, both directions
 *   roundtrip   N splitmix64 values: encode bytewise identical across cores
 *               and the reference, decode(encode(x)) == x, byte order ==
 *               numeric order, out-of-range refusals, hash32 / unix_ms
 *   noise       random near-valid strings: full status/ns/value agreement
 */
#include "branded_id.h"
#include "cores.h"
#include "support.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define P62_6 56800235584ULL
#define QA 162382637ULL
#define RB 503620799ULL
#define SENTINEL 0xDEADBEEFDEADBEEFULL

static unsigned long failures, checks;

#define CHECK(cond, ...)                                                   \
  do {                                                                     \
    checks++;                                                              \
    if (!(cond) && ++failures <= 30) {                                     \
      fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__);                 \
      fprintf(stderr, __VA_ARGS__);                                        \
      fputc('\n', stderr);                                                 \
    }                                                                      \
  } while (0)

static const char *hex(const unsigned char *b, size_t n) {
  static char buf[2 * 80 + 1];
  if (n > 80) n = 80;
  for (size_t i = 0; i < n; i++) snprintf(buf + 2 * i, 3, "%02x", b[i]);
  buf[2 * n] = '\0';
  return n ? buf : "-";
}

/* ── differential primitives ─────────────────────────────────────────── */

typedef struct {
  branded_status s;
  char ns[BRANDED_NS_LEN];
  uint64_t snow;
} dres;

static int same(const dres *a, const dres *b) {
  if (a->s != b->s) return 0;
  return a->s != BRANDED_OK || (memcmp(a->ns, b->ns, 3) == 0 && a->snow == b->snow);
}

/* decode through the reference and every core; all must agree, and a
 * refusal must leave the outputs untouched. Returns the reference result. */
static dres diff_decode(const unsigned char *id, size_t len) {
  dres want = {BRANDED_OK, {'#', '#', '#'}, SENTINEL};
  want.s = ref_decode(id, len, want.ns, &want.snow);
  for (size_t c = 0; c < NCORES; c++) {
    dres got = {BRANDED_OK, {'#', '#', '#'}, SENTINEL};
    got.s = CORES[c].decode((const char *)id, len, got.ns, &got.snow);
    CHECK(same(&got, &want), "%s decode %s: got %s %llu, want %s %llu", CORES[c].name, hex(id, len),
          brd_class_name(got.s), (unsigned long long)got.snow, brd_class_name(want.s),
          (unsigned long long)want.snow);
    if (got.s != BRANDED_OK)
      CHECK(memcmp(got.ns, "###", 3) == 0 && got.snow == SENTINEL,
            "%s decode %s: refusal wrote its outputs", CORES[c].name, hex(id, len));
  }
  return want;
}

/* encode through the reference and every core: identical status and bytes;
 * on success every core decodes the id back to (ns, snow). */
static branded_status diff_encode(const unsigned char *ns, size_t ns_len, uint64_t snow) {
  char want[BRANDED_LEN];
  memset(want, '#', sizeof want);
  branded_status ws = ref_encode(ns, ns_len, snow, want);
  for (size_t c = 0; c < NCORES; c++) {
    char got[BRANDED_LEN];
    memset(got, '#', sizeof got);
    branded_status gs = brd_encode_bytes(CORES[c].encode, ns, ns_len, snow, got);
    CHECK(gs == ws && memcmp(got, want, BRANDED_LEN) == 0, "%s encode(%s, %llu): got %s %.14s, want %s %.14s",
          CORES[c].name, hex(ns, ns_len), (unsigned long long)snow, brd_class_name(gs), got,
          brd_class_name(ws), want);
    if (gs == BRANDED_OK) {
      dres back = {BRANDED_OK, {0, 0, 0}, 0};
      back.s = CORES[c].decode(got, BRANDED_LEN, back.ns, &back.snow);
      CHECK(back.s == BRANDED_OK && memcmp(back.ns, ns, 3) == 0 && back.snow == snow,
            "%s decode(encode(%s, %llu)) round trip", CORES[c].name, hex(ns, ns_len),
            (unsigned long long)snow);
    }
  }
  return ws;
}

static void section(const char *name, unsigned long before_checks, unsigned long before_fail) {
  printf("%s c props: %-10s %10lu checks\n", failures > before_fail ? "FAIL" : "ok  ", name,
         checks - before_checks);
}

/* payload digits of (hi: 5 digits, lo: 6 digits), most significant first */
static void payload_of(uint64_t hi, uint64_t lo, unsigned char out[BRANDED_PAYLOAD_LEN]) {
  for (int i = 4; i >= 0; i--, hi /= 62u) out[i] = (unsigned char)BRD_ALPHABET[hi % 62u];
  for (int i = 10; i >= 5; i--, lo /= 62u) out[i] = (unsigned char)BRD_ALPHABET[lo % 62u];
}

/* ── sections ────────────────────────────────────────────────────────── */

static void t_literals(void) {
  const unsigned char *usr = (const unsigned char *)"USR";
  for (size_t c = 0; c < NCORES; c++) {
    const brd_core *k = &CORES[c];
    char out[BRANDED_LEN], ns[3];
    uint64_t v = 0;
    CHECK(k->encode("USR", 274557032793636864ULL, out) == BRANDED_OK &&
              memcmp(out, "USR0KHTOWnGLuC", 14) == 0, "%s V-1", k->name);
    CHECK(k->decode("USR0KHTOWnGLuC", 14, ns, &v) == BRANDED_OK && v == 274557032793636864ULL,
          "%s V-1 inverse", k->name);
    CHECK(k->decode("USR0NgWEfAEJfs", 14, ns, &v) == BRANDED_OK && v == 320636799581945856ULL &&
              memcmp(ns, "USR", 3) == 0, "%s V-2", k->name);
    CHECK(k->encode("ABC", 0, out) == BRANDED_OK && memcmp(out, "ABC00000000000", 14) == 0, "%s V-3", k->name);
    CHECK(k->encode("ABC", BRD_MAX_SNOW, out) == BRANDED_OK && memcmp(out + 3, "AzL8n0Y58m7", 11) == 0,
          "%s V-4", k->name);
    CHECK(k->decode("USRzzzzzzzzzzz", 14, ns, &v) == BRANDED_ERR_RANGE, "%s V-5 range", k->name);
    CHECK(k->decode("usr0KHTOWnGLuC", 14, ns, &v) == BRANDED_ERR_NAMESPACE, "%s V-5 namespace", k->name);
    CHECK(k->decode("USR0KHTOWnGLu", 13, ns, &v) == BRANDED_ERR_LENGTH, "%s V-5 13 bytes", k->name);
    CHECK(k->decode("USR0KHTOWnGLuCC", 15, ns, &v) == BRANDED_ERR_LENGTH, "%s V-5 15 bytes", k->name);
    CHECK(k->decode("USRAzL8n0Y58m8", 14, ns, &v) == BRANDED_ERR_RANGE, "%s max + 1", k->name);
    CHECK(k->hash32(274557032793636864ULL) == 234878118u, "%s V-6", k->name);
    CHECK(k->unix_ms(274557032793636864ULL) == 1769526697641ULL, "%s E-1", k->name);
    CHECK(k->unix_ms(320636799581945856ULL) == 1780512970164ULL, "%s E-2", k->name);
    /* the oracle's precedence asserts */
    CHECK(brd_encode_bytes(k->encode, (const unsigned char *)"usr", 3, 1ULL << 63, out) == BRANDED_ERR_NAMESPACE,
          "%s encode(usr, 2^63) is NAMESPACE", k->name);
    CHECK(brd_encode_bytes(k->encode, usr, 2, 0, out) == BRANDED_ERR_NAMESPACE, "%s encode(US, 0)", k->name);
    CHECK(k->decode("usr0KHTOWnGL!!", 14, ns, &v) == BRANDED_ERR_NAMESPACE, "%s NAMESPACE beats CHARSET", k->name);
    CHECK(k->decode("USRzzzzzzzzzz!", 14, ns, &v) == BRANDED_ERR_CHARSET, "%s CHARSET beats RANGE", k->name);
  }
  CHECK(QA * P62_6 + RB == BRD_MAX_SNOW, "2^63 - 1 == QA * 62^6 + RB");
}

static void t_digits(void) {
  /* d * 62^k for every digit d and payload position: one non-zero digit */
  for (int k = 0; k < BRANDED_PAYLOAD_LEN; k++) {
    uint64_t pk = 1;
    for (int j = 0; j < k; j++) pk *= 62u;
    for (unsigned d = 0; d < 62; d++) {
      if (d && pk > BRD_MAX_SNOW / d) break; /* d * 62^k >= 2^63: not encodable */
      uint64_t snow = d * pk;
      char want[BRANDED_LEN];
      memcpy(want, "DIG00000000000", 14);
      want[BRANDED_LEN - 1 - k] = BRD_ALPHABET[d];
      for (size_t c = 0; c < NCORES; c++) {
        char out[BRANDED_LEN];
        CHECK(CORES[c].encode("DIG", snow, out) == BRANDED_OK && memcmp(out, want, 14) == 0,
              "%s digit %u at position %d maps to %c", CORES[c].name, d, k, BRD_ALPHABET[d]);
      }
      diff_decode((const unsigned char *)want, BRANDED_LEN);
      diff_encode((const unsigned char *)"DIG", 3, snow);
    }
  }
}

static void t_bytes(void) {
  static const char *const seeds[] = {"USR0KHTOWnGLuC", "ZZZAzL8n0Y58m7", "ABC00000000000",
                                      "SESzzzzzzzzzzz", "RNGAzL8n0Y58m8", "AAA0000000000z"};
  for (size_t s = 0; s < sizeof seeds / sizeof *seeds; s++) {
    for (int pos = 0; pos < BRANDED_LEN; pos++) {
      for (unsigned b = 0; b < 256; b++) {
        unsigned char id[BRANDED_LEN];
        memcpy(id, seeds[s], BRANDED_LEN);
        id[pos] = (unsigned char)b;
        dres r = diff_decode(id, BRANDED_LEN);
        if (s == 2) { /* ABC00000000000: classification must be exact */
          if (pos < BRANDED_NS_LEN)
            CHECK((r.s == BRANDED_ERR_NAMESPACE) == !ref_upper((unsigned char)b),
                  "namespace byte %02x at %d", b, pos);
          else
            CHECK((r.s == BRANDED_ERR_CHARSET) == (ref_digit((unsigned char)b) < 0),
                  "payload byte %02x at %d", b, pos);
        }
      }
    }
  }
  /* encode: every byte in every namespace position */
  for (int pos = 0; pos < BRANDED_NS_LEN; pos++)
    for (unsigned b = 0; b < 256; b++) {
      unsigned char ns[3] = {'U', 'S', 'R'};
      ns[pos] = (unsigned char)b;
      diff_encode(ns, 3, 274557032793636864ULL);
      diff_encode(ns, 3, 1ULL << 63);
    }
}

static void t_lengths(void) {
  unsigned char buf[64];
  for (size_t i = 0; i < sizeof buf; i++) buf[i] = (unsigned char)"USR0KHTOWnGLuC"[i % 14];
  for (size_t n = 0; n <= sizeof buf; n++) {
    dres r = diff_decode(buf, n);
    CHECK((r.s == BRANDED_ERR_LENGTH) == (n != BRANDED_LEN), "length %zu", n);
  }
  for (size_t n = 0; n <= 6; n++) {
    CHECK(diff_encode((const unsigned char *)"USRRRR", n, 0) == (n == 3 ? BRANDED_OK : BRANDED_ERR_NAMESPACE),
          "namespace length %zu", n);
    CHECK(diff_encode((const unsigned char *)"USRRRR", n, ~0ULL) ==
              (n == 3 ? BRANDED_ERR_RANGE : BRANDED_ERR_NAMESPACE), "namespace length %zu, value 2^64-1", n);
  }
}

static void t_boundaries(void) {
  uint64_t edges[96];
  size_t n = 0;
  uint64_t fixed[] = {0, 1, 61, 62, 3843, 3844, 1ULL << 22, (1ULL << 41) - 1, ((1ULL << 41) - 1) << 22,
                      1ULL << 62, BRD_MAX_SNOW - 1, BRD_MAX_SNOW, 1ULL << 63, (1ULL << 63) + 1,
                      3ULL << 62, ~0ULL, QA * P62_6 - 1, QA * P62_6, QA * P62_6 + RB,
                      (QA - 1) * P62_6 + (P62_6 - 1), P62_6 - 1, P62_6};
  for (size_t i = 0; i < sizeof fixed / sizeof *fixed; i++) edges[n++] = fixed[i];
  uint64_t p = 1;
  for (int k = 1; k <= 10; k++) {
    p *= 62u;
    edges[n++] = p - 1;
    edges[n++] = p;
    edges[n++] = p + 1;
  }
  for (size_t i = 0; i < n; i++) {
    branded_status s = diff_encode((const unsigned char *)"USR", 3, edges[i]);
    CHECK(s == (edges[i] <= BRD_MAX_SNOW ? BRANDED_OK : BRANDED_ERR_RANGE), "edge %llu",
          (unsigned long long)edges[i]);
  }

  /* the arithmetic guard from both sides, as (hi, lo) payloads */
  struct { uint64_t hi, lo; branded_status want; } g[] = {
      {QA, RB, BRANDED_OK},                    /* exactly 2^63 - 1 */
      {QA, RB + 1, BRANDED_ERR_RANGE},         /* exactly 2^63 */
      {QA, P62_6 - 1, BRANDED_ERR_RANGE},
      {QA, 0, BRANDED_OK},
      {QA - 1, P62_6 - 1, BRANDED_OK},
      {QA + 1, 0, BRANDED_ERR_RANGE},
      {916132831ULL, P62_6 - 1, BRANDED_ERR_RANGE}, /* zzzzz zzzzzz */
      {0, 0, BRANDED_OK},
      {0, P62_6 - 1, BRANDED_OK},
  };
  for (size_t i = 0; i < sizeof g / sizeof *g; i++) {
    unsigned char id[BRANDED_LEN] = {'R', 'N', 'G'};
    payload_of(g[i].hi, g[i].lo, id + 3);
    CHECK(diff_decode(id, BRANDED_LEN).s == g[i].want, "guard (hi=%llu, lo=%llu)",
          (unsigned long long)g[i].hi, (unsigned long long)g[i].lo);
  }

  /* the max payload's neighbourhood: every position bumped up is RANGE,
   * every position stepped down is OK */
  const char *top = "AzL8n0Y58m7";
  for (int pos = 0; pos < BRANDED_PAYLOAD_LEN; pos++) {
    int at = ref_digit((unsigned char)top[pos]);
    for (int d = 0; d < 62; d++) {
      unsigned char id[BRANDED_LEN] = {'R', 'N', 'G'};
      memcpy(id + 3, top, 11);
      id[3 + pos] = (unsigned char)BRD_ALPHABET[d];
      dres r = diff_decode(id, BRANDED_LEN);
      if (d > at) CHECK(r.s == BRANDED_ERR_RANGE, "max payload, position %d bumped to %c", pos, BRD_ALPHABET[d]);
      if (d <= at) CHECK(r.s == BRANDED_OK, "max payload, position %d lowered to %c", pos, BRD_ALPHABET[d]);
    }
  }

  /* V-7: byte order == numeric order, every alphabet index in the low digit */
  uint64_t v7[62 + 5];
  size_t m = 0;
  for (uint64_t i = 0; i < 62; i++) v7[m++] = i;
  v7[m++] = 62; v7[m++] = 3843; v7[m++] = 3844; v7[m++] = 1ULL << 22; v7[m++] = BRD_MAX_SNOW;
  for (size_t c = 0; c < NCORES; c++) {
    char prev[BRANDED_LEN], cur[BRANDED_LEN];
    CORES[c].encode("SES", v7[0], prev);
    for (size_t i = 1; i < m; i++) {
      CORES[c].encode("SES", v7[i], cur);
      CHECK(memcmp(prev, cur, BRANDED_LEN) < 0, "%s V-7 order at %llu", CORES[c].name, (unsigned long long)v7[i]);
      memcpy(prev, cur, BRANDED_LEN);
    }
  }
}

static void t_precedence(uint64_t *rng) {
  /* encode: NAMESPACE outranks RANGE */
  static const char *const bad_ns[] = {"usr", "UsR", "US1", "US ", "@AB", "[AB", "AB`", "AB{"};
  static const uint64_t bad_snow[] = {1ULL << 63, (1ULL << 63) + 1, ~0ULL, 3ULL << 62};
  for (size_t i = 0; i < sizeof bad_ns / sizeof *bad_ns; i++)
    for (size_t j = 0; j < 4; j++)
      CHECK(diff_encode((const unsigned char *)bad_ns[i], 3, bad_snow[j]) == BRANDED_ERR_NAMESPACE,
            "encode(%s, %llu) is NAMESPACE", bad_ns[i], (unsigned long long)bad_snow[j]);
  unsigned char odd[3] = {0x00, 0x80, 0xFF};
  CHECK(diff_encode(odd, 3, ~0ULL) == BRANDED_ERR_NAMESPACE, "encode(00 80 ff, 2^64-1)");

  /* decode: LENGTH > NAMESPACE > CHARSET > RANGE */
  struct { const char *id; size_t len; branded_status want; } d[] = {
      {"usr0KHTOWnGL!!", 14, BRANDED_ERR_NAMESPACE},
      {"usrzzzzzzzzzzz", 14, BRANDED_ERR_NAMESPACE}, /* namespace beats range */
      {"USRzzzzzzzzzz!", 14, BRANDED_ERR_CHARSET},
      {"USR!zzzzzzzzzz", 14, BRANDED_ERR_CHARSET},   /* lex-high and off-alphabet */
      {"USR{0000000000", 14, BRANDED_ERR_CHARSET},   /* '{' sorts above 'z' */
      {"USR~0000000000", 14, BRANDED_ERR_CHARSET},
      {"USRzzzzzzzzzz\xff", 14, BRANDED_ERR_CHARSET},
      {"usr0KHTOWnGLu", 13, BRANDED_ERR_LENGTH},
      {"usr!!!!!!!!!!!!", 15, BRANDED_ERR_LENGTH},
  };
  for (size_t i = 0; i < sizeof d / sizeof *d; i++)
    CHECK(diff_decode((const unsigned char *)d[i].id, d[i].len).s == d[i].want, "decode %s", d[i].id);

  /* random multi-fault: lowercase namespace over a random payload */
  for (int i = 0; i < 200000; i++) {
    unsigned char id[BRANDED_LEN];
    for (int j = 0; j < 3; j++) id[j] = (unsigned char)('a' + brd_splitmix64(rng) % 26u);
    for (int j = 3; j < BRANDED_LEN; j++) id[j] = (unsigned char)brd_splitmix64(rng);
    CHECK(diff_decode(id, BRANDED_LEN).s == BRANDED_ERR_NAMESPACE, "lowercase namespace %s", hex(id, 14));
  }
  /* random: a lex-high valid payload with one off-alphabet byte is CHARSET */
  for (int i = 0; i < 200000; i++) {
    unsigned char id[BRANDED_LEN] = {'Z', 'Z', 'Z'};
    for (int j = 3; j < BRANDED_LEN; j++) id[j] = (unsigned char)BRD_ALPHABET[36 + brd_splitmix64(rng) % 26u];
    unsigned char bad;
    do bad = (unsigned char)brd_splitmix64(rng); while (ref_digit(bad) >= 0);
    id[3 + brd_splitmix64(rng) % 11u] = bad;
    CHECK(diff_decode(id, BRANDED_LEN).s == BRANDED_ERR_CHARSET, "charset over range %s", hex(id, 14));
  }
}

static void t_roundtrip(uint64_t *rng, unsigned long n) {
  char prev[BRANDED_PAYLOAD_LEN] = {0};
  uint64_t prev_snow = 0;
  int have_prev = 0;
  for (unsigned long i = 0; i < n; i++) {
    uint64_t r = brd_splitmix64(rng);
    unsigned char ns[3] = {(unsigned char)('A' + r % 26u), (unsigned char)('A' + (r >> 8) % 26u),
                           (unsigned char)('A' + (r >> 16) % 26u)};
    uint64_t raw = brd_splitmix64(rng);
    uint64_t snow = (i & 7u) == 7u ? raw : raw >> 1; /* 1 in 8 raw: half of those >= 2^63 */

    char want[BRANDED_LEN];
    branded_status ws = ref_encode(ns, 3, snow, want);
    char got[NCORES][BRANDED_LEN];
    for (size_t c = 0; c < NCORES; c++) {
      branded_status gs = CORES[c].encode((const char *)ns, snow, got[c]);
      checks++;
      if (gs != ws || (ws == BRANDED_OK && memcmp(got[c], want, BRANDED_LEN) != 0)) {
        CHECK(0, "%s encode(%.3s, %llu) differs from the reference", CORES[c].name, (const char *)ns,
              (unsigned long long)snow);
        continue;
      }
      if (ws != BRANDED_OK) continue;
      char bns[3];
      uint64_t back = 0;
      branded_status bs = CORES[c].decode(got[c], BRANDED_LEN, bns, &back);
      checks++;
      if (bs != BRANDED_OK || back != snow || memcmp(bns, ns, 3) != 0)
        CHECK(0, "%s round trip %llu", CORES[c].name, (unsigned long long)snow);
    }
    if (ws == BRANDED_OK) {
      /* payload byte order must equal numeric order (V-7, generalised) */
      if (have_prev) {
        int cmp = memcmp(prev, want + BRANDED_NS_LEN, BRANDED_PAYLOAD_LEN);
        CHECK((cmp < 0) == (prev_snow < snow) && (cmp == 0) == (prev_snow == snow),
              "byte order != numeric order: %llu vs %llu", (unsigned long long)prev_snow,
              (unsigned long long)snow);
      }
      memcpy(prev, want + BRANDED_NS_LEN, BRANDED_PAYLOAD_LEN);
      prev_snow = snow;
      have_prev = 1;
    } else {
      CHECK(ws == BRANDED_ERR_RANGE && snow > BRD_MAX_SNOW, "only >= 2^63 is refused");
    }
    uint32_t h = ref_hash32(raw);
    uint64_t ms = (snow >> 22) + BRANDED_EPOCH_MS;
    for (size_t c = 0; c < NCORES; c++) {
      checks++;
      if (CORES[c].hash32(raw) != h || CORES[c].unix_ms(snow) != ms)
        CHECK(0, "%s hash32/unix_ms(%llu)", CORES[c].name, (unsigned long long)raw);
    }
  }
}

static void t_noise(uint64_t *rng) {
  for (int i = 0; i < 1000000; i++) {
    unsigned char id[24];
    uint64_t r = brd_splitmix64(rng);
    size_t len = (r & 15u) ? BRANDED_LEN : (size_t)(r >> 4) % 24u;
    for (size_t j = 0; j < len; j++) {
      uint64_t x = brd_splitmix64(rng);
      if (j < 3) id[j] = (x & 31u) ? (unsigned char)('A' + (x >> 5) % 26u) : (unsigned char)(x >> 8);
      else id[j] = (x & 15u) ? (unsigned char)BRD_ALPHABET[(x >> 4) % 62u] : (unsigned char)(x >> 8);
    }
    diff_decode(id, len);
  }
}

int main(int argc, char **argv) {
  unsigned long n = 10000000ul;
  if (argc > 1) n = strtoul(argv[1], NULL, 10);
  uint64_t rng = 0x0B4D1400C0DEULL;
  unsigned long c0, f0;

  c0 = checks, f0 = failures; t_literals();           section("literals", c0, f0);
  c0 = checks, f0 = failures; t_digits();             section("digits", c0, f0);
  c0 = checks, f0 = failures; t_bytes();              section("bytes", c0, f0);
  c0 = checks, f0 = failures; t_lengths();            section("lengths", c0, f0);
  c0 = checks, f0 = failures; t_boundaries();         section("boundaries", c0, f0);
  c0 = checks, f0 = failures; t_precedence(&rng);     section("precedence", c0, f0);
  c0 = checks, f0 = failures; t_roundtrip(&rng, n);   section("roundtrip", c0, f0);
  c0 = checks, f0 = failures; t_noise(&rng);          section("noise", c0, f0);

  printf("%s c props: %zu cores (", failures ? "FAIL" : "ok  ", NCORES);
  for (size_t c = 0; c < NCORES; c++) printf("%s%s", c ? ", " : "", CORES[c].name);
  printf("), %lu round trips, %lu checks, %lu failures\n", n, checks, failures);
  return failures ? 1 : 0;
}
