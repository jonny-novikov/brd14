/* branded_id.c — memory-optimized libc-free implementation of the branded ID
 * contract: the same ABI as ../speed, and not one byte of lookup table.
 *
 * Footprint notes
 * ---------------
 * The speed core spends ~8 KB of .rodata (a 7,688-byte pair table, a 256-byte
 * decode table, the alphabet, the max payload) to save cycles. That is cheap
 * on a server and expensive wherever cache lines are contested: wasm, small
 * cores, or a hot loop whose L1 is shared with real work. This core carries no
 * data at all — each table becomes a few ALU ops — and `make gates` shows its
 * .rodata as 0 bytes and its undefined-symbol list as empty (no libc calls).
 *
 * encode: the same split at 62^6 as the speed core, hi = value / 62^6 (5
 * digits, <= QA < 2^28) and lo = value % 62^6 (6 digits), so the work is two
 * INDEPENDENT dependency chains the CPU overlaps; the loop below interleaves
 * them so every iteration issues one step of each. Unlike the speed core it
 * emits one digit per divmod (no pair table). Digit -> char is arithmetic: the
 * alphabet is three ASCII runs, '0'..'9' then 'A'..'Z' (+7 past '9') then
 * 'a'..'z' (+6 more past 'Z'), so c = d + '0' + 7*[d > 9] + 6*[d > 35], each
 * bracket the sign bit of an unsigned subtraction (9 - d wraps iff d > 9):
 * branch-free and table-free. The test suite checks all 62 digits.
 *
 * Every divisor is a compile-time constant, and the reciprocals are written
 * out by hand rather than left to the compiler, because this core is built
 * with -Os and at -Os gcc 13 emits a real `div` for constant divisors (the
 * shorter encoding; tens of cycles of latency where a multiply costs 3). Spelling
 * out the multiply-high (Granlund & Montgomery, PLDI 1994) makes "no div in
 * encode or decode" hold at every optimisation level; `make gates` checks it
 * in the object code, and the _Static_asserts below are the exactness proofs,
 * evaluated by the compiler on every build.
 *
 * decode: each payload byte is classified by three disjoint unsigned-wrap
 * range masks, (b - '0') < 10, (b - 'A') < 26, (b - 'a') < 26 — a byte below
 * a range's start wraps to a huge unsigned value, so one compare checks both
 * ends. The digit is b - '0' - 7*upper - 13*lower, and an invalid byte is
 * tagged with bit 8; the tags are OR-folded across all 11 bytes and tested
 * once after accumulation (unsigned wraparound makes the garbage digits
 * harmless), so the loop has no data-dependent branch. The range guard is
 * arithmetic, on the same split:
 * 2^63 - 1 = QA * 62^6 + RB, so value < 2^63 iff
 * hi < QA || (hi == QA && lo <= RB) — no max-payload constant, no memcmp, and
 * because it runs after the charset check, accumulation never needs more than
 * u32 for hi (62^5 < 2^30) and u64 for lo (62^6 < 2^36).
 */
#include "branded_id.h"

#define P62_5 916132832ULL   /* 62^5 */
#define P62_6 56800235584ULL /* 62^6 */
#define QA    162382637u     /* (2^63 - 1) / 62^6 */
#define RB    503620799ULL   /* (2^63 - 1) % 62^6 */

_Static_assert(QA * P62_6 + RB == (uint64_t)INT64_MAX, "2^63 - 1 == QA * 62^6 + RB");
_Static_assert(RB < P62_6, "RB is a remainder mod 62^6");
_Static_assert(QA < (1u << 28), "hi of any in-range value fits 28 bits");

/* x / 62 for x < 2^30: one 32x32->64 multiply and a shift. m = ceil(2^35/62),
 * e = 62m - 2^35 = 30, and floor(x*m / 2^35) == floor(x / 62) whenever
 * x*e < 2^35 — true for every x < 2^30. Both chains stay inside: hi <= QA,
 * and lo is below 62^5 after its first step. */
