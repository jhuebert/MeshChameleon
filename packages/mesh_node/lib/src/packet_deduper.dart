import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'virtual_clock.dart';

/// Bounded duplicate-detection cache plus the sent-group echo table.
///
/// Mirrors `Mesh.cpp`'s `hasSeen` table and openHop's `_check_dedup`
/// (300s TTL, 1000 entries). Sent group hashes are tracked separately so a
/// locally transmitted channel packet is not queued again when it echoes back.
class PacketDeduper {
  PacketDeduper({required this.clock});

  final VirtualClock clock;

  static const int _ttlSecs = 300;
  static const int _maxEntries = 1000;

  final Map<String, int> _seen = {};
  final Map<String, int> _sentGroup = {};

  /// Returns `true` if [packetHash] was already seen within the TTL window.
  bool isDuplicate(Uint8List packetHash) {
    final key = bytesToHex(packetHash);
    final now = clock.monotonicSeconds;
    final seenAt = _seen[key];
    if (seenAt != null && now - seenAt <= _ttlSecs) {
      _seen.remove(key);
      _seen[key] = now; // refresh recency
      return true;
    }
    _seen.remove(key);
    _seen[key] = now;
    _seen.removeWhere((_, ts) => now - ts > _ttlSecs);
    while (_seen.length > _maxEntries) {
      _seen.remove(_seen.keys.first);
    }
    return false;
  }

  /// Record a locally transmitted packet so rebroadcasts of it are ignored.
  ///
  /// Stock firmware marks packets seen in `sendFlood`, `sendDirect`, and
  /// `sendZeroHop`. MeshChameleon cannot rely on a half-duplex radio to
  /// suppress its own echoes because repeaters can send the original packet
  /// back. `CMD_SEND_RAW_PACKET` deliberately bypasses this (stock forwards it
  /// through `Dispatcher::sendPacket`, which does not mark seen).
  void markSent(Uint8List packetHash) {
    final key = bytesToHex(packetHash);
    final now = clock.monotonicSeconds;
    _seen.remove(key);
    _seen[key] = now;
    _seen.removeWhere((_, ts) => now - ts > _ttlSecs);
    while (_seen.length > _maxEntries) {
      _seen.remove(_seen.keys.first);
    }
  }

  void clearHash(Uint8List packetHash) {
    _seen.remove(bytesToHex(packetHash));
  }

  void noteSentGroup(Uint8List packetHash) {
    final hash = bytesToHex(packetHash);
    _sentGroup.update(hash, (count) => count + 1, ifAbsent: () => 1);
    while (_sentGroup.length > _maxEntries) {
      _sentGroup.remove(_sentGroup.keys.first);
    }
  }

  /// Consume one echo of a locally sent group packet.
  bool consumeSentGroup(Uint8List packetHash) {
    final hash = bytesToHex(packetHash);
    final count = _sentGroup[hash];
    if (count == null) return false;
    if (count == 1) {
      _sentGroup.remove(hash);
    } else {
      _sentGroup[hash] = count - 1;
    }
    return true;
  }

  void clear() {
    _seen.clear();
    _sentGroup.clear();
  }
}
