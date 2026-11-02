import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'json_file.dart';

/// Current on-disk saved-network-connection schema.
const int networkConnectionHistoryVersion = 1;

/// Maximum number of saved network targets kept after a successful connection.
const int maxSavedNetworkConnections = 20;

/// Largest timestamp representable by [DateTime] (UTC epoch milliseconds).
const int _maxTimestampMilliseconds = 8640000000000000;

/// Whether [host] is a non-empty TCP/IP host name or address.
bool isValidTcpHost(String host) => host.trim().isNotEmpty;

/// Whether [port] is a usable non-zero TCP port.
bool isValidTcpPort(int port) => port >= 1 && port <= 65535;

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

/// Formats a TCP target, bracketing IPv6 literals (for example
/// `[fe80::1]:5000`).
String formatNetworkAddress(String host, int port) {
  final trimmed = host.trim();
  if (trimmed.contains(':') && !trimmed.startsWith('[')) {
    return '[$trimmed]:$port';
  }
  return '$trimmed:$port';
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
/// Reads are best-effort and never throw: a missing, corrupt, or unreadable
/// file yields an empty history. Writes are atomic and serialized; their
/// failures propagate so callers can decide whether to surface them.
class NetworkConnectionStore {
  NetworkConnectionStore({File? file}) : _file = file;

  File? _file;
  JsonFile? _json;

  Future<File> _resolveFile() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/network_connections.json');
  }

  Future<JsonFile> _resolveJson() async =>
      _json ??= JsonFile(await _resolveFile());

  Future<List<SavedNetworkConnection>> load() async {
    try {
      final file = await _resolveFile();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      return decodeNetworkConnections(decoded);
    } catch (_) {
      // A corrupt or unreadable file must never block startup.
      return const [];
    }
  }

  Future<void> save(List<SavedNetworkConnection> connections) async {
    final snapshot = _order(connections);
    await (await _resolveJson()).write(encodeNetworkConnections(snapshot));
  }

  /// Remove the saved connection history, used when restoring a backup
  /// without one.
  Future<void> delete() async {
    await (await _resolveJson()).delete();
  }
}
