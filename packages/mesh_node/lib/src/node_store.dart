import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Schema version written into every persisted [NodeState]. Bump when the
/// layout changes so older blobs can be migrated or discarded.
const int nodeStateSchemaVersion = 1;

/// A serialisable snapshot of the node state that survives restarts:
/// preferences, contacts, channels, the offline message queue, and the
/// recent advert-path cache.
///
/// The identity is intentionally *not* part of this snapshot; it is owned and
/// stored separately (see the app's secure identity store).
class NodeState {
  NodeState({
    required this.prefs,
    List<Contact>? contacts,
    Map<int, Channel>? channels,
    List<QueuedMessage>? queue,
    Map<String, AdvertPath>? advertPaths,
  })  : contacts = contacts ?? <Contact>[],
        channels = channels ?? <int, Channel>{},
        queue = queue ?? <QueuedMessage>[],
        advertPaths = advertPaths ?? <String, AdvertPath>{};

  final NodePrefs prefs;
  final List<Contact> contacts;
  final Map<int, Channel> channels;
  final List<QueuedMessage> queue;

  /// Keyed by the hex-encoded public-key prefix.
  final Map<String, AdvertPath> advertPaths;

  factory NodeState.fromJson(Map<String, Object?> json) {
    final contacts = <Contact>[];
    for (final raw in _listOf(json['contacts'])) {
      final contact = _contactFromJson(_asMap(raw));
      if (contact != null) contacts.add(contact);
    }

    final channels = <int, Channel>{};
    for (final raw in _listOf(json['channels'])) {
      final map = _asMap(raw);
      channels[_int(map['index'])] = _channelFromJson(map);
    }

    final queue = <QueuedMessage>[];
    for (final raw in _listOf(json['queue'])) {
      queue.add(_queuedMessageFromJson(_asMap(raw)));
    }

    final advertPaths = <String, AdvertPath>{};
    for (final raw in _listOf(json['advert_paths'])) {
      final map = _asMap(raw);
      final key = map['key'] as String?;
      if (key == null || key.isEmpty) continue;
      advertPaths[key] = _advertPathFromJson(map);
    }

    return NodeState(
      prefs: _prefsFromJson(_asMap(json['prefs'])),
      contacts: contacts,
      channels: channels,
      queue: queue,
      advertPaths: advertPaths,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'version': nodeStateSchemaVersion,
        'prefs': _prefsToJson(prefs),
        'contacts': contacts.map(_contactToJson).toList(),
        'channels': channels.entries
            .map((e) => <String, Object?>{'index': e.key, ..._channelToJson(e.value)})
            .toList(),
        'queue': queue.map(_queuedMessageToJson).toList(),
        'advert_paths': advertPaths.entries
            .map((e) => <String, Object?>{'key': e.key, ..._advertPathToJson(e.value)})
            .toList(),
      };
}

/// Persistence backend for the node state. Implementations must be safe to
/// call from multiple rapid mutations; [save] captures its snapshot before
/// yielding.
abstract class NodeStore {
  /// Load the last saved state, or `null` if nothing has been persisted yet.
  Future<NodeState?> load();

  /// Persist [state], replacing any previously saved snapshot.
  Future<void> save(NodeState state);
}

/// In-memory [NodeStore]. Useful as a default and for tests.
class InMemoryNodeStore implements NodeStore {
  NodeState? _state;

  @override
  Future<NodeState?> load() async => _state;

  @override
  Future<void> save(NodeState state) async {
    _state = state;
  }
}

/// JSON-file [NodeStore]. Writes atomically (temp file + rename) and serialises
/// concurrent saves so a later mutation can never be clobbered by an earlier
/// in-flight write.
class JsonNodeStore implements NodeStore {
  JsonNodeStore({required this.file, this.pretty = false});

  final File file;
  final bool pretty;
  Future<void> _tail = Future<void>.value();

