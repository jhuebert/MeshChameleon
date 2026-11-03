import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'json_document_store.dart';
import 'network_address.dart';

export 'network_address.dart';

/// Current on-disk saved-network-connection schema.
const int networkConnectionHistoryVersion = 1;

/// Maximum number of saved network targets kept after a successful connection.
const int maxSavedNetworkConnections = 20;

/// Largest timestamp representable by [DateTime] (UTC epoch milliseconds).
const int _maxTimestampMilliseconds = 8640000000000000;

bool _isValidTimestamp(int timestamp) =>
    timestamp > 0 && timestamp <= _maxTimestampMilliseconds;

/// A successfully reached TCP companion target.
///
/// Host casing is preserved for display; [key] normalizes it for duplicate
/// detection. [lastConnectedAt] is UTC epoch milliseconds.
class SavedNetworkConnection {
  const SavedNetworkConnection({
    required this.host,
    required this.port,
    required this.lastConnectedAt,
  });

  final String host;
  final int port;
  final int lastConnectedAt;

  String get key => '${host.trim().toLowerCase()}:$port';

  /// `host:port`, bracketing IPv6 literals for display.
  String get displayAddress => formatNetworkAddress(host, port);

  Map<String, Object?> toJson() => <String, Object?>{
        'host': host,
        'port': port,
        'last_connected_at': lastConnectedAt,
      };

