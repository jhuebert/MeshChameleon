import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

var _seed = 80;

Future<(MeshNode, FakeDeviceLink)> _makeNode({
  int firmwareVerCode = 14,
  InMemoryNodeStore? store,
  Future<void> Function()? onPoweredOff,
  RadioParams? radioParams,
}) async {
  final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = _seed++);
  final link = FakeDeviceLink(
    deviceInfo_: DeviceInfo(firmwareVerCode: firmwareVerCode),
    radioParams_: radioParams ??
        const RadioParams(
          frequencyHz: 915000000,
          bandwidthHz: 250000,
          spreadingFactor: 10,
          codingRate: 5,
          txPowerDbm: 20,
        ),
  );
  await link.connect();
  final node = MeshNode(
    identity: id,
    link: link,
    physical: PhysicalCapabilities(
      firmwareVerCode: firmwareVerCode,
      maxTxPower: 30,
    ),
    store: store ?? InMemoryNodeStore(),
    onPoweredOff: onPoweredOff,
  );
  await node.load();
  return (node, link);
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test('binary_and_cli_reboot_each_send_exactly_one_device_reboot', () async {
    final (node, link) = await _makeNode();
    addTearDown(node.stop);

    await node.reboot();
    expect(link.calls.where((c) => c == 'reboot').length, 1);
    expect(link.rebootRequests, 1);

    expect(await node.runCliCommand('reboot'), 'OK');
    expect(link.calls.where((c) => c == 'reboot').length, 2);
    expect(link.rebootRequests, 2);
  });

  test('no_reply_disconnect_does_not_wait5s_or_report_cli_timeout', () async {
    final (node, link) = await _makeNode();
    addTearDown(node.stop);
    final stopwatch = Stopwatch()..start();
    final reply = await node.runCliCommand('reboot');
    stopwatch.stop();
    expect(reply, 'OK');
    expect(link.rebootRequests, 1);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('reboot_write_failure_before_dispatch_reports_error', () async {
    final (node, link) = await _makeNode();
    addTearDown(node.stop);
    link.rebootError = const DeviceCommandError.disconnected(
      message: 'not connected',
    );

    await expectLater(
      node.reboot(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
    );
    expect(link.rebootRequests, 0);
    expect(await node.runCliCommand('reboot'), 'Error: device unavailable');
    expect(link.rebootRequests, 0);
  });

  test('reboot_keeps_virtual_durable_data_clears_ephemeral_operations',
      () async {
    final peer = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 91);
    final anon = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 92);
    final store = InMemoryNodeStore();
    await store.save(NodeState(
      prefs: NodePrefs(nodeName: 'kept name'),
      contacts: [
        Contact(
          publicKey: peer.publicKey,
          name: 'kept contact',
          outPath: Uint8List.fromList([1]),
          outPathLen: 1,
        ),
      ],
      channels: {
        2: Channel(
          name: 'kept channel',
          secret: Uint8List.fromList(List.filled(16, 4)),
        ),
      },
      queue: [
        QueuedMessage(senderKey: peer.publicKey, text: 'kept queue'),
      ],
      advertPaths: {
        'aabbccddeeff00': AdvertPath(
          publicKeyPrefix:
              Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0]),
          name: 'path',
          pathLen: 1,
          path: Uint8List.fromList([0x42]),
          recvTimestamp: 5,
        ),
      },
    ));
    final (node, link) = await _makeNode(store: store);
    node.start();
    addTearDown(node.stop);

    // Ephemeral anonymous contact.
    await node.sendAnonReq(anon.publicKey, Uint8List.fromList([1]));
    expect(node.getContactByKey(anon.publicKey), isNotNull);

    // Active login session.
    final login = await node.sendLogin(peer.publicKey, 'pw');
    final secret = await peer.sharedSecret(node.identity.publicKey);
    final body = Uint8List(13)
      ..setRange(
          0, 4, (BufferWriter()..writeUInt32Le(login.expectedAck!)).toBytes())
      ..[4] = 0
      ..[5] = 4;
    final cipher = CryptoUtils.encryptThenMac(
      secret.sublist(0, 16),
      secret,
      body,
    );
    link.deliver(
      6.0,
      -70,
      (Packet()
            ..header = Packet.createHeader(payloadTypeResponse, routeTypeDirect)
            ..payload = Uint8List.fromList([
              node.identity.publicKey[0],
              peer.publicKey[0],
              ...cipher,
            ]))
          .writeTo(),
    );
    await pump();
    expect(node.hasConnection(peer.publicKey), isTrue);

    await node.reboot();

    expect(node.prefs.nodeName, 'kept name');
    expect(node.getContactByKey(peer.publicKey)?.name, 'kept contact');
    expect(node.getChannel(2)?.name, 'kept channel');
    expect(
      node.getAdvertPath(
        Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0]),
      ),
      isNotNull,
    );
    expect(node.getContactByKey(anon.publicKey), isNull,
        reason: 'transient contacts are ephemeral');
    expect(node.hasConnection(peer.publicKey), isFalse);
    expect((await node.syncNextMessage())?.text, 'kept queue');
  });

  test('shutdown_stops_tx_and_reconnect_until_explicit_connect', () async {
    var offCallbacks = 0;
    final (node, link) = await _makeNode(
      onPoweredOff: () async => offCallbacks++,
    );
    node.start();
    addTearDown(node.stop);
    final transmittedBefore = link.transmitted.length;

    await node.shutdown();
    expect(node.poweredOff, isTrue);
    expect(link.shutdownRequests, 1);
    expect(link.cliCommands, contains('poweroff'));
    expect(offCallbacks, 1);
    expect(await node.sendControlData(Uint8List.fromList([1])), isFalse);
    expect(link.transmitted.length, transmittedBefore);

    // Idempotent while off.
    await node.shutdown();
    expect(link.shutdownRequests, 1);

    // Explicit restart re-enables semantic work.
    if (link.currentState != LinkState.connected) await link.connect();
    node.start();
    expect(node.poweredOff, isFalse);
    expect(await node.sendControlData(Uint8List.fromList([2])), isTrue);
    expect(link.transmitted.length, transmittedBefore + 1);
  });

  test('shutdown_is_gated_by_physical_fw14_and_reports_failures', () async {
    final (oldNode, oldLink) = await _makeNode(firmwareVerCode: 13);
    addTearDown(oldNode.stop);
    await expectLater(
      oldNode.shutdown(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeUnsupportedCmd)),
    );
    expect(oldLink.shutdownRequests, 0);

    final (node, link) = await _makeNode();
    addTearDown(node.stop);
    link.shutdownError = const DeviceCommandError.disconnected(
      message: 'not connected',
    );
    await expectLater(
      node.shutdown(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeBadState)),
    );
    expect(node.poweredOff, isFalse);
    expect(link.shutdownRequests, 0);
  });

  test('reconnect_refresh_preserves_virtual_mode_identity_and_preferences',
      () async {
    final (node, link) = await _makeNode();
    node.start();
    addTearDown(node.stop);
    await node.setAdvertName('Virtual Name');
    await node.setPathHashMode(2);
    await node.setMultiAcks(3);
    await node.setTimezoneOffsetHours(-4);
    final identityBefore = Uint8List.fromList(node.identity.publicKey);

    await link.disconnect();
    await link.connect();
    const refreshed = RadioParams(
      frequencyHz: 921000000,
      bandwidthHz: 125000,
      spreadingFactor: 11,
      codingRate: 6,
      txPowerDbm: 17,
    );
    await link.setRadioParams(refreshed);
    node.adoptPhysicalCapabilities(const PhysicalCapabilities(
      firmwareVerCode: 14,
      maxTxPower: 28,
    ));
    node.syncRadioParams(refreshed);
    node.start();

    expect(node.identity.publicKey, identityBefore);
    expect(node.prefs.nodeName, 'Virtual Name');
    expect(node.prefs.pathHashMode, 2);
    expect(node.prefs.multiAcks, 3);
    expect(node.prefs.timezoneOffsetHours, -4);
    expect(node.prefs.frequencyHz, refreshed.frequencyHz);
    expect(node.prefs.bandwidthHz, refreshed.bandwidthHz);
    expect(node.prefs.spreadingFactor, refreshed.spreadingFactor);
    expect(node.prefs.codingRate, refreshed.codingRate);
    expect(node.prefs.txPowerDbm, refreshed.txPowerDbm);
  });

  test('virtual_reset_and_key_import_never_reboot_the_device', () async {
    final (node, link) = await _makeNode();
    addTearDown(node.stop);
    final old = node.identity;
    final replacement = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 93);
    await node.importPrivateKey(replacement.meshcore64);
    expect(link.rebootRequests, 0);
    expect(node.identity.publicKey, isNot(old.publicKey));
    await node.resetVirtualState();
    expect(link.rebootRequests, 0);
  });
}
