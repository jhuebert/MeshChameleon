import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'virtual_clock.dart';

/// A login keep-alive session with a repeater/room server.
class ConnectionSession {
  ConnectionSession(this.pubkey, this.interval);

  final Uint8List pubkey;
  Duration interval;
  Timer? timer;

  /// Monotonic seconds of the last activity; the session is dropped once this
  /// is older than 2.5x [interval].
  int lastActivity = 0;

  /// The ACK hash we expect from the next keep-alive request.
  int? expectedAck;

  void stop() {
    timer?.cancel();
    timer = null;
    expectedAck = null;
  }
}

/// Active login/keep-alive sessions, keyed by server public key hex.
class ConnectionSessions {
  ConnectionSessions({
    required this.clock,
    required this.onKeepAlive,
  });

  final VirtualClock clock;
  final Future<void> Function(ConnectionSession connection) onKeepAlive;

  final Map<String, ConnectionSession> _sessions = {};

  Iterable<ConnectionSession> get values => _sessions.values;

  int get length => _sessions.length;

  void start(Uint8List pubkey, int keepAliveSecs) {
    if (keepAliveSecs <= 0) return;
    final key = bytesToHex(pubkey);
    final connection = _sessions.putIfAbsent(
      key,
      () => ConnectionSession(
          Uint8List.fromList(pubkey), Duration(seconds: keepAliveSecs)),
    );
    connection.interval = Duration(seconds: keepAliveSecs);
    connection.lastActivity = clock.monotonicSeconds;
    connection.timer?.cancel();
    connection.timer = Timer.periodic(
      connection.interval,
      (_) => unawaited(onKeepAlive(connection)),
    );
  }

  void stop(Uint8List pubkey) {
    _sessions.remove(bytesToHex(pubkey))?.stop();
  }

  void remove(ConnectionSession connection) {
    _sessions.remove(bytesToHex(connection.pubkey));
  }

  void removeByHex(String hex) {
    _sessions.remove(hex)?.stop();
  }

  bool contains(Uint8List pubkey) => _sessions.containsKey(bytesToHex(pubkey));

  bool containsValue(ConnectionSession connection) =>
      _sessions.containsValue(connection);

  void markActive(Uint8List pubkey) {
    _sessions[bytesToHex(pubkey)]?.lastActivity = clock.monotonicSeconds;
  }

  /// Consume a keep-alive ACK. Returns true when [crc] matched a session.
  bool acceptAck(int crc) {
    for (final connection in _sessions.values) {
      if (connection.expectedAck != null &&
          connection.expectedAck == (crc & 0xFFFFFFFF)) {
        connection.expectedAck = null;
        connection.lastActivity = clock.monotonicSeconds;
        return true;
      }
    }
    return false;
  }

  Future<void> sendAllNow() async {
    for (final connection in _sessions.values.toList()) {
      await onKeepAlive(connection);
    }
  }

  void clear() {
    for (final connection in _sessions.values) {
      connection.stop();
    }
    _sessions.clear();
  }
}
