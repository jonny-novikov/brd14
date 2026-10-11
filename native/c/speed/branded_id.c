/* branded_id.c — optimized libc-only implementation of the branded ID contract.
 *
 * Optimization notes
 * ------------------
 * encode: the naive form is eleven u64 divmods by 62 in one serial dependency
 * chain. This implementation (a) splits the value at 62^6 into hi and lo, two
 * INDEPENDENT chains the CPU overlaps, with both chains in 32-bit registers
 * after their first step (2^63/62^6 = 162,382,637 < 62^5, and lo/3844 < 62^4),
 * and (b) emits two digits per divmod through a 62x62 pair table, so the two
 * chains run 2 + 2 divmods instead of 5 + 6. All divisors are compile-time
 * constants and are strength-reduced to multiply+shift (Granlund & Montgomery,
 * PLDI 1994); the bench proves it by counting div instructions in the object
 * code. The pair-table step is the base-100 itoa technique (Alexandrescu)
 * carried to base 62^2.
 *
 * decode: one 256-byte table maps bytes to digit+1 (0 = invalid), so charset
 * validation and digit extraction share a load. The range check exploits the
 * format itself: fixed-width base62 over an ASCII-ordered alphabet sorts
 * lexicographically, so "value < 2^63" is memcmp(payload, base62(2^63-1)) <= 0
 * — the sortability property doubling as the overflow guard, after which u64
 * accumulation is provably wrap-free. Accumulation is split into the same two
 * independent chains (hi: 5 digits in u32, lo: 6 digits in u64) recombined as
 * hi * 62^6 + lo.
 */
#include "branded_id.h"
#include <string.h>

static const char ALPHABET[62 + 1] =
    "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";