#define M62 554189329ULL
#define S62 35
_Static_assert(M62 * 62u >= (1ULL << S62) && M62 * 62u - (1ULL << S62) < 62u, "M62 = ceil(2^35/62)");
_Static_assert(((1ULL << 30) - 1) * (M62 * 62u - (1ULL << S62)) < (1ULL << S62), "div62 exact below 2^30");
_Static_assert(P62_5 <= (1ULL << 30), "lo after one step is in div62's domain");

/* value / 62^6 for value < 2^63: multiply-high by ceil(2^98 / 62^6), then
 * shift 34. The error term e = m*62^6 - 2^98 is just under 2^35, so the bound
 * (2^63 - 1) * e < 2^98 holds with almost no slack: this reciprocal is exact
 * for the contract's domain and not one bit wider. Encode applies it only
 * after the range check. */
#define M_SPLIT 0x4D6E196812289D0FULL
#define S_SPLIT 34
/* lo / 62 for lo < 62^6 (the lo chain's first, 36-bit step): multiply-high by
 * ceil(2^64 / 62); e = 46 and (62^6 - 1) * 46 < 2^64. */
#define M_LO 0x0421084210842109ULL

#if defined(__SIZEOF_INT128__)
__extension__ typedef unsigned __int128 brd_u128;
_Static_assert((brd_u128)M_SPLIT * P62_6 >= ((brd_u128)1 << 98) &&
               (brd_u128)M_SPLIT * P62_6 - ((brd_u128)1 << 98) < P62_6, "M_SPLIT = ceil(2^98/62^6)");
_Static_assert((brd_u128)INT64_MAX * ((brd_u128)M_SPLIT * P62_6 - ((brd_u128)1 << 98)) <
               ((brd_u128)1 << 98), "split exact for every value < 2^63");
_Static_assert((brd_u128)M_LO * 62u >= ((brd_u128)1 << 64) &&
               (brd_u128)M_LO * 62u - ((brd_u128)1 << 64) < 62u, "M_LO = ceil(2^64/62)");
_Static_assert((brd_u128)(P62_6 - 1) * ((brd_u128)M_LO * 62u - ((brd_u128)1 << 64)) <
               ((brd_u128)1 << 64), "lo / 62 exact below 62^6");
#endif

/* High 64 bits of a 64x64 product. One `mul` where the compiler has a 128-bit
 * type; otherwise exact schoolbook on 32-bit limbs (mid < 3 * 2^32, so no
 * carry is lost). BRANDED_NO_INT128 forces the portable path; the test suite
 * builds and checks it so it cannot rot unseen. */
static inline uint64_t mulhi64(uint64_t a, uint64_t b) {
#if defined(__SIZEOF_INT128__) && !defined(BRANDED_NO_INT128)
  return (uint64_t)(((brd_u128)a * b) >> 64);
#else
  uint64_t al = a & 0xFFFFFFFFu, ah = a >> 32, bl = b & 0xFFFFFFFFu, bh = b >> 32;
  uint64_t ll = al * bl, lh = al * bh, hl = ah * bl, hh = ah * bh;
  uint64_t mid = (ll >> 32) + (lh & 0xFFFFFFFFu) + (hl & 0xFFFFFFFFu);
  return hh + (lh >> 32) + (hl >> 32) + (mid >> 32);
#endif
}

static inline uint32_t div62(uint32_t x) {
  return (uint32_t)(((uint64_t)x * M62) >> S62);
}

/* d in [0, 62) -> its alphabet char, with no table and no branch. */
static inline char b62_char(uint32_t d) {
  return (char)(d + '0' + 7u * ((9u - d) >> 31) + 6u * ((35u - d) >> 31));
}

/* Three bytes of [A-Z]. Read as unsigned char so bytes >= 0x80 classify the
 * same whether plain char is signed or not. */
static inline uint32_t ns_valid(const unsigned char *n) {
  return ((uint32_t)(n[0] - 'A') < 26u) & ((uint32_t)(n[1] - 'A') < 26u) &
         ((uint32_t)(n[2] - 'A') < 26u);
}

