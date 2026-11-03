import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/network_connection_history.dart';
import 'package:meshchameleon/services/network_connection_store.dart';

class _FailingStore extends NetworkConnectionStore {
  _FailingStore() : super(file: File('/tmp/unused-network-history.json'));

  @override
  Future<void> save(List<SavedNetworkConnection> connections) async {
    throw const FileSystemException('disk full');
  }
}

void main() {
  late Directory dir;
  late NetworkConnectionStore store;
  late List<String> logs;
  late int changes;
  late NetworkConnectionHistory history;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('network_history_');
    store = NetworkConnectionStore(file: File('${dir.path}/connections.json'));
    logs = [];
    changes = 0;
    history = NetworkConnectionHistory(
      store: store,
      onLog: logs.add,
      onChanged: () => changes++,
    );
  });

  tearDown(() => dir.delete(recursive: true));

  test('loads the persisted history', () async {
    await store.save([
      const SavedNetworkConnection(
        host: '192.168.1.2',
        port: 5000,
        lastConnectedAt: 100,
      ),
    ]);

    await history.load();
    expect(history.connections.single.host, '192.168.1.2');
  });

  test('a corrupt history is logged and treated as empty', () async {
    await File('${dir.path}/connections.json').writeAsString('{bad');

    await history.load();

    expect(history.connections, isEmpty);
    expect(logs.single, contains('Could not load network connection history'));
  });

  test('records, removes, and restores targets', () async {
    await history.record('192.168.1.2', 5000);
    final saved = history.connections.single;
    expect(saved.displayAddress, '192.168.1.2:5000');
    expect(await store.load(), hasLength(1));

    expect(await history.remove(saved), isTrue);
    expect(history.connections, isEmpty);

    expect(await history.restore(saved), isTrue);
    expect(history.connections.single.lastConnectedAt, saved.lastConnectedAt);
    expect(changes, greaterThanOrEqualTo(3));
  });

  test('a failed remove keeps the in-memory history', () async {
    final failing = NetworkConnectionHistory(
      store: _FailingStore(),
      onLog: logs.add,
      onChanged: () => changes++,
    );
    const connection = SavedNetworkConnection(
      host: '192.168.1.2',
      port: 5000,
      lastConnectedAt: 100,
    );
    await failing.record('192.168.1.2', 5000);

    expect(await failing.remove(connection), isFalse);
    expect(failing.connections, isNotEmpty);
    expect(logs.join('\n'), contains('Could not remove'));
  });
}
