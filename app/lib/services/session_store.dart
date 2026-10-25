import 'dart:convert';
import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path_provider/path_provider.dart';

/// How the last-used companion device was reached.
///
/// [simulated] is the in-memory fake device used for development; it is only
/// restored by builds that offer it (see `DeviceCapabilities`).
enum DeviceTargetKind { tcp, ble, simulated }

/// Persisted description of the last device session.
///
/// This is deliberately small and separate from [NodeStore]: it captures *how
/// to reach the radio*, not the mesh node's contacts/channels/queue. It lets the
/// app restore the last session (device link + proxy port) on the next launch.
class SessionConfig {
  const SessionConfig({
    required this.kind,
    this.host,
    this.devicePort = defaultCompanionPort,
    this.bleRemoteId,
    this.bleName,
    this.proxyPort = defaultCompanionPort,
    this.autoResume = false,
  });

  final DeviceTargetKind kind;

  /// TCP device link host (null for [DeviceTargetKind.ble]).
  final String? host;

  /// TCP device link port.
  final int devicePort;

  /// BLE remote id / advertised name (null for [DeviceTargetKind.tcp]).
  final String? bleRemoteId;
  final String? bleName;

  /// The app-facing companion server port.
  final int proxyPort;

  /// Whether the app should reconnect and restart the proxy on launch.
  final bool autoResume;

  SessionConfig copyWith({int? proxyPort, bool? autoResume}) => SessionConfig(
        kind: kind,
        host: host,
        devicePort: devicePort,
        bleRemoteId: bleRemoteId,
        bleName: bleName,
        proxyPort: proxyPort ?? this.proxyPort,
        autoResume: autoResume ?? this.autoResume,
      );

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'host': host,
        'devicePort': devicePort,
        'bleRemoteId': bleRemoteId,
        'bleName': bleName,
        'proxyPort': proxyPort,
        'autoResume': autoResume,
      };

  static SessionConfig? fromJson(Map<String, dynamic> json) {
    DeviceTargetKind? kind;
    for (final candidate in DeviceTargetKind.values) {
      if (candidate.name == json['kind']) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) return null;
    return SessionConfig(
      kind: kind,
      host: json['host'] as String?,
      devicePort:
          (json['devicePort'] as num?)?.toInt() ?? defaultCompanionPort,
      bleRemoteId: json['bleRemoteId'] as String?,
      bleName: json['bleName'] as String?,
      proxyPort: (json['proxyPort'] as num?)?.toInt() ?? defaultCompanionPort,
      autoResume: json['autoResume'] as bool? ?? false,
    );
  }
}

/// Persists [SessionConfig] to a small JSON file in the app support directory.
class SessionStore {
  SessionStore({File? file}) : _file = file;

  File? _file;

  Future<File> _resolve() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/session.json');
  }

  Future<SessionConfig?> load() async {
    try {
      final file = await _resolve();
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return null;
      return SessionConfig.fromJson(decoded);
    } catch (_) {
      // A corrupt or unreadable file should never block startup.
      return null;
    }
  }

  Future<void> save(SessionConfig config) async {
    final file = await _resolve();
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(config.toJson()));
  }
}
