/// FNV-1a, the one hash both ports share.
///
/// Two call sites need a stable hash: the compression fingerprint and the
/// bag-of-ngrams embedding. Neither is a security boundary - the fingerprint
/// dedupes identical text and the embedding buckets features - so neither
/// needs a cryptographic primitive, and the previous SHA-256 was truncated
/// to 64 bits anyway, which leaves roughly 32 bits of collision resistance
/// under the birthday bound.
///
/// **Everything here is deliberately arithmetic, never bitwise.** Compiled
/// to JavaScript a Dart `int` is a double and `&`, `<<`, `>>`, `^` truncate
/// to signed 32 bits, so the obvious implementation gives different answers
/// on web than on the VM. `%`, `~/` and `*` stay exact as long as every
/// intermediate is below 2^53, which the limb sizes below guarantee. The
/// 64-bit state is carried as two 32-bit halves for the same reason.
///
/// Must stay bit-identical to `src/state_projection_loop/hashing.py`;
/// `spec/fixtures/compression.json` pins that.
library;

const int _p32 = 0x100000000; // 2^32
const int _p16 = 0x10000; // 2^16

// FNV-1a 64: offset basis 0xCBF29CE484222325, prime 0x100000001B3.
const int _fnv64OffsetHi = 0xCBF29CE4;
const int _fnv64OffsetLo = 0x84222325;
// 0x100000001B3 splits as 0x100 * 2^32 + 0x1B3 - the high word is 0x100,
// not 1. Getting that wrong still yields a correct low half, so the low
// 32 bits of the digest match while the high 32 bits silently do not.
const int _fnv64PrimeHi = 0x100;
const int _fnv64PrimeLo = 0x1B3;

const int _fnv32Offset = 0x811C9DC5;
const int _fnv32Prime = 0x01000193;

/// XOR a single byte into the low 8 bits of a non-negative 32-bit value.
///
/// Only the low byte can change, so the XOR itself stays under 256 and is
/// safe on every platform; the rest of the value is carried arithmetically.
int _xorByte(int value, int byte) {
  final low = value % 0x100;
  return value - low + (low ^ (byte % 0x100));
}

/// 32x32 -> low 32 bits, via 16-bit limbs so no intermediate exceeds 2^48.
int _mul32(int a, int b) {
  final aLo = a % _p16, aHi = a ~/ _p16;
  final bLo = b % _p16, bHi = b ~/ _p16;
  final mid = (aHi * bLo + aLo * bHi) % _p16;
  return (aLo * bLo + mid * _p16) % _p32;
}

/// FNV-1a 64 over [bytes], returned as `(hi, lo)` 32-bit halves.
///
/// `hi * 2^64` vanishes mod 2^64, so the product is
/// `(hi*primeLo + lo*primeHi + carry) * 2^32 + (lo*primeLo mod 2^32)`.
/// No general 64x64 multiply is needed and every intermediate stays below
/// 2^42, well inside the 2^53 that survives compilation to JavaScript.
(int, int) fnv1a64Parts(List<int> bytes) {
  var hi = _fnv64OffsetHi;
  var lo = _fnv64OffsetLo;
  for (final byte in bytes) {
    lo = _xorByte(lo, byte);
    final low = lo * _fnv64PrimeLo;
    final carry = low ~/ _p32;
    hi = (hi * _fnv64PrimeLo + lo * _fnv64PrimeHi + carry) % _p32;
    lo = low % _p32;
  }
  return (hi, lo);
}

/// FNV-1a 32 over [bytes].
int fnv1a32(List<int> bytes) {
  var h = _fnv32Offset;
  for (final byte in bytes) {
    h = _mul32(_xorByte(h, byte), _fnv32Prime);
  }
  return h;
}

/// 16 lowercase hex digits - the full 64-bit digest, not a truncation.
String fnv1a64Hex(List<int> bytes) {
  final (hi, lo) = fnv1a64Parts(bytes);
  return hi.toRadixString(16).padLeft(8, '0') +
      lo.toRadixString(16).padLeft(8, '0');
}
