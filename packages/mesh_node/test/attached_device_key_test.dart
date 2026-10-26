import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('unicast to the attached radio key is rejected without transmission',
      () async {
    final identity = await LocalIdentity.generate();
    final device = await LocalIdentity.generate();
    final link = FakeDeviceLink();
    await link.connect();
    final node = MeshNode(
      identity: identity,
      link: link,
      attachedDevicePublicKey: Uint8List.fromList(device.publicKey),
    )..start();
    addTearDown(node.stop);

    await node.addUpdateContact(Contact(
      publicKey: Uint8List.fromList(device.publicKey),
      name: 'attached radio',
      advType: advTypeChat,
    ));
    final before = link.transmitted.length;

    Future<void> rejects(Future<Object?> future) async {
      await expectLater(
        future,
        throwsA(isA<CompanionOperationError>()
            .having((e) => e.code, 'code', errCodeIllegalArg)),
      );
    }

    await rejects(node.sendTextMessage(device.publicKey, 'hello'));
    await rejects(node.sendBinaryReq(device.publicKey, Uint8List.fromList([1])));
    await rejects(node.sendAnonReq(device.publicKey, Uint8List.fromList([1])));
    await rejects(node.sendTelemetryRequest(device.publicKey));
    expect(link.transmitted, hasLength(before));
  });

  test('a different peer is not blocked by the attached-radio guard', () async {
    final identity = await LocalIdentity.generate();
    final device = await LocalIdentity.generate();
    final peer = await LocalIdentity.generate();
    final link = FakeDeviceLink();
    await link.connect();
    final node = MeshNode(
      identity: identity,
      link: link,
      attachedDevicePublicKey: Uint8List.fromList(device.publicKey),
    )..start();
    addTearDown(node.stop);
    await node.addUpdateContact(Contact(
      publicKey: Uint8List.fromList(peer.publicKey),
      name: 'peer',
      advType: advTypeChat,
    ));
    final result = await node.sendTextMessage(peer.publicKey, 'hello');
    expect(result.success, isTrue);
    expect(link.transmitted, isNotEmpty);
  });
}
