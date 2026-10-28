import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'build_info.dart';

/// Cached per-identity packet counters from [MeshNode.sessionStats].
class MeshPacketStats {
  const MeshPacketStats({
    required this.sent,
    required this.received,
    required this.floodTx,
    required this.directTx,
    required this.floodRx,
    required this.directRx,
    required this.receiveErrors,
    required this.queueLength,
    required this.txAirSeconds,
    required this.rxAirSeconds,
    required this.lastRssi,
    required this.lastSnrScaled,
    required this.noiseFloor,
  });

  final int sent;
  final int received;
  final int floodTx;
  final int directTx;
  final int floodRx;
  final int directRx;
  final int receiveErrors;
  final int queueLength;
  final int txAirSeconds;
  final int rxAirSeconds;
  final int lastRssi;
  final int lastSnrScaled;
  final int noiseFloor;

  double get lastSnr => lastSnrScaled / 4.0;

  factory MeshPacketStats.fromMap(Map<String, Object?> values) {
    int read(String key) => values[key] is int ? values[key] as int : 0;
    return MeshPacketStats(
      sent: read('sent'),
      received: read('recv'),
      floodTx: read('flood_tx'),
      directTx: read('direct_tx'),
      floodRx: read('flood_rx'),
      directRx: read('direct_rx'),
      receiveErrors: read('recv_errors'),
      queueLength: read('queue_len'),
      txAirSeconds: read('tx_air_secs'),
      rxAirSeconds: read('rx_air_secs'),
      lastRssi: read('last_rssi'),
      lastSnrScaled: read('last_snr_scaled'),
      noiseFloor: read('noise_floor'),
    );
  }
}

/// Presentation-safe view of one identity for diagnostics.
class IdentityDiagnostics {
  const IdentityDiagnostics({
    required this.id,
    required this.name,
    required this.prefixHex,
    required this.active,
    required this.live,
    required this.contactCount,
    required this.channelCount,
    required this.queuedDirect,
    required this.queuedChannel,
    this.enabled = true,
    this.unavailableReason,
    this.packets,
  });

  final String id;
  final String name;
  final String prefixHex;
  final bool active;
  final bool live;
  final bool enabled;
  final int contactCount;
  final int channelCount;
  final int queuedDirect;
  final int queuedChannel;
  final String? unavailableReason;
  final MeshPacketStats? packets;
}

/// Everything the About & diagnostics page and copied report need.
///
/// The snapshot is immutable, but [CompanionMetrics] and [LinkMetrics] are
/// intentionally live session objects; callers take a fresh snapshot whenever
/// the page refreshes.
class DiagnosticsSnapshot {
  const DiagnosticsSnapshot({
    required this.buildInfo,
    required this.generatedAt,
    required this.appUptime,
    required this.proxyRunning,
    required this.proxyPort,
    required this.deviceConnected,
    required this.deviceLabel,
    required this.deviceInfo,
    required this.deviceSessionDuration,
    required this.reconnectAttempts,
    required this.reconnectSuccesses,
    required this.foregroundServiceRunning,
    required this.batteryOptimizationsIgnored,
    required this.autoResume,
    required this.identityDatabaseError,
    required this.companion,
    required this.link,
    required this.identities,
    required this.recentLogs,
  });

  final BuildInfo buildInfo;
  final DateTime generatedAt;
  final Duration appUptime;
  final bool proxyRunning;
  final int proxyPort;
  final bool deviceConnected;
  final String? deviceLabel;
  final DeviceInfo? deviceInfo;
  final Duration? deviceSessionDuration;
  final int reconnectAttempts;
  final int reconnectSuccesses;
  final bool foregroundServiceRunning;
  final bool? batteryOptimizationsIgnored;
  final bool autoResume;
  final String? identityDatabaseError;
  final CompanionMetrics companion;
  final LinkMetrics link;
  final List<IdentityDiagnostics> identities;
  final List<String> recentLogs;

  int get liveIdentityCount =>
      identities.where((identity) => identity.live).length;

  String get proxyLabel =>
      proxyRunning ? 'Listening on :$proxyPort' : 'Stopped';

  String get deviceLabelText =>
      deviceConnected ? (deviceLabel ?? 'Connected') : 'Not connected';

  String get batteryOptimizationLabel => switch (batteryOptimizationsIgnored) {
        true => 'Exempt',
        false => 'Optimized',
        null => 'Checking…',
      };

