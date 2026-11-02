import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'virtual_clock.dart';

/// Tracks outbound request tags and the requests awaiting a response.
///
/// Tags are virtual wall-clock seconds and never collide with an in-flight
/// discovery, telemetry, or binary request. Login/status keep the firmware's
/// legacy 4-byte sender-prefix matching scheme.
class RequestTracker {
  RequestTracker({required this.clock});

  final VirtualClock clock;

  final Map<int, Uint8List> _pendingDiscovery = {};
  final Map<int, Uint8List> _pendingTelemetry = {};
  final Map<int, Uint8List> _pendingBinary = {};
  Uint8List? _pendingLogin;
  Uint8List? _pendingStatus;

  int _lastRequestTag = 0;
  int _lastPacketTimestamp = 0;

  /// Virtual wall-clock seconds that advance when two packets share a second.
  int nextTimestamp() {
    var ts = clock.wallSeconds;
    if (ts <= _lastPacketTimestamp) ts = _lastPacketTimestamp + 1;
    _lastPacketTimestamp = ts;
    return ts;
  }

  /// Record a caller-supplied timestamp so later generated timestamps advance.
  void noteTimestamp(int timestamp) {
    if (timestamp > _lastPacketTimestamp) {
      _lastPacketTimestamp = timestamp;
    }
  }

  /// Timestamp for a CLI reply that must be newer than the request and the last
  /// packet we generated.
  int replyTimestamp(int requestTimestamp) {
    var timestamp = clock.wallSeconds;
    if (timestamp <= requestTimestamp) timestamp = requestTimestamp + 1;
    if (timestamp <= _lastPacketTimestamp) timestamp = _lastPacketTimestamp + 1;
    _lastPacketTimestamp = timestamp;
    return timestamp;
  }

  /// Virtual request tag that doesn't collide with an in-flight request.
  int nextTag() {
    var tag = clock.wallSeconds;
    if (tag <= _lastRequestTag) tag = _lastRequestTag + 1;
    while (_pendingBinary.containsKey(tag) ||
        _pendingTelemetry.containsKey(tag) ||
        _pendingDiscovery.containsKey(tag)) {
      tag++;
    }
    _lastRequestTag = tag;
    return tag;
  }

  void registerDiscovery(int tag, Uint8List target) =>
      _pendingDiscovery[tag] = Uint8List.fromList(target);

  void removeDiscovery(int tag) => _pendingDiscovery.remove(tag);

  Uint8List? discoveryTarget(int tag) => _pendingDiscovery[tag];

  void registerTelemetry(int tag, Uint8List target) =>
      _pendingTelemetry[tag] = Uint8List.fromList(target);

  void removeTelemetry(int tag) => _pendingTelemetry.remove(tag);

  Uint8List? telemetryTarget(int tag) => _pendingTelemetry[tag];

  void registerBinary(int tag, Uint8List target) =>
      _pendingBinary[tag] = Uint8List.fromList(target);

  void removeBinary(int tag) => _pendingBinary.remove(tag);

  Uint8List? binaryTarget(int tag) => _pendingBinary[tag];

  void setPendingLogin(Uint8List prefix4) =>
      _pendingLogin = Uint8List.fromList(prefix4);

  void clearPendingLogin() => _pendingLogin = null;

  /// Remove and return true when [prefix4] matches the pending login.
  bool takeLogin(Uint8List prefix4) {
    final pending = _pendingLogin;
    if (pending == null || !bytesEqual(pending, prefix4)) return false;
    _pendingLogin = null;
    return true;
  }

  void setPendingStatus(Uint8List prefix4) =>
      _pendingStatus = Uint8List.fromList(prefix4);

  void clearPendingStatus() => _pendingStatus = null;

  /// Remove and return true when [prefix4] matches the pending status request.
  bool takeStatus(Uint8List prefix4) {
    final pending = _pendingStatus;
    if (pending == null || !bytesEqual(pending, prefix4)) return false;
    _pendingStatus = null;
    return true;
  }

  bool get hasPendingLogin => _pendingLogin != null;
  bool get hasPendingStatus => _pendingStatus != null;
  Uint8List? get pendingLogin => _pendingLogin;
  Uint8List? get pendingStatus => _pendingStatus;

  /// Drop every pending request associated with [pubkey].
  void removeForContact(Uint8List pubkey) {
    final prefix = _prefix4(pubkey);
    if (_pendingLogin != null && bytesEqual(_pendingLogin!, prefix)) {
      _pendingLogin = null;
    }
    if (_pendingStatus != null && bytesEqual(_pendingStatus!, prefix)) {
      _pendingStatus = null;
    }
    _pendingTelemetry.removeWhere((_, value) => bytesEqual(value, pubkey));
    _pendingDiscovery.removeWhere((_, value) => bytesEqual(value, pubkey));
    _pendingBinary.removeWhere((_, value) => bytesEqual(value, pubkey));
  }

  void clear() {
    _pendingDiscovery.clear();
    _pendingTelemetry.clear();
    _pendingBinary.clear();
    _pendingLogin = null;
    _pendingStatus = null;
    _lastRequestTag = 0;
  }

  static Uint8List _prefix4(Uint8List pubkey) => Uint8List.fromList(pubkey
      .sublist(0, pubkey.length < keyPrefix4 ? pubkey.length : keyPrefix4));
}
