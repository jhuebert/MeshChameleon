import 'dart:io';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/services/proxy_controller.dart';
import 'package:meshchameleon/services/proxy_status.dart';

class _FailingServer extends CompanionServer {
  _FailingServer(CompanionBridge bridge) : super(bridge: bridge);

  @override
  Future<void> stop() async => throw StateError('boom');
}

ProxyController _controller({
  required MeshNode? Function() activeNode,
  required List<String> logs,
  int Function()? port,
  int Function()? identityCount,
  bool Function()? deviceConnected,
  Future<void> Function()? updateNotification,
}) =>
    ProxyController(
      activeNode: activeNode,
      identityCount: identityCount ?? () => 1,
      deviceConnected: deviceConnected ?? () => true,
      metrics: CompanionMetrics(),
      port: port ?? () => 0,
      setPort: (_) {},
      notify: () {},
      log: logs.add,
      updateNotification: updateNotification ?? () async {},
    );

void main() {
  test('the default platform probe is used when no override is supplied', () {
    final error = SocketException(
      'Failed to create server socket',
      osError: const OSError('Address already in use', 48),
      port: 5000,
    );
    final message = describeProxyStartFailure(error, 5000);
    expect(message, contains('Proxy port 5000 is already in use'));
  });

  test('Linux and Windows address-in-use codes get the port-setting hint', () {
    for (final code in [98, 10048]) {
      final error = SocketException(
        'Failed to create server socket',
        osError: OSError('Address already in use', code),
        port: 5000,
      );
      expect(describeProxyStartFailure(error, 5000, isMacOS: false),
          contains('Choose another port in Settings'));
    }
  });

  test('a socket failure without an OS error keeps the generic message', () {
    final message = describeProxyStartFailure(
      const SocketException('no route'),
      5000,
    );
    expect(message, contains('Failed to start proxy:'));
  });

  test('start reports why no identity can be served', () async {
    final logs = <String>[];
    var identities = 0;
    var connected = false;
    final controller = _controller(
      activeNode: () => null,
      identityCount: () => identities,
      deviceConnected: () => connected,
      logs: logs,
    );

    await controller.start();
    expect(logs, contains('No identity available'));

    identities = 1;
    await controller.start();
    expect(logs, contains('Connect a device first'));

    connected = true;
    await controller.start();
    expect(logs, contains('The active identity is unavailable'));
    expect(controller.status, ProxyStatus.stopped);
  });

  testWidgets('a bind failure is reported and leaves no server',
      (tester) async {
    final logs = <String>[];
    final node = MeshNode(
      identity: await LocalIdentity.generate(),
      link: FakeDeviceLink(),
    );
    final controller = _controller(activeNode: () => node, logs: logs);

    // A negative port cannot be bound, so CompanionServer.start() fails before
    // any listener is opened.
    await controller.start(serverPort: -1);

    expect(controller.status, ProxyStatus.stopped);
    expect(controller.server, isNull);
    expect(logs.any((line) => line.contains('Failed to start proxy:')), isTrue);
  });

  test('a failed listener close is reported on stop', () async {
    final logs = <String>[];
    final node = MeshNode(
      identity: await LocalIdentity.generate(),
      link: FakeDeviceLink(),
    );
    final controller = _controller(activeNode: () => node, logs: logs);
    controller.server = _FailingServer(node);

    await controller.stop();

    expect(logs, contains('Could not stop the proxy cleanly: Bad state: boom'));
    expect(controller.status, ProxyStatus.stopped);
  });

  test('dispose stops a running server', () async {
    final logs = <String>[];
    final node = MeshNode(
      identity: await LocalIdentity.generate(),
      link: FakeDeviceLink(),
    );
    final controller = _controller(activeNode: () => node, logs: logs);
    controller.server = CompanionServer(bridge: node, onLog: logs.add);

    controller.dispose();
    expect(controller.status, ProxyStatus.stopped);
    expect(controller.server, isNull);
  });

  test('a start queued behind a failed stop still runs', () async {
    final logs = <String>[];
    final controller = _controller(
      activeNode: () => null,
      identityCount: () => 0,
      logs: logs,
      updateNotification: () async => throw StateError('boom'),
    );

    final failedStop = controller.stop();
    final queuedStart = controller.start();
    await failedStop.catchError((_) {});
    await queuedStart;

    expect(logs, contains('No identity available'));
  });
}
