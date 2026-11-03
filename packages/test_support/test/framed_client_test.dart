import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';
import 'package:test_support/test_support.dart';

void main() {
  test('StreamQueue returns buffered and awaited values', () async {
    final controller = StreamController<int>();
    final queue = StreamQueue(controller.stream);
    controller.add(1);
    await Future<void>.delayed(Duration.zero);
    expect(await queue.next(), 1);

    final pending = queue.next();
    controller.add(2);
    expect(await pending, 2);
    expect(await queue.nextWithin(const Duration(milliseconds: 10)), isNull);
    await queue.cancel();
    await controller.close();
  });

  test('FramedClient sends inbound frames and reads outbound frames', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    final accepted = server.first;
    final socket = await Socket.connect(server.address, server.port);
    final client = FramedClient(socket);
    addTearDown(client.close);
    final peer = await accepted;

    final received = Completer<List<int>>();
    final codec = SerialFrameCodec.bidirectional();
    peer.listen((data) {
      received.complete(codec.ingest(data).single);
    });
    client.send([1, 2, 3]);
    expect(await received.future, [1, 2, 3]);

    peer.add(codec.encodeFrame([9, 8], prefix: frameOutboundPrefix));
    expect(await client.next(), Uint8List.fromList([9, 8]));
    peer.add(codec.encodeFrame([9, 7], prefix: frameOutboundPrefix));
    expect(await client.awaitCode(9, const Duration(seconds: 1)), isTrue);
    await peer.close();
  });

  _schedulerTests();
}

void _schedulerTests() {
  test('FakeScheduler fires one-shot and periodic timers in order', () {
    final scheduler = FakeScheduler();
    final fired = <String>[];
    scheduler.create(const Duration(milliseconds: 10), () => fired.add('one'));
    final periodic = scheduler.createPeriodic(
      const Duration(milliseconds: 10),
      (_) => fired.add('periodic'),
    );

    scheduler.elapse(const Duration(milliseconds: 25));
    expect(fired, ['one', 'periodic', 'periodic']);
    expect(periodic.tick, 2);

    periodic.cancel();
    scheduler.elapse(const Duration(milliseconds: 25));
    expect(fired, ['one', 'periodic', 'periodic']);
  });
}
