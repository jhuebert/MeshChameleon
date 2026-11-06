import 'dart:convert';
import 'dart:typed_data';

/// Maximum advertised-name length in UTF-8 bytes.
const int maxAdvertNameBytes = 31;

bool _isControlRune(int rune) => rune < 0x20 || (rune >= 0x7F && rune <= 0x9F);

/// Validate a name supplied as a Dart string.
///
/// Names are nonempty, at most [maxAdvertNameBytes] UTF-8 bytes, contain no
/// embedded NUL, and contain no control characters. Returns the name when
/// valid, otherwise `null`.
String? validateAdvertName(String name) {
  if (name.isEmpty) return null;
  final bytes = utf8.encode(name);
  if (bytes.length > maxAdvertNameBytes) return null;
  if (bytes.contains(0)) return null;
  if (name.runes.any(_isControlRune)) return null;
  return name;
}

/// Decode a binary `SET_ADVERT_NAME` payload.
///
/// Stock firmware treats the field as a C string and truncates it to 31 bytes.
/// An optional trailing NUL is accepted; embedded NULs end the name. Overlong
/// names are truncated on a UTF-8 boundary. Empty names, malformed UTF-8, and
/// control characters are still rejected.
String? decodeAdvertNameBytes(List<int> raw) {
  var bytes = raw;
  final nul = bytes.indexOf(0);
  if (nul >= 0) bytes = bytes.sublist(0, nul);
  if (bytes.isEmpty) return null;
  if (bytes.length > maxAdvertNameBytes) {
    bytes = bytes.sublist(0, utf8CutIndex(bytes, maxAdvertNameBytes));
  }
  try {
    return validateAdvertName(utf8.decode(bytes));
  } on FormatException {
    return null;
  }
}

/// Decode a fixed-size contact-name field.
///
/// Bytes after the first NUL are ignored as padding. The name may be empty for
/// an explicitly added contact, but malformed UTF-8, overlong values, and
/// control characters are rejected.
String? decodeContactNameBytes(List<int> raw) {
  final nul = raw.indexOf(0);
  final bytes = nul >= 0 ? raw.sublist(0, nul) : raw;
  if (bytes.length > maxAdvertNameBytes) return null;
  try {
    final name = utf8.decode(bytes);
    if (name.runes.any(_isControlRune)) return null;
    return name;
  } on FormatException {
    return null;
  }
}

/// Whether integer microdegree coordinates are within the virtual limits.
bool isValidAdvertCoordinateMicros(int latMicros, int lonMicros) =>
    latMicros >= -90000000 &&
    latMicros <= 90000000 &&
    lonMicros >= -180000000 &&
    lonMicros <= 180000000;

/// Index at which [bytes] can be cut without splitting a UTF-8 sequence.
///
/// [limit] is clamped to the list length; continuation bytes are backed off
/// until the cut lands on a code-point boundary.
int utf8CutIndex(List<int> bytes, int limit) {
  var end = limit < bytes.length ? limit : bytes.length;
  if (end < 0) end = 0;
  while (end > 0 && end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
    end--;
  }
  return end;
}

/// Truncate UTF-8 [bytes] to at most [maxBytes], appending [ellipsis].
///
/// The ellipsis is included in the limit. When the limit is smaller than the
/// ellipsis itself, the ellipsis is cut to fit.
Uint8List truncateUtf8Bytes(
  List<int> bytes,
  int maxBytes, {
  String ellipsis = '...',
}) {
  if (maxBytes <= 0) return Uint8List(0);
  if (bytes.length <= maxBytes) return Uint8List.fromList(bytes);
  final marker = utf8.encode(ellipsis);
  if (maxBytes <= marker.length) {
    return Uint8List.fromList(marker.sublist(0, maxBytes));
  }
  final end = utf8CutIndex(bytes, maxBytes - marker.length);
  return Uint8List.fromList([...bytes.sublist(0, end), ...marker]);
}
