import 'dart:async';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_node/mesh_node.dart';

import 'proxy_status.dart';

/// Owns the app-facing companion server and its start/stop transition queue.
///
/// The controller reads the active node and connection state through callbacks
/// so it can stay independent of the app composition root. Notification copy
/// and the effective port are written back through the owner's hooks.
class ProxyController {
  ProxyController({
    required this.activeNode,
    required this.identityCount,
    required this.deviceConnected,
    required this.metrics,
    required this.port,
    required this.setPort,
    required this.notify,
    required this.log,
    required this.updateNotification,
  });

  final MeshNode? Function() activeNode;
  final int Function() identityCount;
  final bool Function() deviceConnected;
  final CompanionMetrics metrics;
  final int Function() port;
  final void Function(int value) setPort;
  final void Function() notify;
  final void Function(String message) log;
  final Future<void> Function() updateNotification;

  CompanionServer? server;
  ProxyStatus status = ProxyStatus.stopped;

  /// Serializes queued start/stop operations so a rapid toggle cannot leave a
  /// listener running with the UI reporting stopped (or the reverse).
  Future<void>? _tail;

  bool get running => status == ProxyStatus.running;

  Future<T> _runTransition<T>(Future<T> Function() action) {
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

  Future<void> start({int? serverPort}) =>
      _runTransition(() => _start(serverPort));

  Future<void> _start(int? serverPort) async {
    final active = activeNode();
    if (active == null) {
      log(identityCount() == 0
          ? 'No identity available'
          : deviceConnected()
              ? 'The active identity is unavailable'
              : 'Connect a device first');
      return;
    }
    final current = server ??= CompanionServer(
      bridge: active,
      config: CompanionServerConfig(port: serverPort ?? port()),
      metrics: metrics,
      onLog: log,
    );
    try {
      await current.start();
      setPort(current.port ?? port());
      status = ProxyStatus.running;
      log('Proxy server listening on port ${port()}');
      await updateNotification();
    } catch (e) {
      log('Failed to start proxy: $e');
      try {
        await current.stop();
      } catch (_) {}
      if (identical(server, current)) server = null;
    }
    notify();
  }

  Future<void> stop() => _runTransition(_stop);

  Future<void> _stop() async {
    final current = server;
    server = null;
    try {
      await current?.stop();
    } catch (e) {
      log('Could not stop the proxy cleanly: $e');
    }
    status = ProxyStatus.stopped;
    await updateNotification();
    notify();
  }

  void dispose() {
    status = ProxyStatus.stopped;
    final current = server;
    server = null;
    if (current != null) unawaited(current.stop());
  }
}