/* Byte -> base62 digit, tagged. The three ranges are disjoint, so at most one
 * mask is set; a valid byte returns its digit (< 62), and a byte outside
 * [0-9A-Za-z] returns (b - '0' + 256) mod 2^32, which is >= 208 for every
 * such byte. So the OR of all eleven results is >= 64 iff any byte was bad:
 * validity rides along in the value itself, with no flag variable. (A flag
 * passed by pointer would make -fstack-protector-strong, the Ubuntu default,
 * plant a canary and a __stack_chk_fail reference whenever -Os keeps this
 * helper out of line.) */
static inline uint32_t b62_digit(uint32_t b) {
  uint32_t dig = (b - '0') < 10u;
  uint32_t up  = (b - 'A') < 26u;
  uint32_t low = (b - 'a') < 26u;
  return b - '0' - 7u * up - 13u * low + (((dig | up | low) ^ 1u) << 8);
}

branded_status branded_encode(const char ns[BRANDED_NS_LEN], uint64_t snowflake,
                              char out[BRANDED_LEN]) {
  /* Namespace-first (docs/contract.md): NAMESPACE outranks RANGE. */
  if (!ns_valid((const unsigned char *)ns)) return BRANDED_ERR_NAMESPACE;
  if (snowflake > (uint64_t)INT64_MAX) return BRANDED_ERR_RANGE;

  out[0] = ns[0]; out[1] = ns[1]; out[2] = ns[2];
  char *p = out + BRANDED_NS_LEN; /* p[0..10] = the 11 payload digits */

  uint32_t hi = (uint32_t)(mulhi64(snowflake, M_SPLIT) >> S_SPLIT); /* <= QA: p[0..4] */
  uint64_t lo = snowflake - (uint64_t)hi * P62_6;                    /* < 62^6: p[5..10] */

  /* The lo chain's first step is the only one wider than 30 bits. */
  uint32_t l = (uint32_t)mulhi64(lo, M_LO); /* lo / 62 < 62^5 */
  p[10] = b62_char((uint32_t)(lo - (uint64_t)l * 62u));

  /* Five steps of each chain, interleaved: no step depends on the other
   * chain, so both multiplies are in flight together. */
  for (int i = 4; i >= 0; i--) {
    uint32_t qh = div62(hi), ql = div62(l);
    p[i] = b62_char(hi - qh * 62u);
    p[i + 5] = b62_char(l - ql * 62u);
    hi = qh;
    l = ql;
  }
  return BRANDED_OK;
}

branded_status branded_decode(const char *id, size_t len,
                              char ns_out[BRANDED_NS_LEN], uint64_t *snowflake_out) {
  if (len != BRANDED_LEN) return BRANDED_ERR_LENGTH;
  const unsigned char *u = (const unsigned char *)id;
  if (!ns_valid(u)) return BRANDED_ERR_NAMESPACE;

  const unsigned char *p = u + BRANDED_NS_LEN;
  uint32_t tags = b62_digit(p[5]);
  uint32_t hi = 0;    /* digits p[0..4]:  < 62^5, fits u32 */
  uint64_t lo = tags; /* digits p[5..10]: < 62^6           */
  for (int i = 0; i < 5; i++) { /* the two Horner chains, interleaved */
    uint32_t dh = b62_digit(p[i]), dl = b62_digit(p[i + 6]);
    tags |= dh | dl;
    hi = hi * 62u + dh;
    lo = lo * 62u + dl;
  }
  if (tags >= 64u) return BRANDED_ERR_CHARSET;

  /* Arithmetic range guard: (hi, lo) <= (QA, RB) in lexicographic order. */
  if (!((hi < QA) | ((hi == QA) & (lo <= RB)))) return BRANDED_ERR_RANGE;

  ns_out[0] = id[0]; ns_out[1] = id[1]; ns_out[2] = id[2];
  *snowflake_out = (uint64_t)hi * P62_6 + lo;
  return BRANDED_OK;
}

uint32_t branded_hash32(uint64_t key) {
  key ^= key >> 33;
  key *= 0xFF51AFD7ED558CCDULL;
  key ^= key >> 33;
  return (uint32_t)key;
}

uint64_t branded_unix_ms(uint64_t snowflake) {
  return (snowflake >> 22) + BRANDED_EPOCH_MS;
}