/* PAIRS[2k], PAIRS[2k+1] = the two base62 digits of k, for k in [0, 3844). */
static const char PAIRS[62 * 62 * 2 + 1] =
    "000102030405060708090A0B0C0D0E0F0G0H0I0J0K0L0M0N0O0P0Q0R0S0T0U0V0W0X0Y0Z0a0b0c0d0e0f0g0h0i0j0k0l0m0n0o0p0q0r0s0t0u0v0w0x0y0z"
    "101112131415161718191A1B1C1D1E1F1G1H1I1J1K1L1M1N1O1P1Q1R1S1T1U1V1W1X1Y1Z1a1b1c1d1e1f1g1h1i1j1k1l1m1n1o1p1q1r1s1t1u1v1w1x1y1z"
    "202122232425262728292A2B2C2D2E2F2G2H2I2J2K2L2M2N2O2P2Q2R2S2T2U2V2W2X2Y2Z2a2b2c2d2e2f2g2h2i2j2k2l2m2n2o2p2q2r2s2t2u2v2w2x2y2z"
    "303132333435363738393A3B3C3D3E3F3G3H3I3J3K3L3M3N3O3P3Q3R3S3T3U3V3W3X3Y3Z3a3b3c3d3e3f3g3h3i3j3k3l3m3n3o3p3q3r3s3t3u3v3w3x3y3z"
    "404142434445464748494A4B4C4D4E4F4G4H4I4J4K4L4M4N4O4P4Q4R4S4T4U4V4W4X4Y4Z4a4b4c4d4e4f4g4h4i4j4k4l4m4n4o4p4q4r4s4t4u4v4w4x4y4z"
    "505152535455565758595A5B5C5D5E5F5G5H5I5J5K5L5M5N5O5P5Q5R5S5T5U5V5W5X5Y5Z5a5b5c5d5e5f5g5h5i5j5k5l5m5n5o5p5q5r5s5t5u5v5w5x5y5z"
    "606162636465666768696A6B6C6D6E6F6G6H6I6J6K6L6M6N6O6P6Q6R6S6T6U6V6W6X6Y6Z6a6b6c6d6e6f6g6h6i6j6k6l6m6n6o6p6q6r6s6t6u6v6w6x6y6z"
    "707172737475767778797A7B7C7D7E7F7G7H7I7J7K7L7M7N7O7P7Q7R7S7T7U7V7W7X7Y7Z7a7b7c7d7e7f7g7h7i7j7k7l7m7n7o7p7q7r7s7t7u7v7w7x7y7z"
    "808182838485868788898A8B8C8D8E8F8G8H8I8J8K8L8M8N8O8P8Q8R8S8T8U8V8W8X8Y8Z8a8b8c8d8e8f8g8h8i8j8k8l8m8n8o8p8q8r8s8t8u8v8w8x8y8z"
    "909192939495969798999A9B9C9D9E9F9G9H9I9J9K9L9M9N9O9P9Q9R9S9T9U9V9W9X9Y9Z9a9b9c9d9e9f9g9h9i9j9k9l9m9n9o9p9q9r9s9t9u9v9w9x9y9z"
    "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"
    "e0e1e2e3e4e5e6e7e8e9eAeBeCeDeEeFeGeHeIeJeKeLeMeNeOePeQeReSeTeUeVeWeXeYeZeaebecedeeefegeheiejekelemeneoepeqereseteuevewexeyez"
    "f0f1f2f3f4f5f6f7f8f9fAfBfCfDfEfFfGfHfIfJfKfLfMfNfOfPfQfRfSfTfUfVfWfXfYfZfafbfcfdfefffgfhfifjfkflfmfnfofpfqfrfsftfufvfwfxfyfz"
    "g0g1g2g3g4g5g6g7g8g9gAgBgCgDgEgFgGgHgIgJgKgLgMgNgOgPgQgRgSgTgUgVgWgXgYgZgagbgcgdgegfggghgigjgkglgmgngogpgqgrgsgtgugvgwgxgygz"
    "h0h1h2h3h4h5h6h7h8h9hAhBhChDhEhFhGhHhIhJhKhLhMhNhOhPhQhRhShThUhVhWhXhYhZhahbhchdhehfhghhhihjhkhlhmhnhohphqhrhshthuhvhwhxhyhz"
    "i0i1i2i3i4i5i6i7i8i9iAiBiCiDiEiFiGiHiIiJiKiLiMiNiOiPiQiRiSiTiUiViWiXiYiZiaibicidieifigihiiijikiliminioipiqirisitiuiviwixiyiz"
    "j0j1j2j3j4j5j6j7j8j9jAjBjCjDjEjFjGjHjIjJjKjLjMjNjOjPjQjRjSjTjUjVjWjXjYjZjajbjcjdjejfjgjhjijjjkjljmjnjojpjqjrjsjtjujvjwjxjyjz"
    "k0k1k2k3k4k5k6k7k8k9kAkBkCkDkEkFkGkHkIkJkKkLkMkNkOkPkQkRkSkTkUkVkWkXkYkZkakbkckdkekfkgkhkikjkkklkmknkokpkqkrksktkukvkwkxkykz"
    "l0l1l2l3l4l5l6l7l8l9lAlBlClDlElFlGlHlIlJlKlLlMlNlOlPlQlRlSlTlUlVlWlXlYlZlalblcldlelflglhliljlklllmlnlolplqlrlsltlulvlwlxlylz"
    "m0m1m2m3m4m5m6m7m8m9mAmBmCmDmEmFmGmHmImJmKmLmMmNmOmPmQmRmSmTmUmVmWmXmYmZmambmcmdmemfmgmhmimjmkmlmmmnmompmqmrmsmtmumvmwmxmymz"
    "n0n1n2n3n4n5n6n7n8n9nAnBnCnDnEnFnGnHnInJnKnLnMnNnOnPnQnRnSnTnUnVnWnXnYnZnanbncndnenfngnhninjnknlnmnnnonpnqnrnsntnunvnwnxnynz"
    "o0o1o2o3o4o5o6o7o8o9oAoBoCoDoEoFoGoHoIoJoKoLoMoNoOoPoQoRoSoToUoVoWoXoYoZoaobocodoeofogohoiojokolomonooopoqorosotouovowoxoyoz"
    "p0p1p2p3p4p5p6p7p8p9pApBpCpDpEpFpGpHpIpJpKpLpMpNpOpPpQpRpSpTpUpVpWpXpYpZpapbpcpdpepfpgphpipjpkplpmpnpopppqprpsptpupvpwpxpypz"
    "q0q1q2q3q4q5q6q7q8q9qAqBqCqDqEqFqGqHqIqJqKqLqMqNqOqPqQqRqSqTqUqVqWqXqYqZqaqbqcqdqeqfqgqhqiqjqkqlqmqnqoqpqqqrqsqtquqvqwqxqyqz"
    "r0r1r2r3r4r5r6r7r8r9rArBrCrDrErFrGrHrIrJrKrLrMrNrOrPrQrRrSrTrUrVrWrXrYrZrarbrcrdrerfrgrhrirjrkrlrmrnrorprqrrrsrtrurvrwrxryrz"
    "s0s1s2s3s4s5s6s7s8s9sAsBsCsDsEsFsGsHsIsJsKsLsMsNsOsPsQsRsSsTsUsVsWsXsYsZsasbscsdsesfsgshsisjskslsmsnsospsqsrssstsusvswsxsysz"
    "t0t1t2t3t4t5t6t7t8t9tAtBtCtDtEtFtGtHtItJtKtLtMtNtOtPtQtRtStTtUtVtWtXtYtZtatbtctdtetftgthtitjtktltmtntotptqtrtstttutvtwtxtytz"
    "u0u1u2u3u4u5u6u7u8u9uAuBuCuDuEuFuGuHuIuJuKuLuMuNuOuPuQuRuSuTuUuVuWuXuYuZuaubucudueufuguhuiujukulumunuoupuqurusutuuuvuwuxuyuz"
    "v0v1v2v3v4v5v6v7v8v9vAvBvCvDvEvFvGvHvIvJvKvLvMvNvOvPvQvRvSvTvUvVvWvXvYvZvavbvcvdvevfvgvhvivjvkvlvmvnvovpvqvrvsvtvuvvvwvxvyvz"
    "w0w1w2w3w4w5w6w7w8w9wAwBwCwDwEwFwGwHwIwJwKwLwMwNwOwPwQwRwSwTwUwVwWwXwYwZwawbwcwdwewfwgwhwiwjwkwlwmwnwowpwqwrwswtwuwvwwwxwywz"
    "x0x1x2x3x4x5x6x7x8x9xAxBxCxDxExFxGxHxIxJxKxLxMxNxOxPxQxRxSxTxUxVxWxXxYxZxaxbxcxdxexfxgxhxixjxkxlxmxnxoxpxqxrxsxtxuxvxwxxxyxz"
    "y0y1y2y3y4y5y6y7y8y9yAyByCyDyEyFyGyHyIyJyKyLyMyNyOyPyQyRySyTyUyVyWyXyYyZyaybycydyeyfygyhyiyjykylymynyoypyqyrysytyuyvywyxyyyz"
    "z0z1z2z3z4z5z6z7z8z9zAzBzCzDzEzFzGzHzIzJzKzLzMzNzOzPzQzRzSzTzUzVzWzXzYzZzazbzczdzezfzgzhzizjzkzlzmznzozpzqzrzsztzuzvzwzxzyzz";