  String toReport() {
    final out = StringBuffer();
    void line([String value = '']) => out.writeln(value);
    void section(String value) {
      line();
      line('== $value ==');
    }

    line('MeshChameleon diagnostics');
    line('Generated: ${formatUtc(generatedAt)}');
    section('Build');
    for (final entry in buildInfo.details) {
      line('${entry.key}: ${entry.value}');
    }
    if (!buildInfo.hasFullBuildMetadata) {
      line(
          'Note: built without scripts/build.sh; commit/build time unavailable.');
    }

    section('Status');
    line('App uptime: ${formatDuration(appUptime)}');
    line('Proxy: $proxyLabel');
    line('Device link: $deviceLabelText');
    if (deviceSessionDuration != null) {
      line('Device session: ${formatDuration(deviceSessionDuration!)}');
    }
    line('Identities: ${identities.length} ($liveIdentityCount live)');
    line(
        'Foreground service: ${foregroundServiceRunning ? 'Running' : 'Stopped'}');
    line('Battery optimization: $batteryOptimizationLabel');
    line('Resume on launch: ${autoResume ? 'On' : 'Off'}');
    if (identityDatabaseError != null) {
      line('Identity database: $identityDatabaseError');
    }

    section('MeshCore app -> MeshChameleon');
    line('Client connected: ${companion.clientConnected ? 'Yes' : 'No'}');
    if (companion.clientConnected) {
      line('Client address: ${companion.currentClientAddress ?? 'unknown'}');
      line(
          'Client session: ${formatDuration(companion.currentClientDuration)}');
    }
    line('App protocol version: ${companion.appTargetVer ?? 'unknown'}');
    line('Connections: ${formatCount(companion.clientConnections)}');
    line('Commands received: ${formatCount(companion.commandsReceived)}');
    line('Replies sent: ${formatCount(companion.repliesSent)}');
    line('Pushes sent: ${formatCount(companion.pushesSent)}');
    line('Payload in/out: ${formatBytes(companion.payloadBytesIn)} / '
        '${formatBytes(companion.payloadBytesOut)}');
    line('Disconnects: ${formatCount(companion.clientDisconnects)} '
        '(evictions ${formatCount(companion.evictions)}, '
        'idle ${formatCount(companion.idleTimeouts)}, '
        'errors ${formatCount(companion.clientErrors)})');
    line('Error replies: ${formatCount(companion.errorReplies)}');
    line('Unsupported commands: ${formatCount(companion.unsupportedCommands)}');
    if (companion.lastDisconnectReason != null) {
      line('Last disconnect: ${companion.lastDisconnectReason}');
    }

    section('MeshChameleon -> device');
    line('Device: $deviceLabelText');
    if (deviceInfo != null) {
      line('Firmware: code ${deviceInfo!.firmwareVerCode}, '
          '${deviceInfo!.manufacturer} ${deviceInfo!.version}');
      line('Radio capacity: ${deviceInfo!.maxContacts} contacts, '
          '${deviceInfo!.maxChannels} channels');
    }
    line('Connect attempts/successes/failures: '
        '${formatCount(link.connectAttempts)}/'
        '${formatCount(link.connectSuccesses)}/'
        '${formatCount(link.connectFailures)}');
    line('Disconnects/drops: ${formatCount(link.disconnects)}/'
        '${formatCount(link.unexpectedDrops)}; '
        'reconnects: ${formatCount(reconnectAttempts)} attempted, '
        '${formatCount(reconnectSuccesses)} succeeded');
    line('Raw TX/RX packets: ${formatCount(link.rawTxPackets)} / '
        '${formatCount(link.rawRxPackets)}');
    line('Raw TX/RX bytes: ${formatBytes(link.rawTxBytes)} / '
        '${formatBytes(link.rawRxBytes)}');
    line('Device commands: ${formatCount(link.deviceRequests)} '
        '(failures ${formatCount(link.deviceRequestFailures)}, '
        'timeouts ${formatCount(link.deviceTimeouts)})');
    if (link.lastRssi != null) {
      line('Last RX signal: ${link.lastRssi!.round()} dBm RSSI, '
          '${link.lastSnr?.toStringAsFixed(1) ?? '?'} dB SNR');
    }
    line('Connected time: ${formatDuration(link.totalConnected)} total, '
        '${formatDuration(link.currentSessionDuration)} current');
    if (link.lastError != null) {
      line('Last device error: ${link.lastError}');
    }

    section('Radio & mesh traffic');
    line('Physical radio totals are unique. Per-identity RX counts include '
        'the same received frame once per live identity.');
    for (final identity in identities) {
      final packets = identity.packets;
      if (!identity.enabled) {
        line('- ${identity.name} [${identity.prefixHex}]: disabled');
        continue;
      }
      if (packets == null) {
        line('- ${identity.name} [${identity.prefixHex}]: not live');
        continue;
      }
      line('- ${identity.name} [${identity.prefixHex}]'
          '${identity.active ? ' (active)' : ''}');
      line('  semantic TX/RX: ${formatCount(packets.sent)} / '
          '${formatCount(packets.received)}');
      line('  flood TX/RX: ${formatCount(packets.floodTx)} / '
          '${formatCount(packets.floodRx)}');
      line('  direct TX/RX: ${formatCount(packets.directTx)} / '
          '${formatCount(packets.directRx)}');
      line('  receive errors: ${formatCount(packets.receiveErrors)}; '
          'queue: ${formatCount(packets.queueLength)}');
      line(
          '  airtime TX/RX: ${formatDuration(Duration(seconds: packets.txAirSeconds))} / '
          '${formatDuration(Duration(seconds: packets.rxAirSeconds))}');
      line('  contacts/channels: ${identity.contactCount}/'
          '${identity.channelCount}; queued direct/channel: '
          '${identity.queuedDirect}/${identity.queuedChannel}');
      if (identity.unavailableReason != null) {
        line('  unavailable: ${identity.unavailableReason}');
      }
    }
    if (identities.isEmpty) line('No identities.');

    section('Recent log (last ${recentLogs.length})');
    if (recentLogs.isEmpty) {
      line('(none)');
    } else {
      for (final entry in recentLogs) {
        line(entry);
      }
    }
    return out.toString();
  }
}

String formatDuration(Duration duration) {
  final seconds = duration.inSeconds;
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  final secs = seconds % 60;
  if (days > 0) return '${days}d ${hours}h ${minutes}m';
  if (hours > 0) return '${hours}h ${minutes}m ${secs}s';
  if (minutes > 0) return '${minutes}m ${secs}s';
  return '${secs}s';
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String formatCount(int value) => value.toString().replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+$)'),
      (match) => '${match[1]},',
    );

String formatUtc(DateTime value) {
  final utc = value.toUtc();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${utc.year}-${two(utc.month)}-${two(utc.day)} '
      '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)} UTC';
}
