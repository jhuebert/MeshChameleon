import 'dart:async';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'local_peer_router.dart';
import 'virtual_clock.dart';

/// Raw-radio transmission, airtime accounting, and packet counters.
///
/// The transport owns no semantic node state: it transmits an already-built
/// [Packet], mirrors successful sends to local peers, and tracks the counters
/// reported through the companion stats commands.
class PacketTransport {
  PacketTransport({
    required this.link,
    required this.prefs,
    required this.clock,
    required this.localRouter,
    required this.isBlocked,
    required this.isRetired,
    required this.isCurrent,
    required this.effectiveFloodScope,
    required this.publicKey,
  });

  final RadioLink link;
  final NodePrefs prefs;
  final VirtualClock clock;
  final LocalPeerRouter? localRouter;

  /// True while semantic TX is suppressed (retired, powered off, resetting, or
  /// an identity swap is in progress).
  final bool Function() isBlocked;

  /// True once this runtime has been permanently retired.
  final bool Function() isRetired;

  /// True when [generation] still owns the active identity.
  final bool Function(int generation) isCurrent;

  final Uint8List? Function() effectiveFloodScope;
  final Uint8List Function() publicKey;

  int _activePhysicalTx = 0;
  Completer<void>? _physicalTxIdle;
  int _txAirMicros = 0;
  int _rxAirMicros = 0;
  int _lastRxRssi = 0;
  int _lastRxSnrScaled = 0;

  final Map<String, int> _packetStats = {
    'recv': 0,
    'sent': 0,
    'flood_tx': 0,
    'direct_tx': 0,
    'flood_rx': 0,
    'direct_rx': 0,
    'recv_errors': 0,
  };

  int get lastRxRssi => _lastRxRssi;
  int get lastRxSnrScaled => _lastRxSnrScaled;
  int get txAirSeconds => _txAirMicros ~/ 1000000;
  int get rxAirSeconds => _rxAirMicros ~/ 1000000;

  Future<void> transmit(
    Packet packet, {
    required bool flood,
    bool scoped = false,
    bool preservePath = false,
    int priority = 0,
    int? identityGeneration,
  }) async {
    // Suppress new semantic transmissions while an identity switch is paused
    // or identity storage is uncertain. Already-started sends are awaited by
    // the replacement path before the key changes.
    if (isBlocked()) return;
    if (identityGeneration != null && !isCurrent(identityGeneration)) {
      return;
    }
    if (flood && !preservePath) {
      packet.path = Uint8List(0);
      packet.pathLenByte = PathUtils.encodePathLen(
        prefs.pathHashMode.clamp(0, 2) + 1,
        0,
      );
    }
    if (scoped && flood) {
      final scope = effectiveFloodScope();
      if (scope != null) packet.applyFloodScope(scope);
    }
    _packetStats['sent'] = (_packetStats['sent'] ?? 0) + 1;
    _packetStats[flood ? 'flood_tx' : 'direct_tx'] =
        (_packetStats[flood ? 'flood_tx' : 'direct_tx'] ?? 0) + 1;
    final bytes = packet.writeTo();
    _txAirMicros += airtimeMicrosFor(bytes.length);
    _activePhysicalTx++;
    try {
      await link.sendRawPacket(bytes, priority);
    } finally {
      _activePhysicalTx--;
      if (_activePhysicalTx == 0) {
        final idle = _physicalTxIdle;
        _physicalTxIdle = null;
        if (idle != null && !idle.isCompleted) idle.complete();
      }
    }
    // A successful RF dispatch still mirrors, but never under a newer identity
    // generation than the one that built the packet.
    if (identityGeneration == null || isCurrent(identityGeneration)) {
      await _mirrorOutbound(bytes);
    }
  }

  Future<void> _mirrorOutbound(Uint8List bytes) async {
    final router = localRouter;
    if (router == null || isRetired()) return;
    try {
      await router.mirrorOutbound(
        bytes,
        fromPublicKey: publicKey(),
      );
    } catch (_) {
      // A mirror failure must never turn a successful RF send into a failure.
      // The router isolates and reports per-peer failures.
    }
  }

  Future<void> waitForIdle() {
    if (_activePhysicalTx == 0) return Future<void>.value();
    return (_physicalTxIdle ??= Completer<void>()).future;
  }

  /// Estimated airtime of an [bytes]-byte frame under the current radio
  /// settings, or 0 when the parameters are not usable.
  int airtimeMicrosFor(int bytes) {
    final cr = prefs.codingRate <= 4 ? prefs.codingRate + 4 : prefs.codingRate;
    if (prefs.spreadingFactor < 5 ||
        prefs.spreadingFactor > 12 ||
        prefs.bandwidthHz <= 0 ||
        cr < 5 ||
        cr > 8) {
      return 0;
    }
    return loraTimeOnAirMicros(
      payloadBytes: bytes,
      spreadingFactor: prefs.spreadingFactor,
      bandwidthHz: prefs.bandwidthHz,
      codingRate: cr,
    );
  }

  /// Firmware-compatible send timeout estimate.
  ///
  /// Mirrors MeshCore's `calcFloodTimeoutMillisFor` and
  /// `calcDirectTimeoutMillisFor`. Flooded sends need a multiple of the packet
  /// airtime because repeaters add their own transmission and contention delay;
  /// a short fixed timeout makes the client retry before the ACK can arrive.
  int? sendTimeoutMillisFor(
    Packet packet, {
    required bool flood,
    bool scoped = false,
  }) {
    final scopedFlood = flood && scoped && effectiveFloodScope() != null;
    final rawLength = flood
        ? packet.payload.length + 2 + (scopedFlood ? 4 : 0)
        : packet.rawLength;
    final airtimeMs = airtimeMicrosFor(rawLength) ~/ 1000;
    if (airtimeMs <= 0) return null;
    if (flood) return 500 + 16 * airtimeMs;
    return 500 + ((airtimeMs * 6 + 250) * (packet.pathHashCount + 1));
  }

  void addRxAirtime(int bytes) {
    _rxAirMicros += airtimeMicrosFor(bytes);
  }

  void recordMalformedFrame() {
    _packetStats['recv_errors'] = (_packetStats['recv_errors'] ?? 0) + 1;
  }

  void recordRxError() {
    _packetStats['recv_errors'] = (_packetStats['recv_errors'] ?? 0) + 1;
  }

  void recordFrame(Packet packet) {
    _packetStats['recv'] = (_packetStats['recv'] ?? 0) + 1;
    _packetStats[packet.isRouteFlood ? 'flood_rx' : 'direct_rx'] =
        (_packetStats[packet.isRouteFlood ? 'flood_rx' : 'direct_rx'] ?? 0) + 1;
    _lastRxRssi = packet.rssi;
    _lastRxSnrScaled = (packet.snr * 4).round();
  }

  Map<String, Object?> get stats => Map<String, Object?>.from(_packetStats);

  Map<String, Object?> get sessionStats => Map.unmodifiable({
        ..._packetStats,
        'tx_air_secs': txAirSeconds,
        'rx_air_secs': rxAirSeconds,
        'last_rssi': _lastRxRssi,
        'last_snr_scaled': _lastRxSnrScaled,
      });

  void resetCounters() {
    for (final key in _packetStats.keys.toList()) {
      _packetStats[key] = 0;
    }
    _lastRxRssi = 0;
    _lastRxSnrScaled = 0;
    _txAirMicros = 0;
    _rxAirMicros = 0;
  }
}
