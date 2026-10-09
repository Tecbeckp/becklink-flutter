import 'dart:convert';

// FNV-1a 64-bit parameters (draft-eastlake-fnv). The offset basis is above
// 2^63, so on the Dart VM it is stored as the negative int with the same
// bit pattern; multiplication wraps modulo 2^64, as FNV requires.
const int _offsetBasis = 0xcbf29ce484222325;
const int _prime = 0x100000001b3;

/// The 64-bit FNV-1a digest of the UTF-8 bytes of [text], as 16 lowercase
/// hex digits.
///
/// A compact, stable fingerprint for local bookkeeping (for example which
/// links were already delivered), so the text itself does not have to be
/// stored. It is not a cryptographic hash and must not protect secrets.
/// Internal to the SDK.
String fnv1a64Hex(String text) {
  var hash = _offsetBasis;
  for (final byte in utf8.encode(text)) {
    hash ^= byte;
    hash *= _prime;
  }
  // Two 32-bit halves, because the VM cannot show the top bit of a 64-bit
  // int as an unsigned hex digit.
  final high = (hash >> 32) & 0xffffffff;
  final low = hash & 0xffffffff;
  return '${high.toRadixString(16).padLeft(8, '0')}'
      '${low.toRadixString(16).padLeft(8, '0')}';
}
