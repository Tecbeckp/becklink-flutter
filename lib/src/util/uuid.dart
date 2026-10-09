import 'dart:math';

/// Returns a random UUID version 4 in the lowercase 8-4-4-4-12 form the SDK
/// API expects for `install_id`, `first_open_id`, `event_id` and
/// `Idempotency-Key` (contract section 2).
///
/// [random] must be a cryptographically secure generator in production
/// ([Random.secure]): IDs must not be guessable, because an install ID is
/// the only thing that ties events to an install.
String uuidV4(Random random) {
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  // RFC 9562 section 5.4: version 4 in the high nibble of byte 6, variant
  // 0b10 in the two high bits of byte 8.
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0'));
  final digits = hex.join();
  return '${digits.substring(0, 8)}-${digits.substring(8, 12)}-'
      '${digits.substring(12, 16)}-${digits.substring(16, 20)}-'
      '${digits.substring(20)}';
}

final _uuidFormat = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
);

const _nilUuid = '00000000-0000-0000-0000-000000000000';

/// [value] in lowercase when it is a UUID the SDK API accepts, otherwise
/// `null`.
///
/// Accepts the 8-4-4-4-12 form of any RFC 9562 version in either case,
/// except the nil UUID (contract section 2): IDs that come from outside the
/// SDK's own generator, such as an install ID kept in the iOS Keychain or
/// read back from storage, need not be version 4.
String? normalizeUuid(String value) {
  final lower = value.toLowerCase();
  if (!_uuidFormat.hasMatch(lower) || lower == _nilUuid) return null;
  return lower;
}
