import 'dart:io';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path_provider/path_provider.dart';

import 'json_document_store.dart';

/// How the last-used companion device was reached.
///
/// [simulated] is the in-memory fake device used for testing without a radio.
enum DeviceTargetKind { tcp, ble, simulated }

/// Current on-disk saved-session schema.
///
/// Versionless files come from pre-0.1.0 development builds and are read as
/// version 1.
const int sessionConfigVersion = 1;

/// Persisted description of the last device session.
///
/// This is deliberately small and separate from the node state store: it
/// captures *how to reach the radio*, not the mesh node's
/// contacts/channels/queue. It lets the app restore the last session (device
/// link + proxy port) on the next launch.
class SessionConfig {
  const SessionConfig({
    required this.kind,
    this.host,
    this.devicePort = defaultCompanionPort,
    this.bleRemoteId,
    this.bleName,
    this.proxyPort = defaultCompanionPort,
    this.autoResume = false,
    this.intentionallyOff = false,
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

  /// A successful physical shutdown suppresses automatic reconnect/auto-resume
  /// until the user explicitly connects again.
  final bool intentionallyOff;

  SessionConfig copyWith({
    int? proxyPort,
    bool? autoResume,
    bool? intentionallyOff,
  }) =>
      SessionConfig(
        kind: kind,
        host: host,
        devicePort: devicePort,
        bleRemoteId: bleRemoteId,
        bleName: bleName,
        proxyPort: proxyPort ?? this.proxyPort,
        autoResume: autoResume ?? this.autoResume,
        intentionallyOff: intentionallyOff ?? this.intentionallyOff,
      );

  Map<String, dynamic> toJson() => {
        'version': sessionConfigVersion,
        'kind': kind.name,
        'host': host,
        'devicePort': devicePort,
        'bleRemoteId': bleRemoteId,
        'bleName': bleName,
        'proxyPort': proxyPort,
        'autoResume': autoResume,
        'intentionallyOff': intentionallyOff,
      };

  static SessionConfig? fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version != null &&
        (version is! num ||
            version != version.toInt() ||
            version.toInt() != sessionConfigVersion)) {
      return null;
    }
    DeviceTargetKind? kind;
    for (final candidate in DeviceTargetKind.values) {
      if (candidate.name == json['kind']) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) return null;
    final rawDevicePort = json['devicePort'];
    final rawProxyPort = json['proxyPort'];
    final host = json['host'];
    final bleRemoteId = json['bleRemoteId'];
    final bleName = json['bleName'];
    final autoResume = json['autoResume'];
    final intentionallyOff = json['intentionallyOff'];
    if ((rawDevicePort != null &&
            (rawDevicePort is! num ||
                rawDevicePort != rawDevicePort.toInt())) ||
        (rawProxyPort != null &&
            (rawProxyPort is! num || rawProxyPort != rawProxyPort.toInt())) ||
        (host != null && host is! String) ||
        (bleRemoteId != null && bleRemoteId is! String) ||
        (bleName != null && bleName is! String) ||
        (autoResume != null && autoResume is! bool) ||
        (intentionallyOff != null && intentionallyOff is! bool)) {
      return null;
    }
    final devicePort = (rawDevicePort as num?)?.toInt() ?? defaultCompanionPort;
    // The proxy port may be zero: that asks the OS for a free port.
    final proxyPort = (rawProxyPort as num?)?.toInt() ?? defaultCompanionPort;
    if (devicePort < 1 ||
        devicePort > 65535 ||
        proxyPort < 0 ||
        proxyPort > 65535) {
      return null;
    }
    return SessionConfig(
      kind: kind,
      host: host as String?,
      devicePort: devicePort,
      bleRemoteId: bleRemoteId as String?,
      bleName: bleName as String?,
      proxyPort: proxyPort,
      autoResume: autoResume as bool? ?? false,
      intentionallyOff: intentionallyOff as bool? ?? false,
    );
  }
}

/// Persists [SessionConfig] to a small JSON file in the app support directory.
class SessionStore {
  SessionStore({File? file}) : _file = file;

  File? _file;

  late final JsonDocumentStore<SessionConfig> _store = JsonDocumentStore(
    resolveFile: _resolveFile,
    decode: (json) =>
        json is Map<String, dynamic> ? SessionConfig.fromJson(json) : null,
    encode: (config) => config.toJson(),
    version: sessionConfigVersion,
  );

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/session.json');
  }

  Future<SessionConfig?> load() => _store.load();

  Future<void> save(SessionConfig config) => _store.save(config);

  /// Remove the saved session, used when restoring a backup without one.
  Future<void> delete() => _store.delete();
}
