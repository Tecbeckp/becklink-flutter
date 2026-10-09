final _controlCharacters = RegExp(r'[\u0000-\u001f\u007f-\u009f]+');

/// [text] on one line (control characters become a space) and at most
/// [maxLength] UTF-16 units long, ending in `…` when shortened, without
/// splitting a surrogate pair.
///
/// For server-provided text that ends up in exception messages and logs: a
/// line break could forge extra log lines, and an unbounded text could flood
/// the console. Internal to the SDK.
String singleLine(String text, {required int maxLength}) {
  final line = text.replaceAll(_controlCharacters, ' ').trim();
  if (line.length <= maxLength) return line;
  var end = maxLength - 1;
  final last = line.codeUnitAt(end - 1);
  if (last >= 0xd800 && last <= 0xdbff) end--;
  return '${line.substring(0, end)}…';
}
