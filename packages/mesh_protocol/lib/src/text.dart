import 'dart:convert';

/// Maximum advertised-name length in UTF-8 bytes.
const int maxAdvertNameBytes = 31;

bool _isControlRune(int rune) =>
    rune < 0x20 || (rune >= 0x7F && rune <= 0x9F);

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
/// An optional single trailing NUL terminator is accepted and removed. Embedded
/// NULs, overlong values, malformed UTF-8, empty names, and control characters
/// are rejected rather than truncated or concatenated.
String? decodeAdvertNameBytes(List<int> raw) {
  var bytes = raw;
  if (bytes.isNotEmpty && bytes.last == 0) {
    bytes = bytes.sublist(0, bytes.length - 1);
  }
  if (bytes.isEmpty || bytes.length > maxAdvertNameBytes) return null;
  if (bytes.contains(0)) return null;
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