/* base62(2^63 - 1): the largest valid payload. Verified in the test suite. */
static const char MAX_PAYLOAD[BRANDED_PAYLOAD_LEN] =
    {'A','z','L','8','n','0','Y','5','8','m','7'};

#define P62_6 56800235584ULL /* 62^6 = 3844^3 */

/* byte -> base62 digit + 1; 0 marks an invalid byte. */
static const unsigned char B62[256] = {
    ['0']=1, ['1']=2, ['2']=3, ['3']=4, ['4']=5, ['5']=6, ['6']=7, ['7']=8,
    ['8']=9, ['9']=10, ['A']=11, ['B']=12, ['C']=13, ['D']=14, ['E']=15,
    ['F']=16, ['G']=17, ['H']=18, ['I']=19, ['J']=20, ['K']=21, ['L']=22,
    ['M']=23, ['N']=24, ['O']=25, ['P']=26, ['Q']=27, ['R']=28, ['S']=29,
    ['T']=30, ['U']=31, ['V']=32, ['W']=33, ['X']=34, ['Y']=35, ['Z']=36,
    ['a']=37, ['b']=38, ['c']=39, ['d']=40, ['e']=41, ['f']=42, ['g']=43,
    ['h']=44, ['i']=45, ['j']=46, ['k']=47, ['l']=48, ['m']=49, ['n']=50,
    ['o']=51, ['p']=52, ['q']=53, ['r']=54, ['s']=55, ['t']=56, ['u']=57,
    ['v']=58, ['w']=59, ['x']=60, ['y']=61, ['z']=62
};

