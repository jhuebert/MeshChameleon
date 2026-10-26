import 'dart:async';
import 'dart:io';

import 'package:device_link/device_link.dart';
import 'package:test/test.dart';

void main() {
  test('a closed device link yields a typed disconnected error, not a crash',
      () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<Socket>();
    final serverSub = server.listen((socket) {
      if (!accepted.isCompleted) accepted.complete(socket);
    });
    final link = TcpDeviceLink(host: '127.0.0.1', port: server.port);
    await link.connect();
    final peer = await accepted.future;
    final states = <LinkState>[];
    final stateSub = link.state.listen(states.add);
    addTearDown(() async {
      await stateSub.cancel();
      await link.disconnect();
      await peer.close();
      await serverSub.cancel();
      await server.close();
    });

    await peer.close();
    await server.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>().having(
        (e) => e.kind,
        'kind',
        DeviceCommandErrorKind.disconnected,
      )),
    );
    expect(link.currentState, LinkState.disconnected);
    expect(states, contains(LinkState.disconnected));

    // A second command must also fail cleanly rather than throwing an
    // unhandled SocketException from the dead socket.
    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()),
    );
  });
}
