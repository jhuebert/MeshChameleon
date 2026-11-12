import 'package:flutter/material.dart';

/// Monogram avatar tinted deterministically from the identity name.
///
/// Decorative only: the monogram/tint is not a security fingerprint, so the
/// avatar is excluded from semantics. The tint is derived from a stable FNV-1a
/// hash, never the process-dependent `String.hashCode`.
class IdentityAvatar extends StatelessWidget {
  const IdentityAvatar({
    super.key,
    required this.name,
    this.size = 48,
  });

  /// Background/foreground pairs; all dark enough for white text.
  static const List<(Color background, Color foreground)> palette = [
    (Color(0xFF2E5D43), Color(0xFFEAF6EE)),
    (Color(0xFF4A5D23), Color(0xFFF4F9E4)),
    (Color(0xFF1F5F5B), Color(0xFFE4F7F3)),
    (Color(0xFF6B4E12), Color(0xFFFBEFD3)),
    (Color(0xFF5B3A5E), Color(0xFFF6E9F7)),
    (Color(0xFF37455C), Color(0xFFE9EFF8)),
  ];

  final String name;
  final double size;

  /// First non-whitespace grapheme of the name, upper-cased ('?' when empty).
  static String monogramFor(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return '?';
    return trimmed.characters.first.toUpperCase();
  }

  /// Stable across runs and platforms (FNV-1a over the name's code units).
  static int stableHash(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  static (Color background, Color foreground) tintFor(String name) =>
      palette[stableHash(name.trim().toLowerCase()) % palette.length];

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = tintFor(name);
    return ExcludeSemantics(
      child: Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: background,
          shape: BoxShape.circle,
        ),
        child: Text(
          monogramFor(name),
          style: TextStyle(
            color: foreground,
            fontSize: size * 0.44,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