static inline int ns_valid(const char ns[BRANDED_NS_LEN]) {
  return ((unsigned)(ns[0] - 'A') <= 25u) & ((unsigned)(ns[1] - 'A') <= 25u) &
         ((unsigned)(ns[2] - 'A') <= 25u);
}

static inline void put_pair(char *dst, uint32_t k) {
  dst[0] = PAIRS[2u * k];
  dst[1] = PAIRS[2u * k + 1u];
}

branded_status branded_encode(const char ns[BRANDED_NS_LEN], uint64_t snowflake,
                              char out[BRANDED_LEN]) {
  if (snowflake > (uint64_t)INT64_MAX) return BRANDED_ERR_RANGE;
  if (!ns_valid(ns)) return BRANDED_ERR_NAMESPACE;

  out[0] = ns[0]; out[1] = ns[1]; out[2] = ns[2];
  char *p = out + BRANDED_NS_LEN; /* p[0..10] = the 11 payload digits */

  uint32_t hi = (uint32_t)(snowflake / P62_6); /* < 62^5: digits p[0..4]  */
  uint64_t lo = snowflake % P62_6;             /* < 62^6: digits p[5..10] */

  /* chain A: 2 divmods */
  put_pair(p + 3, hi % 3844u); hi /= 3844u;
  put_pair(p + 1, hi % 3844u); hi /= 3844u;
  p[0] = ALPHABET[hi];                         /* hi < 62 */

  /* chain B: 2 divmods, independent of chain A */
  put_pair(p + 9, (uint32_t)(lo % 3844u));
  uint32_t l = (uint32_t)(lo / 3844u);         /* < 62^4: fits u32 */
  put_pair(p + 7, l % 3844u); l /= 3844u;
  put_pair(p + 5, l);                          /* l < 3844: is a pair index */

  return BRANDED_OK;
}

branded_status branded_decode(const char *id, size_t len,
                              char ns_out[BRANDED_NS_LEN], uint64_t *snowflake_out) {
  if (len != BRANDED_LEN) return BRANDED_ERR_LENGTH;
  if (!ns_valid(id)) return BRANDED_ERR_NAMESPACE;

  const unsigned char *p = (const unsigned char *)id + BRANDED_NS_LEN;

  unsigned invalid = 0;
  uint32_t hi = 0; /* digits p[0..4]:  < 62^5, fits u32  */
  uint64_t lo = 0; /* digits p[5..10]: < 62^6            */
  for (int i = 0; i < 5; i++) {
    unsigned d = B62[p[i]];
    invalid |= (d == 0u);
    hi = hi * 62u + (d - 1u);
  }
  for (int i = 5; i < BRANDED_PAYLOAD_LEN; i++) {
    unsigned d = B62[p[i]];
    invalid |= (d == 0u);
    lo = lo * 62u + (uint64_t)(d - 1u);
  }
  if (invalid) return BRANDED_ERR_CHARSET;

  /* Lexicographic order equals numeric order for this format. */
  if (memcmp(p, MAX_PAYLOAD, BRANDED_PAYLOAD_LEN) > 0) return BRANDED_ERR_RANGE;

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