  static SavedNetworkConnection? fromJson(Object? value) {
    if (value is! Map) return null;
    final host = value['host'];
    final port = value['port'];
    final lastConnectedAt = value['last_connected_at'];
    if (host is! String || port is! num || lastConnectedAt is! num) {
      return null;
    }
    final trimmedHost = host.trim();
    final portValue = port.toInt();
    final connectedAt = lastConnectedAt.toInt();
    if (!isValidTcpHost(trimmedHost) ||
        !isValidTcpPort(portValue) ||
        portValue != port ||
        !_isValidTimestamp(connectedAt) ||
        connectedAt != lastConnectedAt) {
      return null;
    }
    return SavedNetworkConnection(
      host: trimmedHost,
      port: portValue,
      lastConnectedAt: connectedAt,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SavedNetworkConnection &&
      other.key == key &&
      other.lastConnectedAt == lastConnectedAt;

  @override
  int get hashCode => Object.hash(key, lastConnectedAt);
}

/// Adds or refreshes [host]:[port] and returns the normalized history.
///
/// Invalid input leaves [current] unchanged. Existing entries with the same
/// case-insensitive key are replaced, then the result is sorted newest-first
/// and capped at [maxSavedNetworkConnections].
List<SavedNetworkConnection> withRecordedNetworkConnection(
  List<SavedNetworkConnection> current, {
  required String host,
  required int port,
  required int connectedAt,
}) {
  final trimmedHost = host.trim();
  if (!isValidTcpHost(trimmedHost) ||
      !isValidTcpPort(port) ||
      !_isValidTimestamp(connectedAt)) {
    return List<SavedNetworkConnection>.unmodifiable(current);
  }
  return _replaceAndOrder(
    current,
    SavedNetworkConnection(
      host: trimmedHost,
      port: port,
      lastConnectedAt: connectedAt,
    ),
  );
}

/// Removes the entry identified by [key] and returns the ordered history.
List<SavedNetworkConnection> withoutNetworkConnection(
  List<SavedNetworkConnection> current,
  String key,
) =>
    _order(current.where((connection) => connection.key != key));

/// Restores a previously removed entry, preserving its original timestamp.
///
/// If a newer record with the same key exists (the user reconnected before
/// Undo), the newer record is kept.
List<SavedNetworkConnection> withRestoredNetworkConnection(
  List<SavedNetworkConnection> current,
  SavedNetworkConnection connection,
) {
  if (!isValidTcpHost(connection.host) ||
      !isValidTcpPort(connection.port) ||
      !_isValidTimestamp(connection.lastConnectedAt)) {
    return _order(current);
  }
  for (final existing in current) {
    if (existing.key == connection.key &&
        existing.lastConnectedAt >= connection.lastConnectedAt) {
      return _order(current);
    }
  }
  return _replaceAndOrder(current, connection);
}

List<SavedNetworkConnection> _replaceAndOrder(
  List<SavedNetworkConnection> current,
  SavedNetworkConnection connection,
) =>
    _order([
      ...current.where((existing) => existing.key != connection.key),
      connection,
    ]);

List<SavedNetworkConnection> _order(
  Iterable<SavedNetworkConnection> connections,
) {
  // Keep the newest record for duplicate keys so every entry point shares the
  // same file invariant.
  final byKey = <String, SavedNetworkConnection>{};
  for (final connection in connections) {
    final existing = byKey[connection.key];
    if (existing == null ||
        connection.lastConnectedAt > existing.lastConnectedAt) {
      byKey[connection.key] = connection;
    }
  }
  final ordered = byKey.values.toList()..sort(_compare);
  if (ordered.length > maxSavedNetworkConnections) {
    ordered.removeRange(maxSavedNetworkConnections, ordered.length);
  }
  return List<SavedNetworkConnection>.unmodifiable(ordered);
}

int _compare(SavedNetworkConnection a, SavedNetworkConnection b) {
  final byTimestamp = b.lastConnectedAt.compareTo(a.lastConnectedAt);
  if (byTimestamp != 0) return byTimestamp;
  final byHost = a.host.toLowerCase().compareTo(b.host.toLowerCase());
  if (byHost != 0) return byHost;
  return a.port.compareTo(b.port);
}

/// Encode the persisted `{version, connections}` history shape.
Map<String, Object?> encodeNetworkConnections(
  List<SavedNetworkConnection> connections,
) =>
    <String, Object?>{
      'version': networkConnectionHistoryVersion,
      'connections': [
        for (final connection in connections) connection.toJson(),
      ],
    };

/// Decode a persisted history payload.
///
/// With [strict], any invalid record rejects the whole payload; otherwise
/// invalid records are skipped and the valid ones are returned.
List<SavedNetworkConnection> decodeNetworkConnections(
  Object? value, {
  bool strict = false,
}) {
  if (value is! Map) {
    throw const FormatException('invalid saved connection history');
  }
  final version = value['version'];
  final rawConnections = value['connections'];
  if (version is! num ||
      version != version.toInt() ||
      version.toInt() != networkConnectionHistoryVersion ||
      rawConnections is! List) {
    throw const FormatException('invalid saved connection history');
  }
  final parsed = <SavedNetworkConnection>[];
  for (final raw in rawConnections) {
    final connection = SavedNetworkConnection.fromJson(raw);
    if (connection == null) {
      if (strict) {
        throw const FormatException('invalid saved connection');
      }
      continue;
    }
    parsed.add(connection);
  }
  return _order(parsed);
}

/// Persists successfully reached TCP companion targets.
///
/// A missing file yields an empty history. Corrupt, unreadable, or newer-version
/// files throw [JsonDocumentException]; corrupt and newer-version files are
/// quarantined first so a later save cannot silently replace them. Callers that
/// want best-effort behavior (for example [NetworkConnectionHistory]) log the
/// error and continue. Writes are atomic and serialized; their failures
/// propagate so callers can decide whether to surface them.
class NetworkConnectionStore {
  NetworkConnectionStore({File? file}) : _file = file;

  File? _file;

  late final JsonDocumentStore<List<SavedNetworkConnection>> _store =
      JsonDocumentStore(
    resolveFile: _resolveFile,
    decode: (json) => json is Map ? decodeNetworkConnections(json) : null,
    encode: encodeNetworkConnections,
    version: networkConnectionHistoryVersion,
  );

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/network_connections.json');
  }

  Future<List<SavedNetworkConnection>> load() async =>
      (await _store.load()) ?? const [];

  Future<void> save(List<SavedNetworkConnection> connections) async {
    await _store.save(_order(connections));
  }

  /// Remove the saved connection history, used when restoring a backup
  /// without one.
  Future<void> delete() => _store.delete();
}
