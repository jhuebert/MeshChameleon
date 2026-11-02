import 'dart:collection';

import 'network_connection_store.dart';

/// Owns the saved TCP target history and its read-modify-write queue.
///
/// The store already serialises file writes; this queue also prevents a delete,
/// Undo, or successful connect from publishing a stale in-memory snapshot.
class NetworkConnectionHistory {
  NetworkConnectionHistory({
    required this.store,
    required this.onLog,
    required this.onChanged,
  });

  final NetworkConnectionStore store;
  final void Function(String message) onLog;
  final void Function() onChanged;

  List<SavedNetworkConnection> _connections = const [];
  Future<void>? _tail;

  List<SavedNetworkConnection> get connections =>
      UnmodifiableListView(_connections);

  Future<void> load() async {
    _connections = await store.load();
  }

  /// Record a successful [host]:[port] connection.
  Future<void> record(String host, int port) => _mutate(() async {
        _publish(
          withRecordedNetworkConnection(
            _connections,
            host: host,
            port: port,
            connectedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
          ),
        );
        try {
          await store.save(_connections);
        } catch (e) {
          onLog('Could not save network connection history: $e');
        }
      });

  /// Remove a saved target after the file write succeeds.
  Future<bool> remove(SavedNetworkConnection connection) => _mutate(
        () => _save(
          withoutNetworkConnection(_connections, connection.key),
          failureLog: 'Could not remove the saved network connection',
        ),
      );

  /// Restore a removed target with its original timestamp.
  ///
  /// A newer entry for the same key wins if the user reconnected before Undo.
  Future<bool> restore(SavedNetworkConnection connection) => _mutate(
        () => _save(
          withRestoredNetworkConnection(_connections, connection),
          failureLog: 'Could not restore the saved network connection',
        ),
      );

  Future<bool> _save(
    List<SavedNetworkConnection> next, {
    required String failureLog,
  }) async {
    try {
      await store.save(next);
    } catch (e) {
      onLog('$failureLog: $e');
      return false;
    }
    _publish(next);
    return true;
  }

  void _publish(List<SavedNetworkConnection> connections) {
    _connections = connections;
    onChanged();
  }

  Future<T> _mutate<T>(Future<T> Function() action) {
    final previous = _tail;
    final run = previous == null
        ? action()
        : previous.then(
            (_) => action(),
            onError: (Object _) => action(),
          );
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }
}
