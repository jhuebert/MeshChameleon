import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Bounded cache of recently heard advert routes, keyed by the 7-byte public
/// key prefix (hex).
class AdvertPathCache {
  final Map<String, AdvertPath> _paths = {};

  Map<String, AdvertPath> get paths => _paths;

  int get length => _paths.length;

  /// Return a cloned cache with [packet]'s inbound path recorded for [pubkey].
  ///
  /// [base] lets a caller build the candidate from state captured inside the
  /// persistence queue instead of the live cache.
  Map<String, AdvertPath> candidate(
    Packet packet,
    Uint8List pubkey,
    String name,
    int now, {
    Map<String, AdvertPath>? base,
  }) {
    final prefix = Uint8List.fromList(pubkey.sublist(0, advertPathPrefix7));
    final key = bytesToHex(prefix);
    final map = <String, AdvertPath>{
      for (final entry in (base ?? _paths).entries)
        entry.key: entry.value.clone(),
    };
    map[key] = AdvertPath(
      publicKeyPrefix: prefix,
      name: name,
      pathLen: packet.pathLenByte,
      path: packet.path,
      recvTimestamp: now,
    );
    while (map.length > maxAdvertPathCacheEntries) {
      String? oldestKey;
      int? oldestTimestamp;
      for (final entry in map.entries) {
        final timestamp = entry.value.recvTimestamp;
        if (oldestTimestamp == null || timestamp < oldestTimestamp) {
          oldestTimestamp = timestamp;
          oldestKey = entry.key;
        }
      }
      if (oldestKey == null) break;
      map.remove(oldestKey);
    }
    return map;
  }

  void replace(Map<String, AdvertPath> paths) {
    _paths
      ..clear()
      ..addAll(paths);
  }
}
