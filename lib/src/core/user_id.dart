/// Longest user ID, in characters (contract section 2).
const int maxUserIdLength = 256;

final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f-\u009f]');

/// Returns [id] when it is a user ID the SDK API accepts: 1 to
/// [maxUserIdLength] characters (Unicode code points) without control
/// characters (contract section 2).
///
/// Throws an [ArgumentError] otherwise. The message never contains the ID,
/// which identifies a person. Internal to the SDK.
String checkUserId(String id) {
  final length = id.runes.length;
  if (length == 0 || length > maxUserIdLength) {
    throw ArgumentError(
      'must be 1 to $maxUserIdLength characters (is $length)',
      'id',
    );
  }
  if (_controlCharacters.hasMatch(id)) {
    throw ArgumentError('must not contain control characters', 'id');
  }
  return id;
}