  @override
  Future<NodeState?> load() async {
    try {
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return NodeState.fromJson(decoded.cast<String, Object?>());
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  @override
  Future<void> save(NodeState state) {
    // Encode synchronously so the snapshot is fixed before the async write.
    final encoded = pretty
        ? const JsonEncoder.withIndent('  ').convert(state.toJson())
        : jsonEncode(state.toJson());
    _tail = _tail.then((_) => _write(encoded)).catchError((Object _) {});
    return _tail;
  }

  Future<void> _write(String encoded) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(file.path);
  }
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

Iterable<Object?> _listOf(Object? value) =>
    value is List ? value : const <Object?>[];

Map<String, Object?> _asMap(Object? value) =>
    value is Map ? value.cast<String, Object?>() : <String, Object?>{};

int _int(Object? value, [int fallback = 0]) =>
    value is num ? value.toInt() : fallback;

double _double(Object? value, [double fallback = 0.0]) =>
    value is num ? value.toDouble() : fallback;

String _str(Object? value, [String fallback = '']) =>
    value is String ? value : fallback;

Uint8List _bytes(Object? value) {
  if (value is String && value.isNotEmpty) return hexToBytes(value);
  return Uint8List(0);
}

Map<String, Object?> _prefsToJson(NodePrefs p) => <String, Object?>{
      'node_name': p.nodeName,
      'adv_type': p.advType,
      'tx_power_dbm': p.txPowerDbm,
      'max_tx_power': p.maxTxPower,
      'frequency_hz': p.frequencyHz,
      'bandwidth_hz': p.bandwidthHz,
      'spreading_factor': p.spreadingFactor,
      'coding_rate': p.codingRate,
      'latitude': p.latitude,
      'longitude': p.longitude,
      'advert_loc_policy': p.advertLocPolicy,
      'multi_acks': p.multiAcks,
      'telemetry_mode_base': p.telemetryModeBase,
      'telemetry_mode_location': p.telemetryModeLocation,
      'telemetry_mode_environment': p.telemetryModeEnvironment,
      'manual_add_contacts': p.manualAddContacts,
      'autoadd_config': p.autoaddConfig,
      'client_repeat': p.clientRepeat,
      'path_hash_mode': p.pathHashMode,
      'export_private_key_enabled': p.exportPrivateKeyEnabled,
    };

NodePrefs _prefsFromJson(Map<String, Object?> j) {
  final defaults = NodePrefs();
  return NodePrefs(
    nodeName: _str(j['node_name'], defaults.nodeName),
    advType: _int(j['adv_type'], defaults.advType),
    txPowerDbm: _int(j['tx_power_dbm'], defaults.txPowerDbm),
    maxTxPower: _int(j['max_tx_power'], defaults.maxTxPower),
    frequencyHz: _int(j['frequency_hz'], defaults.frequencyHz),
    bandwidthHz: _int(j['bandwidth_hz'], defaults.bandwidthHz),
    spreadingFactor: _int(j['spreading_factor'], defaults.spreadingFactor),
    codingRate: _int(j['coding_rate'], defaults.codingRate),
    latitude: _double(j['latitude']),
    longitude: _double(j['longitude']),
    advertLocPolicy: _int(j['advert_loc_policy'], defaults.advertLocPolicy),
    multiAcks: _int(j['multi_acks'], defaults.multiAcks),
    telemetryModeBase:
        _int(j['telemetry_mode_base'], defaults.telemetryModeBase),
    telemetryModeLocation:
        _int(j['telemetry_mode_location'], defaults.telemetryModeLocation),
    telemetryModeEnvironment: _int(
        j['telemetry_mode_environment'], defaults.telemetryModeEnvironment),
    manualAddContacts:
        _int(j['manual_add_contacts'], defaults.manualAddContacts),
    autoaddConfig: _int(j['autoadd_config'], defaults.autoaddConfig),
    clientRepeat: _int(j['client_repeat'], defaults.clientRepeat),
    pathHashMode: _int(j['path_hash_mode'], defaults.pathHashMode),
    exportPrivateKeyEnabled: j['export_private_key_enabled'] == true,
  );
}

Map<String, Object?> _contactToJson(Contact c) => <String, Object?>{
      'public_key': bytesToHex(c.publicKey),
      'name': c.name,
      'adv_type': c.advType,
      'flags': c.flags,
      'out_path_len': c.outPathLen,
      'out_path': bytesToHex(c.outPath),
      'last_advert_timestamp': c.lastAdvertTimestamp,
      'lastmod': c.lastmod,
      'gps_lat': c.gpsLat,
      'gps_lon': c.gpsLon,
    };

Contact? _contactFromJson(Map<String, Object?> j) {
  final publicKey = _bytes(j['public_key']);
  if (publicKey.length != pubKeySize) return null;
  return Contact(
    publicKey: publicKey,
    name: _str(j['name']),
    advType: _int(j['adv_type']),
    flags: _int(j['flags']),
    outPathLen: _int(j['out_path_len'], -1),
    outPath: _bytes(j['out_path']),
    lastAdvertTimestamp: _int(j['last_advert_timestamp']),
    lastmod: _int(j['lastmod']),
    gpsLat: _double(j['gps_lat']),
    gpsLon: _double(j['gps_lon']),
  );
}

Map<String, Object?> _channelToJson(Channel c) => <String, Object?>{
      'name': c.name,
      'secret': bytesToHex(c.secret),
    };

Channel _channelFromJson(Map<String, Object?> j) => Channel(
      name: _str(j['name']),
      secret: _bytes(j['secret']),
    );

Map<String, Object?> _queuedMessageToJson(QueuedMessage m) => <String, Object?>{
      'sender_key': bytesToHex(m.senderKey),
      'txt_type': m.txtType,
      'timestamp': m.timestamp,
      'text': m.text,
      'is_channel': m.isChannel,
      'channel_idx': m.channelIdx,
      'path_len': m.pathLen,
      'snr': m.snr,
      'rssi': m.rssi,
    };

QueuedMessage _queuedMessageFromJson(Map<String, Object?> j) => QueuedMessage(
      senderKey: _bytes(j['sender_key']),
      txtType: _int(j['txt_type']),
      timestamp: _int(j['timestamp']),
      text: _str(j['text']),
      isChannel: j['is_channel'] == true,
      channelIdx: _int(j['channel_idx']),
      pathLen: _int(j['path_len']),
      snr: _double(j['snr']),
      rssi: _int(j['rssi']),
    );

Map<String, Object?> _advertPathToJson(AdvertPath p) => <String, Object?>{
      'prefix': bytesToHex(p.publicKeyPrefix),
      'name': p.name,
      'path_len': p.pathLen,
      'path': bytesToHex(p.path),
      'recv_timestamp': p.recvTimestamp,
    };

AdvertPath _advertPathFromJson(Map<String, Object?> j) => AdvertPath(
      publicKeyPrefix: _bytes(j['prefix']),
      name: _str(j['name']),
      pathLen: _int(j['path_len']),
      path: _bytes(j['path']),
      recvTimestamp: _int(j['recv_timestamp']),
    );
