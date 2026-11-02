import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Flood-scope selection for outbound packets.
///
/// An explicit override takes precedence over the stored default scope. A
/// zero/absent key means the scope is unset, and [setUnscoped] forces
/// unscoped flooding until the next [setKey].
class FloodScope {
  Uint8List? _override;
  bool _unscoped = false;

  Uint8List? effective(NodePrefs prefs) {
    if (_unscoped) return null;
    final override = _override;
    if (override != null && !_isZeroKey(override)) return override;
    final def = prefs.defaultScopeKey;
    if (def != null && def.length == 16 && !_isZeroKey(def)) return def;
    return null;
  }

  void setKey(Uint8List? key) {
    _override = key == null ? null : Uint8List.fromList(key);
    _unscoped = false;
  }

  void setUnscoped() => _unscoped = true;

  void clear() {
    _override = null;
    _unscoped = false;
  }

  static bool _isZeroKey(Uint8List key) {
    for (final b in key) {
      if (b != 0) return false;
    }
    return true;
  }
}
