import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/network_connection_store.dart';

SavedNetworkConnection _connection(
  String host,
  int port,
  int lastConnectedAt,
) =>
    SavedNetworkConnection(
      host: host,
      port: port,
      lastConnectedAt: lastConnectedAt,
    );

void main() {
  late Directory dir;
  late File file;
  late NetworkConnectionStore store;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('mesh_network_history_');
    file = File('${dir.path}/network_connections.json');
    store = NetworkConnectionStore(file: file);
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('missing file means an empty history', () async {
    expect(await store.load(), isEmpty);
  });

  test('save and load round trip preserves the newest-first order', () async {
    await store.save([
      _connection('older.example', 5000, 100),
      _connection('newer.example', 6000, 300),
      _connection('middle.example', 5500, 200),
    ]);

    final loaded = await store.load();
    expect(
      loaded.map((connection) => connection.displayAddress),
      [
        'newer.example:6000',
        'middle.example:5500',
        'older.example:5000',
      ],
    );
    expect(loaded.first.lastConnectedAt, 300);

    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    expect(decoded['version'], networkConnectionHistoryVersion);
    expect(decoded['connections'], hasLength(3));
  });

  test('ties sort by host then port for deterministic ordering', () async {
    final ordered = withRecordedNetworkConnection(
      const [],
      host: 'bravo',
      port: 5000,
      connectedAt: 100,
    );
    final withAlpha = withRecordedNetworkConnection(
      ordered,
      host: 'Alpha',
      port: 5001,
      connectedAt: 100,
    );
    final withPort = withRecordedNetworkConnection(
      withAlpha,
      host: 'Alpha',
      port: 5000,
      connectedAt: 100,
    );

    expect(
      withPort.map((connection) => connection.displayAddress),
      ['Alpha:5000', 'Alpha:5001', 'bravo:5000'],
    );
  });

  test('recording an existing host and port refreshes and moves it forward',
      () async {
    var connections = [
      _connection('Other', 5000, 200),
      _connection('MeshCore.local', 5000, 100),
    ];

    connections = withRecordedNetworkConnection(
      connections,
      host: '  meshcore.LOCAL ',
      port: 5000,
      connectedAt: 300,
    );

    expect(connections, hasLength(2));
    expect(connections.first.host, 'meshcore.LOCAL');
    expect(connections.first.lastConnectedAt, 300);
    expect(connections.last.host, 'Other');
  });

  test('recording rejects invalid hosts and ports unchanged', () async {
    final current = [_connection('host', 5000, 100)];

    expect(
      withRecordedNetworkConnection(
        current,
        host: '  ',
        port: 5000,
        connectedAt: 200,
      ),
      current,
    );
    expect(
      withRecordedNetworkConnection(
        current,
        host: 'host',
        port: 0,
        connectedAt: 200,
      ),
      current,
    );
    expect(
      withRecordedNetworkConnection(
        current,
        host: 'host',
        port: 70000,
        connectedAt: 200,
      ),
      current,
    );
  });

  test('recording beyond the cap drops the oldest entries', () async {
    var connections = <SavedNetworkConnection>[];
    for (var i = 1; i <= maxSavedNetworkConnections + 5; i++) {
      connections = withRecordedNetworkConnection(
        connections,
        host: 'host$i',
        port: 5000,
        connectedAt: i,
      );
    }

    expect(connections, hasLength(maxSavedNetworkConnections));
    expect(connections.first.host, 'host${maxSavedNetworkConnections + 5}');
    expect(connections.last.host, 'host6');
  });

  test('load skips invalid records and keeps valid ones', () async {
    await file.writeAsString(jsonEncode({
      'version': networkConnectionHistoryVersion,
      'connections': [
        {'host': 'valid.example', 'port': 5000, 'last_connected_at': 200},
        {'host': '', 'port': 5000, 'last_connected_at': 200},
        {'host': 'bad-port-low', 'port': 0, 'last_connected_at': 200},
        {'host': 'bad-port-high', 'port': 70000, 'last_connected_at': 200},
        {'host': 'bad-port-type', 'port': '5000', 'last_connected_at': 200},
        {'host': 'bad-time', 'port': 5000, 'last_connected_at': 0},
        {'host': 'bad-time-type', 'port': 5000, 'last_connected_at': 'now'},
        'not-a-record',
        {'host': 'another.example', 'port': 6000, 'last_connected_at': 100},
      ],
    }));

    final loaded = await store.load();
    expect(
      loaded.map((connection) => connection.displayAddress),
      ['valid.example:5000', 'another.example:6000'],
    );
  });

  test('load keeps only the newest duplicate key', () async {
    await file.writeAsString(jsonEncode({
      'version': networkConnectionHistoryVersion,
      'connections': [
        {'host': 'Duplicate.example', 'port': 5000, 'last_connected_at': 100},
        {'host': 'duplicate.EXAMPLE', 'port': 5000, 'last_connected_at': 300},
      ],
    }));

    final loaded = await store.load();
    expect(loaded, hasLength(1));
    expect(loaded.single.lastConnectedAt, 300);
  });

  test('corrupt JSON and unsupported versions yield an empty history',
      () async {
    await file.writeAsString('{broken');
    expect(await store.load(), isEmpty);

    await file.writeAsString(jsonEncode({
      'version': networkConnectionHistoryVersion + 1,
      'connections': [
        {'host': 'valid.example', 'port': 5000, 'last_connected_at': 200},
      ],
    }));
    expect(await store.load(), isEmpty);
  });

  test('remove persists and restore keeps the original timestamp', () async {
    final first = _connection('first.example', 5000, 300);
    final second = _connection('second.example', 6000, 200);
    await store.save([first, second]);

    final removed = withoutNetworkConnection([first, second], first.key);
    await store.save(removed);
    expect(
      (await store.load()).map((connection) => connection.key),
      [second.key],
    );

    final restored = withRestoredNetworkConnection(removed, first);
    await store.save(restored);
    final loaded = await store.load();
    expect(loaded.map((connection) => connection.key), [first.key, second.key]);
    expect(loaded.first.lastConnectedAt, 300);
  });

  test('restore keeps a newer record with the same key', () async {
    final stale = _connection('host', 5000, 100);
    final fresh = _connection('host', 5000, 300);

    final restored = withRestoredNetworkConnection([fresh], stale);

    expect(restored, hasLength(1));
    expect(restored.single.lastConnectedAt, 300);
  });

  test('IPv6 literals are bracketed for display', () {
    expect(formatNetworkAddress('fe80::1', 5000), '[fe80::1]:5000');
    expect(formatNetworkAddress('[fe80::1]', 5000), '[fe80::1]:5000');
    expect(formatNetworkAddress('192.168.1.55', 5000), '192.168.1.55:5000');
    expect(_connection('fe80::1', 5000, 1).displayAddress, '[fe80::1]:5000');
  });
}
