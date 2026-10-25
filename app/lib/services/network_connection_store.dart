import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Current on-disk saved-network-connection schema.
const int networkConnectionHistoryVersion = 1;

/// Maximum number of saved network targets kept after a successful connection.
const int maxSavedNetworkConnections = 20;

/// Largest timestamp representable by [DateTime] (UTC epoch milliseconds).
const int _maxTimestampMilliseconds = 8640000000000000;

bool _isValidHost(String host) => host.trim().isNotEmpty;

bool _isValidPort(int port) => port >= 1 && port <= 65535;

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
    if (!_isValidHost(trimmedHost) ||
        !_isValidPort(portValue) ||
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
  if (!_isValidHost(trimmedHost) ||
      !_isValidPort(port) ||
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
  if (!_isValidHost(connection.host) ||
      !_isValidPort(connection.port) ||
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

/// Persists successfully reached TCP companion targets.
///
/// Reads are best-effort and never throw: a missing, corrupt, or unreadable
/// file yields an empty history. Writes are atomic and serialized; their
/// failures propagate so callers can decide whether to surface them.
class NetworkConnectionStore {
  NetworkConnectionStore({File? file}) : _file = file;

  File? _file;
  Future<void> _tail = Future<void>.value();

  Future<File> _resolve() async {
    final existing = _file;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    return _file = File('${dir.path}/network_connections.json');
  }

  Future<List<SavedNetworkConnection>> load() async {
    try {
      final file = await _resolve();
      if (!await file.exists()) return const [];
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return const [];
      final version = decoded['version'];
      if (version is! num ||
          version.toInt() != networkConnectionHistoryVersion) {
        return const [];
      }
      final rawConnections = decoded['connections'];
      if (rawConnections is! List) return const [];

      return _order(
        rawConnections
            .map(SavedNetworkConnection.fromJson)
            .whereType<SavedNetworkConnection>(),
      );
    } catch (_) {
      // A corrupt or unreadable file must never block startup.
      return const [];
    }
  }

  Future<void> save(List<SavedNetworkConnection> connections) {
    final snapshot = _order(connections);
    // Serialize writes so overlapping saves cannot share the temp file.
    final write = _tail.then(
      (_) => _write(snapshot),
      onError: (Object _) => _write(snapshot),
    );
    _tail = write.then((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> _write(List<SavedNetworkConnection> connections) async {
    final file = await _resolve();
    await file.parent.create(recursive: true);
    final encoded = jsonEncode(<String, Object?>{
      'version': networkConnectionHistoryVersion,
      'connections': connections
          .map((connection) => connection.toJson())
          .toList(growable: false),
    });
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(encoded, flush: true);
    await temp.rename(file.path);
  }
}
