import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';
import 'package:test_support/test_support.dart';

import 'support/test_bridge.dart';

void main() {
  late CompanionServer server;
  late FramedClient client;
  late TestBridge bridge;
  late LocalIdentity identity;
  late List<String> serverLogs;

  setUp(() async {
    identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
    bridge = TestBridge(identity);
    serverLogs = <String>[];
    server = CompanionServer(
      bridge: bridge,
      config: const CompanionServerConfig(port: 0),
      onLog: serverLogs.add,
    );
    await server.start();
    final socket = await Socket.connect('127.0.0.1', server.port!);
    client = FramedClient(socket);
  });

  tearDown(() async {
    await client.close();
    await server.stop();
  });

  test('DEVICE_QUERY returns DEVICE_INFO', () async {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeDeviceInfo);
    expect(resp[1], defaultFirmwareVerCode);
    expect(resp[2], 255); // maxContacts / 2, clamped to a byte
    expect(resp[3], 8);
  });

  test('metrics count client traffic and disconnect reasons', () async {
    expect(server.metrics.clientConnections, 1);
    expect(server.metrics.clientConnected, isTrue);

    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(server.metrics.commandsReceived, 1);
    expect(server.metrics.payloadBytesIn, 2);
    expect(server.metrics.replyFramesSent, 1);
    expect(server.metrics.payloadBytesOut, resp.length);
    expect(server.metrics.appTargetVer, appProtocolVersion);

    server.pushRawRxData(6, -70, Uint8List.fromList([1, 2, 3]));
    final push = await client.frames.next();
    expect(push[0], pushCodeLogRxData);
    expect(server.metrics.pushesSent, 1);

    client.send([0xFE]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(server.metrics.unsupportedCommands, 1);
    expect(server.metrics.errorReplyFrames, 1);

    await server.disconnectClient(reason: 'test close');
    expect(server.metrics.clientConnected, isFalse);
    expect(server.metrics.clientDisconnects, 1);
    expect(server.metrics.lastDisconnectReason, 'test close');
  });

  test('APP_START does not override the DEVICE_QUERY protocol version',
      () async {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.frames.next();
    expect(server.metrics.appTargetVer, appProtocolVersion);

    // Spec-compliant APP_START: 7 reserved bytes followed by the app name.
    client.send([
      cmdAppStart,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      ...utf8Bytes('mccli'),
      0,
    ]);
    expect((await client.frames.next())[0], respCodeSelfInfo);
    expect(server.metrics.appTargetVer, appProtocolVersion);
  });

  test('metrics count a client eviction', () async {
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await client.frames.next();
    expect(server.metrics.appTargetVer, appProtocolVersion);

    final replacement =
        FramedClient(await Socket.connect('127.0.0.1', server.port!));
    addTearDown(replacement.close);
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(server.metrics.clientConnections, 2);
    expect(server.metrics.clientDisconnects, 1);
    expect(server.metrics.evictions, 1);
    expect(server.metrics.appTargetVer, isNull);
  });

  test('server_rejects_outbound_prefix_as_command', () async {
    // An outbound-prefixed frame is not an app command; the next valid inbound
    // command must be the first one handled.
    client.sendFrame([cmdGetDeviceTime], prefix: frameOutboundPrefix);
    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeDeviceInfo);
  });

  test('target_info_bytes_are_wire_representable', () async {
    bridge.deviceInfo = buildVirtualDeviceInfo(
      clientRepeat: 1,
      pathHashMode: 2,
      targetBaseline: true,
    );
    bridge.pathHash = 2;
    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();

    expect(resp.length, 82);
    expect(resp[1], targetFirmwareVerCode);
    expect(resp[2], 175, reason: 'max_contacts byte is 350 / 2');
    expect(resp[3], 40);
    expect(resp.sublist(4, 8), [0, 0, 0, 0], reason: 'virtual BLE PIN is 0');
    expect(resp.sublist(8, 20), everyElement(0),
        reason: 'no physical build date');

    final manufacturer = resp.sublist(20, 60);
    expect(
      String.fromCharCodes(manufacturer.takeWhile((b) => b != 0)),
      virtualBoardName,
    );
    expect(
      manufacturer.skip(utf8.encode(virtualBoardName).length),
      everyElement(0),
    );

    final version = resp.sublist(60, 80);
    expect(
      String.fromCharCodes(version.takeWhile((b) => b != 0)),
      targetCompatibilityVersion,
    );
    expect(version.skip(utf8.encode(targetCompatibilityVersion).length),
        everyElement(0));
    expect(resp[80], 1, reason: 'physical client repeat');
    expect(resp[81], 2, reason: 'virtual path mode');
    expect(String.fromCharCodes(resp), isNot(contains('Physical')));
  });

  test('SEND_CHANNEL_DATA accepts 157 stock-frame bytes and rejects 158/165',
      () async {
    bridge.channels[0] = Channel(
      name: 'Public',
      secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
    );
    final payload = List<int>.filled(157, 0xAB);
    final accepted = BufferWriter()
      ..writeByte(cmdSendChannelData)
      ..writeByte(0)
      ..writeByte(0xFF)
      ..writeUInt16Le(0x1234)
      ..writeBytes(payload);
    client.send(accepted.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.sentChannelDataPayload, payload);

    for (final length in [158, 165, 166]) {
      final rejected = BufferWriter()
        ..writeByte(cmdSendChannelData)
        ..writeByte(0)
        ..writeByte(0xFF)
        ..writeUInt16Le(0x1234)
        ..writeBytes(List<int>.filled(length, 0xCD));
      client.send(rejected.toBytes());
      expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg],
          reason: '$length bytes cannot fit the 176-byte companion frame');
    }
    expect(bridge.sentChannelDataPayload, payload, reason: 'no partial send');
  });

  test('APP_START returns SELF_INFO with the proxy public key', () async {
    client.send([cmdAppStart, 0, 0, 0, 0, 0, 0, 0]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeSelfInfo);
    expect(resp.sublist(4, 36), identity.publicKey);
    final r = BufferReader(resp.sublist(4 + 32 + 8 + 4));
    expect(r.readUInt32Le(), 915000);
  });

  test('GET_BATT_AND_STORAGE returns battery', () async {
    client.send([cmdGetBattAndStorage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeBattAndStorage);
    expect(BufferReader(resp).readUInt16Le(), isNot(0));
  });

  test('R2 battery_storage_exact_bytes_update_on_virtual_growth_and_shrink',
      () async {
    bridge.batteryReading = const BatteryReading(
      millivolts: 3700,
      storageUsedKb: 1,
      storageTotalKb: 4096,
    );
    client.send([cmdGetBattAndStorage]);
    expect(await client.frames.next(), [
      respCodeBattAndStorage,
      0x74, 0x0E, // 3700 mV, little-endian
      0x01, 0x00, 0x00, 0x00,
      0x00, 0x10, 0x00, 0x00, // 4096 KiB
    ]);

    bridge.batteryReading = const BatteryReading(
      millivolts: 3650,
      storageUsedKb: 5,
      storageTotalKb: 4096,
    );
    client.send([cmdGetBattAndStorage]);
    expect(await client.frames.next(), [
      respCodeBattAndStorage,
      0x42, 0x0E, // 3650 mV
      0x05, 0x00, 0x00, 0x00,
      0x00, 0x10, 0x00, 0x00,
    ]);

    bridge.batteryReading = const BatteryReading(
      millivolts: 3650,
      storageUsedKb: 2,
      storageTotalKb: 4096,
    );
    client.send([cmdGetBattAndStorage]);
    expect(await client.frames.next(), [
      respCodeBattAndStorage,
      0x42,
      0x0E,
      0x02,
      0x00,
      0x00,
      0x00,
      0x00,
      0x10,
      0x00,
      0x00,
    ]);
  });

  test('core_stats_and_self_telemetry_use_same_refreshed_voltage', () async {
    bridge
      ..batteryReading = const BatteryReading(
        millivolts: 3700,
        storageUsedKb: 2,
        storageTotalKb: 4096,
      )
      ..batteryReads = 0
      ..statsReads = 0;

    client.send([cmdSendTelemetryReq, 0, 0, 0]);
    final telemetry = await client.frames.next();
    expect(telemetry[0], pushCodeTelemetryResponse);
    expect(telemetry[9], 0x74);
    expect((telemetry[10] << 8) | telemetry[11], 370); // 3700 mV -> 0.01 V

    client.send([cmdGetStats, statsTypeCore]);
    final stats = await client.frames.next();
    expect(stats[0], respCodeStats);
    expect(stats[1], statsTypeCore);
    expect(BufferReader(stats.sublist(2)).readUInt16Le(), 3700);
    expect(bridge.batteryReads, 2);
    expect(bridge.statsReads, 1);
  });

  test('GET_STATS radio relays a signed noise floor', () async {
    client.send([cmdGetStats, statsTypeRadio]);
    final stats = await client.frames.next();
    expect(stats[0], respCodeStats);
    expect(stats[1], statsTypeRadio);
    final r = BufferReader(stats)..skipBytes(2);
    expect(r.readInt16Le(), -110);
    expect(r.readInt8(), -70);
    expect(r.readInt8(), 24);
    expect(r.readUInt32Le(), 1);
    expect(r.readUInt32Le(), 2);
  });

  test('GET_CUSTOM_VARS returns custom vars frame', () async {
    client.send([cmdGetCustomVars]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCustomVars);
  });

  test('GET_CONTACTS streams start/contact/end', () async {
    bridge.contacts.add(Contact(
      publicKey: Uint8List(32)..[0] = 9,
      name: 'peer',
      advType: advTypeChat,
      lastmod: 100,
    ));
    client.send([cmdGetContacts, 0, 0, 0, 0]);
    expect((await client.frames.next())[0], respCodeContactsStart);
    final contact = await client.frames.next();
    expect(contact[0], respCodeContact);
    expect(contact.sublist(1, 33), bridge.contacts.first.publicKey);
    expect((await client.frames.next())[0], respCodeEndOfContacts);
  });

  test('GET_CONTACTS reports the total count while filtering by since',
      () async {
    bridge.contacts.addAll([
      Contact(
        publicKey: Uint8List(32)..[0] = 9,
        name: 'old',
        lastmod: 50,
      ),
      Contact(
        publicKey: Uint8List(32)..[0] = 10,
        name: 'new',
        lastmod: 200,
      ),
    ]);

    client.send([cmdGetContacts, 100, 0, 0, 0]);
    final start = await client.frames.next();
    expect(start[0], respCodeContactsStart);
    expect((BufferReader(start)..skipBytes(1)).readUInt32Le(), 2);

    final contact = await client.frames.next();
    expect(contact[0], respCodeContact);
    expect(contact.sublist(1, 2), [10]);

    final end = await client.frames.next();
    expect(end[0], respCodeEndOfContacts);
    expect((BufferReader(end)..skipBytes(1)).readUInt32Le(), 200);
  });

  test('unlisted command IDs return ERR unsupported', () async {
    for (final id in [44, 45, 46, 47, 48, 49, 53]) {
      client.send([id]);
      expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    }
  });

  test('raw RX frames are forwarded as PUSH_CODE_LOG_RX_DATA', () async {
    final raw = Uint8List.fromList([1, 2, 3, 4]);
    server.pushRawRxData(6.0, -70, raw);
    expect(await client.frames.next(), [pushCodeLogRxData, 24, 186, ...raw]);
  });

  test('raw custom data uses 0x84 with reserved 0xFF', () async {
    final payload = Uint8List.fromList([9, 8, 7]);
    server.pushRawData(6.0, -70, payload);
    expect(await client.frames.next(),
        [pushCodeRawData, 24, 186, 0xFF, ...payload]);
  });

  test('SET_CHANNEL then GET_CHANNEL round trips', () async {
    final psk = Uint8List.fromList(List.generate(16, (i) => i));
    final w = BufferWriter()
      ..writeByte(cmdSetChannel)
      ..writeByte(3)
      ..writeCString('general', 32)
      ..writeBytes(psk);
    client.send(w.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetChannel, 3]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeChannelInfo);
    expect(resp[1], 3);
    expect(resp.sublist(34, 50), psk);
  });

  test('SEND_CHANNEL_TXT_MSG uses the client timestamp', () async {
    bridge.channels[0] = Channel(
      name: 'Public',
      secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
    );
    final w = BufferWriter()
      ..writeByte(cmdSendChannelTxtMsg)
      ..writeByte(txtTypePlain)
      ..writeByte(0)
      ..writeUInt32Le(0x6AD05965)
      ..writeString('P')
      ..writeByte(0);
    client.send(w.toBytes());

    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.sentChannelIndex, 0);
    expect(bridge.sentChannelText, 'P');
    expect(bridge.sentChannelTimestamp, 0x6AD05965);
  });

  test('SEND_CHANNEL_TXT_MSG decodes UTF-8 text', () async {
    bridge.channels[0] = Channel(
      name: 'Public',
      secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
    );
    final w = BufferWriter()
      ..writeByte(cmdSendChannelTxtMsg)
      ..writeByte(txtTypePlain)
      ..writeByte(0)
      ..writeUInt32Le(0)
      ..writeString('💯🤣')
      ..writeByte(0);
    client.send(w.toBytes());

    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.sentChannelText, '💯🤣');
  });

  test('SET_RADIO_PARAMS validates and forwards', () async {
    final good = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(915000) // kHz
      ..writeUInt32Le(250000)
      ..writeByte(10)
      ..writeByte(5);
    client.send(good.toBytes());
    expect((await client.frames.next())[0], respCodeOk);

    final bad = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(915000)
      ..writeUInt32Le(250000)
      ..writeByte(99)
      ..writeByte(5);
    client.send(bad.toBytes());
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);
  });

  test('radio_set_has_no_ok_or_cache_change_before_device_ack', () async {
    final ack = Completer<void>();
    bridge.radioAck = ack;
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());

    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
      reason: 'no OK before the device acknowledges the write',
    );
    expect(bridge.radioFreqHz, 869000000);

    ack.complete();
    final ok = await client.frames.next();
    expect(ok, [respCodeOk]);
  });

  test('tx_and_tuning_setters_also_await_ack', () async {
    final txAck = Completer<void>();
    bridge.txAck = txAck;
    client.send([cmdSetRadioTxPower, 10]);
    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
    );
    txAck.complete();
    expect(await client.frames.next(), [respCodeOk]);

    final tuningAck = Completer<void>();
    bridge.tuningAck = tuningAck;
    final w = BufferWriter()
      ..writeByte(cmdSetTuningParams)
      ..writeUInt32Le(100)
      ..writeUInt32Le(200);
    client.send(w.toBytes());
    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
    );
    tuningAck.complete();
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.tuning.rxDelayBaseMs, 100);
    expect(bridge.tuning.airtimeFactorMs, 200);
  });

  test('device_err6_is_preserved_and_cache_unchanged', () async {
    bridge.radioError = const CompanionOperationError(
      errCodeIllegalArg,
      message: 'device rejected regulatory setting',
    );
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());

    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('disconnected_or_timeout_is_err4_and_cache_uncertain_no_write_retry',
      () async {
    bridge.radioError = const CompanionOperationError(
      errCodeBadState,
      message: 'device reply timed out',
      uncertain: true,
    );
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());

    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
  });

  test('explicit_repeat_validated_and_forwarded', () async {
    BufferWriter radioFrame(int repeat) => BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5)
      ..writeByte(repeat);

    client.send(radioFrame(1).toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.radioClientRepeat, isTrue);

    client.send(radioFrame(0).toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.radioClientRepeat, isFalse);

    bridge.radioFreqHz = null;
    client.send(radioFrame(2).toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.radioFreqHz, isNull,
        reason: 'invalid repeat is not forwarded');
  });

  test('tuning_get_without_cache_is_err4', () async {
    bridge.tuningGetError = const CompanionOperationError(
      errCodeBadState,
      message: 'no tuning cache',
    );
    client.send([cmdGetTuningParams]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
  });

  test('evicted_client_completion_never_replies_to_replacement_client',
      () async {
    final ack = Completer<void>();
    bridge.radioAck = ack;
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());
    await Future<void>.delayed(const Duration(milliseconds: 30));

    final replacementSocket = await Socket.connect('127.0.0.1', server.port!);
    final replacement = FramedClient(replacementSocket);
    addTearDown(replacement.close);
    replacement.send([cmdDeviceQuery, appProtocolVersion]);

    ack.complete();
    final first = await replacement.frames.next();
    expect(first[0], respCodeDeviceInfo,
        reason: 'old completion must not send OK to the replacement client');
  });

  test('physical_disabled_reply_is_one_byte_disabled', () async {
    bridge.radioError = const CompanionOperationError(15,
        disabled: true, message: 'device disabled the command');
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());
    expect(await client.frames.next(), [respCodeDisabled]);
  });

  test('commands_are_serialized_and_pushes_flow_while_awaiting_ack', () async {
    final ack = Completer<void>();
    bridge.radioAck = ack;
    final frame = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      ..writeUInt32Le(869000)
      ..writeUInt32Le(125000)
      ..writeByte(11)
      ..writeByte(5);
    client.send(frame.toBytes());
    client.send([cmdDeviceQuery, appProtocolVersion]);
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // Async radio pushes are not blocked by the waiting command.
    server.pushRawRxData(6.0, -70, Uint8List.fromList([1, 2]));
    expect((await client.frames.next())[0], pushCodeLogRxData);

    // The next client command waits for the in-flight config transaction.
    expect(
      await client.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
    );

    ack.complete();
    expect(await client.frames.next(), [respCodeOk]);
    expect((await client.frames.next())[0], respCodeDeviceInfo);
  });

  test('SEND_TXT_MSG to known contact returns SENT', () async {
    final pubkey = Uint8List(32)..[0] = 7;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));
    final w = BufferWriter()
      ..writeByte(cmdSendTxtMsg)
      ..writeByte(txtTypePlain)
      ..writeByte(2)
      ..writeUInt32Le(0x11223344)
      ..writeBytes(pubkey.sublist(0, 6))
      ..writeString('hi')
      ..writeByte(0);
    client.send(w.toBytes());
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    expect(bridge.sentTextAttempt, 2,
        reason: 'the client attempt byte is not rewritten');
    expect(bridge.sentTextTimestamp, 0x11223344,
        reason: 'the client timestamp is used for the ACK hash');
    final rr = BufferReader(resp)..skipBytes(2);
    expect(rr.readUInt32Le(), 0x1234);
  });

  test('SEND_TXT_MSG decodes UTF-8 text', () async {
    final pubkey = Uint8List(32)..[0] = 7;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));
    final w = BufferWriter()
      ..writeByte(cmdSendTxtMsg)
      ..writeByte(txtTypePlain)
      ..writeByte(0)
      ..writeUInt32Le(0)
      ..writeBytes(pubkey.sublist(0, 6))
      ..writeString('💯🤣')
      ..writeByte(0);
    client.send(w.toBytes());

    expect((await client.frames.next())[0], respCodeSent);
    expect(bridge.sentTextPubkey, pubkey);
    expect(bridge.sentText, '💯🤣');
  });

  test('SYNC_NEXT_MESSAGE with empty queue returns NO_MORE_MESSAGES', () async {
    client.send([cmdSyncNextMessage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeNoMoreMessages);
  });

  test('SYNC_NEXT_MESSAGE returns a queued direct message (V3)', () async {
    // Select the V3 message layout via DEVICE_QUERY.
    client.send([cmdDeviceQuery, 3]);
    await client.frames.next();

    final sender = Uint8List(32)..[0] = 7;
    bridge.nextMessage = QueuedMessage(
      senderKey: sender,
      txtType: txtTypePlain,
      timestamp: 0x11223344,
      text: 'hello',
      pathLen: 2,
      snr: 4.0,
    );

    client.send([cmdSyncNextMessage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeContactMsgRecvV3);
    final r = BufferReader(resp)..skipBytes(4); // code, snr, reserved, reserved
    expect(r.readBytes(6), sender.sublist(0, 6));
    expect(r.readByte(), 2); // path length
    expect(r.readByte(), txtTypePlain);
    expect(r.readUInt32Le(), 0x11223344);
    expect(r.readRemainingBytes(), utf8Bytes('hello'));

    // The bridge advances its cursor: the queue is now empty.
    client.send([cmdSyncNextMessage]);
    expect((await client.frames.next())[0], respCodeNoMoreMessages);
  });

  test('SYNC_NEXT_MESSAGE preserves the channel path-hash width (V3)',
      () async {
    client.send([cmdDeviceQuery, 3]);
    await client.frames.next();
    bridge.nextMessage = QueuedMessage(
      senderKey: Uint8List(32),
      timestamp: 0x11223344,
      text: 'heard',
      isChannel: true,
      channelIdx: 1,
      pathLen: 0x42,
    );

    client.send([cmdSyncNextMessage]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeChannelMsgRecvV3);
    expect(resp[5], 0x42);
  });

  test('app reset clearSigningBuffer discards partial signing data', () async {
    client.send([cmdSignStart]);
    expect((await client.frames.next())[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('stale reset data')]);
    expect((await client.frames.next())[0], respCodeOk);
    server.clearSigningBuffer();
    client.send([cmdSignFinish]);
    final signature = await client.frames.next();
    expect(signature[0], respCodeSignature);
    expect(
      await LocalIdentity.verify(
        Uint8List(0),
        signature.sublist(1),
        bridge.identity.publicKey,
      ),
      isTrue,
    );
  });

  test('SIGN_START/DATA/FINISH returns a 64-byte signature', () async {
    client.send([cmdSignStart]);
    final start = await client.frames.next();
    expect(start[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('hello')]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdSignFinish]);
    final sig = await client.frames.next();
    expect(sig[0], respCodeSignature);
    expect(sig.length, 65);
  });

  test('SET_PATH_HASH_MODE stores and DEVICE_QUERY reflects it', () async {
    client.send([cmdSetPathHashMode, 0, 1]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.pathHash, 1);

    client.send([cmdDeviceQuery, appProtocolVersion]);
    final resp = await client.frames.next();
    expect(resp[81] & 0xFF, 1);

    client.send([cmdSetPathHashMode, 0, 3]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);

    // Nonzero reserved byte is rejected without a state change.
    client.send([cmdSetPathHashMode, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    expect(bridge.pathHash, 1);
  });

  test('GET/SET_TUNING_PARAMS round trip', () async {
    final set = BufferWriter()
      ..writeByte(cmdSetTuningParams)
      ..writeUInt32Le(777)
      ..writeUInt32Le(42);
    client.send(set.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.tuning.rxDelayBaseMs, 777);
    expect(bridge.tuning.airtimeFactorMs, 42);

    client.send([cmdGetTuningParams]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeTuningParams);
    final r = BufferReader(resp)..skipBytes(1);
    expect(r.readUInt32Le(), 777);
    expect(r.readUInt32Le(), 42);
  });

  test('SEND_TELEMETRY_REQ returns SENT and later pushes the response',
      () async {
    final pubkey = Uint8List(32)..[0] = 7;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'sensor'));
    final w = BufferWriter()
      ..writeByte(cmdSendTelemetryReq)
      ..writeBytes([0, 0, 0])
      ..writeBytes(pubkey);
    client.send(w.toBytes());
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x99);
  });

  test('RUN_CLI_COMMAND forwards to the bridge and returns its reply',
      () async {
    bridge.cliReply = 'OK';
    client.send([cmdRunCliCommand, ...'adv_int 0'.codeUnits, 0]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCliReply);
    expect(String.fromCharCodes(resp.sublist(1)), 'OK');
  });

  test('RUN_CLI_COMMAND rejects embedded NUL and bounds UTF-8 replies',
      () async {
    client.send([cmdRunCliCommand, ...utf8Bytes('ver'), 0, 0]);
    final invalid = await client.frames.next();
    expect(invalid[0], respCodeCliReply);
    expect(utf8.decode(invalid.sublist(1)), 'Error: illegal argument');

    bridge.cliReply = 'é' * 200;
    client.send([cmdRunCliCommand, ...utf8Bytes('ver')]);
    final long = await client.frames.next();
    expect(long[0], respCodeCliReply);
    expect(long.length, maxCliReplyLength + 1);
    expect(utf8.decode(long.sublist(1)).endsWith('...'), isTrue);
  });

  test('SEND_TRACE_PATH returns SENT', () async {
    final w = BufferWriter()
      ..writeByte(cmdSendTracePath)
      ..writeUInt32Le(0x1234)
      ..writeUInt32Le(0)
      ..writeByte(0)
      ..writeBytes([1, 2, 3]);
    client.send(w.toBytes());
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x1234);
  });

  test('pushTraceData emits PUSH_CODE_TRACE_DATA matching the firmware',
      () async {
    server.pushTraceData(
      2,
      0,
      0x1111,
      0,
      Uint8List.fromList([1, 2]),
      Uint8List.fromList([0x20, 0x30]),
      24,
    );
    final resp = await client.frames.next();
    expect(resp[0], pushCodeTraceData);
    expect(resp[1], 0);
    expect(resp[2], 2); // path_len
    expect(resp[3], 0); // flags
    final r = BufferReader(resp)..skipBytes(4);
    expect(r.readUInt32Le(), 0x1111);
    expect(r.readUInt32Le(), 0);
    expect(r.readBytes(2), [1, 2]);
    expect(r.readBytes(2), [0x20, 0x30]);
    expect(r.readByte(), 24);
  });

  test('HAS_CONNECTION reflects the bridge session state', () async {
    final pubkey = identity.publicKey;

    bridge.connection = false;
    client.send([cmdHasConnection, ...pubkey]);
    final missing = await client.frames.next();
    expect(missing[0], respCodeErr);
    expect(missing[1], errCodeNotFound);

    bridge.connection = true;
    client.send([cmdHasConnection, ...pubkey]);
    expect((await client.frames.next())[0], respCodeOk);

    // Too short is an illegal argument, not a not-found.
    client.send([cmdHasConnection, 1, 2, 3]);
    final short = await client.frames.next();
    expect(short[0], respCodeErr);
    expect(short[1], errCodeUnsupportedCmd);
  });

  test('no_logs_contain_imported_or_exported_key_hex_or_payload', () async {
    final replacement = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 44);
    client.send([cmdExportPrivateKey]);
    final exported = await client.frames.next();
    expect(exported[0], respCodePrivateKey);
    client.send([cmdImportPrivateKey, ...replacement.meshcore64]);
    expect(await client.frames.next(), [respCodeOk]);

    final logs = serverLogs.join('\n');
    expect(logs, isNot(contains(bytesToHex(identity.meshcore64))));
    expect(logs, isNot(contains(bytesToHex(replacement.meshcore64))));
    expect(logs, isNot(contains(bytesToHex(identity.publicKey))));
    expect(logs, isNot(contains(bytesToHex(replacement.publicKey))));
  });

  test('pin and factory reset remain DISABLED', () async {
    final disabledCommands = <List<int>>[
      (BufferWriter()
            ..writeByte(cmdSetDevicePin)
            ..writeUInt32Le(123456))
          .toBytes(),
      [cmdFactoryReset, ...'reset'.codeUnits],
    ];

    for (final command in disabledCommands) {
      client.send(command);
      expect(await client.frames.next(), [respCodeDisabled]);
    }
    expect(server.metrics.disabledReplyFrames, 2);
    expect(server.metrics.errorReplyFrames, 0);
  });

  test('virtual key export/import switches signing and clears sign buffer',
      () async {
    final oldIdentity = bridge.identity;
    final newIdentity = await LocalIdentity.generate();

    client.send([cmdExportPrivateKey]);
    final exported = await client.frames.next();
    expect(exported[0], respCodePrivateKey);
    expect(exported.sublist(1), oldIdentity.meshcore64);

    client.send([cmdSignStart]);
    expect((await client.frames.next())[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('old signing data')]);
    expect((await client.frames.next())[0], respCodeOk);

    client.send([
      cmdImportPrivateKey,
      ...newIdentity.meshcore64,
      0xAA,
      0xBB, // documented trailing bytes are ignored
    ]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.identity.publicKey, newIdentity.publicKey);
    expect(bridge.identityImports, 1);

    // The previous client's partial sign buffer must not survive the switch.
    client.send([cmdSignFinish]);
    final signature = await client.frames.next();
    expect(signature[0], respCodeSignature);
    expect(
      await LocalIdentity.verify(
        Uint8List(0),
        signature.sublist(1),
        newIdentity.publicKey,
      ),
      isTrue,
    );

    client.send([cmdAppStart, 0, 0, 0, 0, 0, 0, 0]);
    final info = await client.frames.next();
    expect(info.sublist(4, 36), newIdentity.publicKey);

    client.send([cmdExportPrivateKey]);
    final reExported = await client.frames.next();
    expect(reExported.sublist(1), newIdentity.meshcore64);
  });

  test('storage_failure_keeps_old_active_key_and_returns_err5', () async {
    final oldIdentity = bridge.identity;
    final replacement = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 45);
    bridge.identitySaveError = const FileSystemException('write failed');

    client.send([cmdImportPrivateKey, ...replacement.meshcore64]);
    expect(await client.frames.next(), [respCodeErr, errCodeFileIoError]);
    expect(bridge.identity.publicKey, oldIdentity.publicKey);
    expect(bridge.identityImports, 0);

    client.send([cmdExportPrivateKey]);
    final exported = await client.frames.next();
    expect(exported.sublist(1), oldIdentity.meshcore64);
  });

  test('network_import_rejects_short32_prefix00_ff_and_ecdh_invalid_keys',
      () async {
    final oldIdentity = bridge.identity;
    final prefix00 = hexToBytes(
        '904bfc6464fab00f290b0af4281c582995b553cd3183ce295323d62dfacc325af95f5f99de94f6f17e62634498d53c2d0d13c5f39425ce0b298e4cb9a150db7f');
    final prefixFf = hexToBytes(
        '7072e90de6cbc83fc7f634fc9d16f9fbd44a7533fdbd6740edcc4700cd840d795ccb1c02d93bc82cad1bce56544aeeab3ef722891547abe282498e6f452c241d');
    final invalidEcdh = hexToBytes(
        '0137dddb67ad806e5073c8ee561af2980cf721dbde3f7ace16729d4e8fb2613a5ed63e9c3f6ff001ffdd8f93dc4772cb3a5994a23c00184cc1aea33e4ff8b936');
    final badKeys = <Uint8List>[
      prefix00,
      prefixFf,
      invalidEcdh,
    ];
    for (final key in badKeys) {
      client.send([cmdImportPrivateKey, ...key]);
      final response = await client.frames.next();
      expect(response, [respCodeErr, errCodeIllegalArg]);
      expect(bridge.identity.publicKey, oldIdentity.publicKey);
      expect(bridge.identityImports, 0);
    }

    client.send([cmdImportPrivateKey, ...Uint8List(32)]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    expect(bridge.identity.publicKey, oldIdentity.publicKey);
    expect(bridge.identityImports, 0);
  });

  test('SET_FLOOD_SCOPE stores, resets, and forces unscoped', () async {
    final key = Uint8List.fromList(List.generate(16, (i) => i + 1));
    client.send([cmdSetFloodScope, 0, ...key]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.floodScopeKey, key);
    expect(bridge.floodUnscoped, isFalse);

    client.send([cmdSetFloodScope, 0]); // reset override
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.floodScopeKey, isNull);

    client.send([cmdSetFloodScope, 1]); // force unscoped (fw v12+)
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.floodUnscoped, isTrue);
  });

  test('SET/GET_DEFAULT_FLOOD_SCOPE round trips and clears', () async {
    final key = Uint8List.fromList(List.generate(16, (i) => (i * 5) % 256));
    final w = BufferWriter()
      ..writeByte(cmdSetDefaultFloodScope)
      ..writeCString('RegionOne', 31)
      ..writeBytes(key);
    client.send(w.toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.defaultScopeName, 'RegionOne');
    expect(bridge.defaultScopeKey, key);

    client.send([cmdGetDefaultFloodScope]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeDefaultFloodScope);
    // Name occupies a fixed 31-byte, NUL-padded field, then the 16-byte key.
    expect(resp.sublist(1, 1 + 31).indexOf(0), 'RegionOne'.length);
    expect(resp.sublist(1 + 31, 1 + 31 + 16), key);

    client.send([cmdSetDefaultFloodScope]); // clear
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetDefaultFloodScope]);
    expect(await client.frames.next(), [respCodeDefaultFloodScope]);
  });

  test('REBOOT accepts the "reboot" magic and calls the bridge', () async {
    client.send([cmdReboot, ...'reboot'.codeUnits]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.reboots, 1);

    client.send([cmdReboot, ...'nope'.codeUnits]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeErr);
    expect(resp[1], errCodeUnsupportedCmd);
    expect(bridge.reboots, 1);

    client.send([cmdReboot, ...'reboo'.codeUnits]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdReboot, ...'rebootx'.codeUnits]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.reboots, 2);
  });

  test('SEND_ANON_REQ returns SENT and forwards to the bridge', () async {
    final pubkey = identity.publicKey;
    client.send([cmdSendAnonReq, ...pubkey, 1, 0, 7]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeSent);
    expect(bridge.anonPubkey, pubkey);
    expect(bridge.anonData, [1, 0, 7]);
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x4242);
  });

  test('pushBinaryResponse emits reserved + tag + payload', () async {
    bridge.pushSink!.pushBinaryResponse(0x11223344, Uint8List.fromList([9, 8]));
    final resp = await client.frames.next();
    expect(resp[0], pushCodeBinaryResponse);
    expect(resp[1], 0); // reserved
    final r = BufferReader(resp)..skipBytes(2);
    expect(r.readUInt32Le(), 0x11223344);
    expect(r.readRemainingBytes(), [9, 8]);
  });

  test('pushSendConfirmed includes the firmware trip time', () async {
    bridge.pushSink!.pushSendConfirmed(0x11223344, tripTimeMs: 1234);
    final resp = await client.frames.next();
    expect(resp, hasLength(9));
    expect(resp[0], pushCodeSendConfirmed);
    final r = BufferReader(resp)..skipBytes(1);
    expect(r.readUInt32Le(), 0x11223344);
    expect(r.readUInt32Le(), 1234);
  });

  test('EXPORT_CONTACT returns the advert blob', () async {
    bridge.contactBlob = Uint8List.fromList([0x04, 1, 2, 3]);
    client.send([cmdExportContact]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeExportContact);
    expect(resp.sublist(1), [0x04, 1, 2, 3]);
    expect(bridge.exportedFor, isNull);

    final pubkey = identity.publicKey;
    client.send([cmdExportContact, ...pubkey]);
    await client.frames.next();
    expect(bridge.exportedFor, pubkey);

    bridge.contactBlob = null;
    client.send([cmdExportContact, ...pubkey]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeNotFound);
  });

  test('IMPORT_CONTACT forwards the blob', () async {
    final blob = List<int>.filled(98, 0)..[0] = 0x04;
    client.send([cmdImportContact, ...blob]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.importedData, blob);
  });

  test('SHARE_CONTACT forwards the pubkey', () async {
    final pubkey = identity.publicKey;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'self'));
    client.send([cmdShareContact, ...pubkey]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.sharedPubkey, pubkey);

    client.send([cmdShareContact, 1, 2, 3]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);
  });

  test('GET_ALLOWED_REPEAT_FREQ returns the bridge ranges', () async {
    bridge.allowedRepeatFreq =
        Uint8List.fromList([0x40, 0x42, 0x0F, 0x00, 0, 0, 0, 0]);
    client.send([cmdGetAllowedRepeatFreq]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeAllowedRepeatFreq);
    expect(resp.sublist(1), bridge.allowedRepeatFreq);
  });

  test('SEND_RAW_DATA forwards the path and payload', () async {
    // path_len 0x02 => 1-byte hashes, 2 hops, then 2 path bytes, 4-byte payload.
    client.send([cmdSendRawData, 0x02, 0xAA, 0xBB, 1, 2, 3, 4]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.rawPathLenByte, 0x02);
    expect(bridge.rawPath, [0xAA, 0xBB]);
    expect(bridge.rawPayload, [1, 2, 3, 4]);

    // Too-short payload is rejected.
    client.send([cmdSendRawData, 0x00, 1, 2]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeUnsupportedCmd);

    // Reserved hash width (hash_size == 4) is unsupported.
    client.send([cmdSendRawData, 0xC0, 1, 2, 3, 4]);
    final err2 = await client.frames.next();
    expect(err2[0], respCodeErr);
    expect(err2[1], errCodeUnsupportedCmd);
  });

  test('SEND_RAW_PACKET parses and forwards the packet verbatim', () async {
    final packet = Packet()
      ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
      ..payload = Uint8List.fromList([1, 2, 3, 4]);
    packet.setPath([0xAA, 0xBB]);

    client.send([cmdSendRawPacket, 7, ...packet.writeTo()]);
    expect((await client.frames.next())[0], respCodeOk);
    expect(bridge.rawPriority, 7);
    expect(bridge.rawPacket!.writeTo(), packet.writeTo());

    // Malformed packet bytes are rejected.
    client.send([cmdSendRawPacket, 0, 0xFF, 0xFF]);
    final err = await client.frames.next();
    expect(err[0], respCodeErr);
    expect(err[1], errCodeIllegalArg);
  });

  test('self telemetry returns PUSH_CODE_TELEMETRY_RESPONSE', () async {
    client.send([cmdSendTelemetryReq, 0, 0, 0]);
    final resp = await client.frames.next();
    expect(resp[0], pushCodeTelemetryResponse);
    expect(resp.sublist(2, 8), identity.publicKey.sublist(0, 6));
    expect(resp[8], telemChannelSelf); // CayenneLPP self channel
    expect(resp[9], 0x74); // voltage
  });

  test('RUN_CLI_COMMAND uses a CLI_REPLY text even for unsupported', () async {
    bridge.cliReply = null;
    client.send([cmdRunCliCommand, ...utf8Bytes('ver')]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCliReply);
    expect(utf8.decode(resp.sublist(1)), 'Unknown command');
  });

  test('R2 autoadd vectors clamp and preserve max hops', () async {
    client.send([cmdSetAutoAddConfig, 0x06, 0x02]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdGetAutoAddConfig]);
    expect(await client.frames.next(), [respCodeAutoAddConfig, 0x06, 0x02]);

    client.send([cmdSetAutoAddConfig, 0x10]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdGetAutoAddConfig]);
    expect(await client.frames.next(), [respCodeAutoAddConfig, 0x10, 0x02]);

    client.send([cmdSetAutoAddConfig, 0x02, 0xFF]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdGetAutoAddConfig]);
    expect(await client.frames.next(), [respCodeAutoAddConfig, 0x02, 0x40]);
  });

  test('other_params_preserve_all_omitted_fields_and_pack_telemetry', () async {
    client.send([cmdSetOtherParams, 0x01, 0x26, 0x01, 0x02]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.selfInfo.manualAddContacts, 1);
    expect(bridge.selfInfo.telemetryModes, 0x26);
    expect(bridge.selfInfo.advertLocPolicy, 1);
    expect(bridge.selfInfo.multiAcks, 2);

    // Only manual_add is supplied: everything else is preserved.
    client.send([cmdSetOtherParams, 0x00]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.selfInfo.manualAddContacts, 0);
    expect(bridge.selfInfo.telemetryModes, 0x26);
    expect(bridge.selfInfo.advertLocPolicy, 1);
    expect(bridge.selfInfo.multiAcks, 2);

    client.send([cmdSetOtherParams, 0x01, 0x26, 0x01, 0x02]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdAppStart, 0, 0, 0, 0, 0, 0, 0]);
    final self = await client.frames.next();
    expect(self[0], respCodeSelfInfo);
    expect(self[44], 2); // multiAcks
    expect(self[45], 1); // advert location policy
    expect(self[46], 0x26); // packed telemetry
    expect(self[47], 1); // manual add
  });

  test('names_utf8_byte_limit_and_coordinate_ranges', () async {
    // 31 UTF-8 bytes is accepted; 32 is truncated to 31 like stock firmware.
    client.send([cmdSetAdvertName, ...utf8Bytes('a' * 31)]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdSetAdvertName, ...utf8Bytes('a' * 32)]);
    expect(await client.frames.next(), [respCodeOk]);

    // A single trailing NUL is accepted; embedded NUL ends the name.
    client.send([cmdSetAdvertName, ...utf8Bytes('café'), 0]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdSetAdvertName, ...utf8Bytes('ab'), 0, ...utf8Bytes('cd')]);
    expect(await client.frames.next(), [respCodeOk]);
    client.send([cmdSetAdvertName, ...utf8Bytes('bad\nname')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    client.send([cmdSetAdvertName, 0xFF]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdSetAdvertName, ...utf8Bytes('café')]);
    expect(await client.frames.next(), [respCodeOk]);

    client.send([cmdAppStart, 0, 0, 0, 0, 0, 0, 0]);
    final self = await client.frames.next();
    expect(self.sublist(58), utf8Bytes('café'));

    client.send((BufferWriter()
          ..writeByte(cmdSetAdvertLatLon)
          ..writeInt32Le(90000000)
          ..writeInt32Le(-180000000))
        .toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.selfInfo.latitude, 90.0);
    expect(bridge.selfInfo.longitude, -180.0);

    client.send((BufferWriter()
          ..writeByte(cmdSetAdvertLatLon)
          ..writeInt32Le(90000001)
          ..writeInt32Le(0))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    client.send((BufferWriter()
          ..writeByte(cmdSetAdvertLatLon)
          ..writeInt32Le(0)
          ..writeInt32Le(-180000001))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('ADD_UPDATE_CONTACT validates wire path/name/coordinates', () async {
    final key = Uint8List(32)..[0] = 9;
    Uint8List body({int pathLen = 0, Uint8List? name, int? latMicros}) {
      final w = BufferWriter()
        ..writeBytes(key)
        ..writeByte(advTypeChat)
        ..writeByte(0)
        ..writeByte(pathLen);
      w.writeBytes(Uint8List(64)); // fixed path field
      w.writeBytes(name ?? Uint8List(32)); // fixed name field
      w.writeUInt32Le(0); // last_advert
      if (latMicros != null) {
        w
          ..writeInt32Le(latMicros)
          ..writeInt32Le(0);
      }
      return w.toBytes();
    }

    client.send([cmdAddUpdateContact, ...body()]);
    expect(await client.frames.next(), [respCodeOk]);

    client.send([cmdAddUpdateContact, ...body(pathLen: 0x7F)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    final tooLongName = Uint8List.fromList(List.filled(32, 'a'.codeUnitAt(0)));
    client.send([cmdAddUpdateContact, ...body(name: tooLongName)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdAddUpdateContact, ...body(latMicros: 90000001)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('default_advert_is_zero_hop_explicit1_is_flood', () async {
    client.send([cmdSendSelfAdvert]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.advertisedFlood, isFalse);

    client.send([cmdSendSelfAdvert, 0]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.advertisedFlood, isFalse);

    client.send([cmdSendSelfAdvert, 1]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.advertisedFlood, isTrue);
  });

  test('contact push layouts are byte exact', () async {
    final key = Uint8List(32)..[0] = 7;
    server.pushContactDeleted(key);
    expect(await client.frames.next(), [pushCodeContactDeleted, ...key]);

    server.pushContactsFull();
    expect(await client.frames.next(), [pushCodeContactsFull]);

    final body = Uint8List(147);
    server.pushNewAdvert(body);
    final frame = await client.frames.next();
    expect(frame, hasLength(148));
    expect(frame[0], pushCodeNewAdvert);
    expect(frame.sublist(1), body);
  });

  test('R2 virtual time rejects backward and accepts forward', () async {
    bridge.currentTime = 100;
    client.send((BufferWriter()
          ..writeByte(cmdSetDeviceTime)
          ..writeUInt32Le(99))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.currentTime, 100);

    client.send((BufferWriter()
          ..writeByte(cmdSetDeviceTime)
          ..writeUInt32Le(101))
        .toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.currentTime, 101);

    client.send([cmdGetDeviceTime]);
    expect(await client.frames.next(), [respCodeCurrTime, 101, 0, 0, 0]);
  });

  test('default custom settings empty and unknown SET returns ERR6', () async {
    client.send([cmdGetCustomVars]);
    expect(await client.frames.next(), [respCodeCustomVars]);

    client.send([cmdSetCustomVar, ...utf8Bytes('gps:1')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(bridge.customVars, isEmpty);
  });

  test('SET/GET_CUSTOM_VAR round-trips for a provider-supported key', () async {
    bridge.supportedCustomKeys.add('region');
    client.send([cmdSetCustomVar, ...utf8Bytes('region:us')]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetCustomVars]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCustomVars);
    expect(String.fromCharCodes(resp.sublist(1)), 'region:us');
    bridge.supportedCustomKeys.clear();
    bridge.customVars.clear();
  });

  test('a full meshcore-open-style session stays framed and ordered', () async {
    final pubkey = identity.publicKey;
    final peerKey = Uint8List(32)..[0] = 9;
    bridge.contacts.add(Contact(
      publicKey: peerKey,
      name: 'peer',
      advType: advTypeChat,
      lastmod: 100,
    ));
    bridge.contactBlob = Uint8List.fromList([0x04, 0xAA, 0xBB, 0xCC]);

    // Handshake / info block.
    client.send([cmdDeviceQuery, appProtocolVersion]);
    expect((await client.frames.next())[0], respCodeDeviceInfo);

    client.send([cmdAppStart, 0, 0, 0, 0, 0, 0, 0]);
    expect((await client.frames.next())[0], respCodeSelfInfo);

    client.send([cmdGetBattAndStorage]);
    expect((await client.frames.next())[0], respCodeBattAndStorage);

    client.send([cmdGetCustomVars]);
    expect((await client.frames.next())[0], respCodeCustomVars);

    client.send([cmdGetAutoAddConfig]);
    expect((await client.frames.next())[0], respCodeAutoAddConfig);

    client.send([cmdGetContacts, 0, 0, 0, 0]);
    expect((await client.frames.next())[0], respCodeContactsStart);
    expect((await client.frames.next())[0], respCodeContact);
    expect((await client.frames.next())[0], respCodeEndOfContacts);

    // Channel setup round-trips on the same connection.
    final psk = Uint8List.fromList(List.generate(16, (i) => i));
    client.send((BufferWriter()
          ..writeByte(cmdSetChannel)
          ..writeByte(1)
          ..writeCString('general', 32)
          ..writeBytes(psk))
        .toBytes());
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdGetChannel, 1]);
    final chan = await client.frames.next();
    expect(chan[0], respCodeChannelInfo);
    expect(chan.sublist(34, 50), psk);

    // Device time + radio params.
    client.send([cmdGetDeviceTime]);
    expect((await client.frames.next())[0], respCodeCurrTime);

    client.send((BufferWriter()
          ..writeByte(cmdSetRadioParams)
          ..writeUInt32Le(915000) // kHz on the wire
          ..writeUInt32Le(250000)
          ..writeByte(10)
          ..writeByte(5))
        .toBytes());
    expect((await client.frames.next())[0], respCodeOk);

    // Regulatory ranges.
    bridge.allowedRepeatFreq = Uint8List.fromList([0x40, 0x42, 0x0F, 0x00]);
    client.send([cmdGetAllowedRepeatFreq]);
    final freq = await client.frames.next();
    expect(freq[0], respCodeAllowedRepeatFreq);
    expect(freq.sublist(1), bridge.allowedRepeatFreq);

    // Contact sharing.
    client.send([cmdShareContact, ...peerKey]);
    expect((await client.frames.next())[0], respCodeOk);

    client.send([cmdExportContact, ...peerKey]);
    final exported = await client.frames.next();
    expect(exported[0], respCodeExportContact);
    expect(exported.sublist(1), bridge.contactBlob);

    client.send([cmdImportContact, ...List<int>.filled(98, 0)..[0] = 0x04]);
    expect((await client.frames.next())[0], respCodeOk);

    // Binary request: SENT now, the reply follows asynchronously by tag.
    client.send([cmdSendBinaryReq, ...peerKey, reqTypeGetStatus]);
    final sent = await client.frames.next();
    expect(sent[0], respCodeSent);
    final binTag = (BufferReader(sent)..skipBytes(2)).readUInt32Le();
    expect(binTag, 0x5151);
    expect(bridge.binData, [reqTypeGetStatus]);

    bridge.pushSink!.pushBinaryResponse(binTag, Uint8List.fromList([7, 8]));
    final push = await client.frames.next();
    expect(push[0], pushCodeBinaryResponse);
    final pr = BufferReader(push)..skipBytes(2);
    expect(pr.readUInt32Le(), binTag);
    expect(pr.readRemainingBytes(), [7, 8]);

    // Anonymous request: SENT only.
    client.send([cmdSendAnonReq, ...pubkey, 1, 0]);
    final anon = await client.frames.next();
    expect(anon[0], respCodeSent);
    expect((BufferReader(anon)..skipBytes(2)).readUInt32Le(), 0x4242);

    // Raw data + raw packet.
    client.send([cmdSendRawData, 0x00, 1, 2, 3, 4]);
    expect((await client.frames.next())[0], respCodeOk);

    final raw = (Packet()
          ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
          ..payload = Uint8List.fromList([1, 2, 3, 4]))
        .writeTo();
    client.send([cmdSendRawPacket, 0, ...raw]);
    expect((await client.frames.next())[0], respCodeOk);

    // Messaging: a direct text send is acknowledged SENT.
    client.send((BufferWriter()
          ..writeByte(cmdSendTxtMsg)
          ..writeByte(txtTypePlain)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeBytes(peerKey.sublist(0, 6))
          ..writeString('hi')
          ..writeByte(0))
        .toBytes());
    expect((await client.frames.next())[0], respCodeSent);

    // Empty message queue.
    client.send([cmdSyncNextMessage]);
    expect((await client.frames.next())[0], respCodeNoMoreMessages);

    // Path discovery is acknowledged SENT.
    client.send([cmdSendPathDiscoveryReq, 0, ...peerKey]);
    expect((await client.frames.next())[0], respCodeSent);

    // Signing handshake returns a 64-byte signature.
    client.send([cmdSignStart]);
    expect((await client.frames.next())[0], respCodeSignStart);
    client.send([cmdSignData, ...utf8Bytes('hello')]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdSignFinish]);
    final sig = await client.frames.next();
    expect(sig[0], respCodeSignature);
    expect(sig.length, 65);
  });

  test('GET_CHANNEL returns all channels, one index, or not-found', () async {
    final psk = Uint8List.fromList(List.generate(32, (i) => i));
    bridge.channels[0] = Channel(name: 'Public', secret: psk);
    bridge.channels[2] = Channel(name: 'Extra', secret: Uint8List(2));

    for (var i = 0; i < 8; i++) {
      client.send([cmdGetChannel, i]);
      final frame = await client.frames.next();
      expect(frame[0], respCodeChannelInfo);
      expect(frame[1], i);
      if (i == 0) {
        expect(frame.sublist(2, 8), utf8Bytes('Public'));
        // A 32-byte channel secret is clamped to the 16-byte wire field.
        expect(frame.sublist(34, 50), psk.sublist(0, 16));
      } else if (i == 2) {
        expect(frame.sublist(34, 50),
            [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
      } else {
        expect(frame.sublist(2, 34), everyElement(0));
        expect(frame.sublist(34, 50), everyElement(0));
      }
    }

    client.send([cmdGetChannel, 8]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);
  });

  test('SET_CHANNEL accepts 16-byte secrets and rejects 32-byte and truncation',
      () async {
    final psk16 = Uint8List.fromList(List.generate(16, (i) => i + 1));
    final psk32 = Uint8List.fromList(List.generate(32, (i) => i + 1));

    client.send((BufferWriter()
          ..writeByte(cmdSetChannel)
          ..writeByte(4)
          ..writeCString('short', 32)
          ..writeBytes(psk16))
        .toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.channels[4]!.name, 'short');
    expect(bridge.channels[4]!.secret, psk16);

    // A full 32-byte, non-NUL name is clamped to 31 bytes like stock strncpy.
    client.send((BufferWriter()
          ..writeByte(cmdSetChannel)
          ..writeByte(8)
          ..writeBytes(utf8.encode('n' * 32))
          ..writeBytes(psk16))
        .toBytes());
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.channels[8]!.name, 'n' * 31);

    // Stock 1.18 firmware rejects the unsupported 32-byte variant.
    client.send((BufferWriter()
          ..writeByte(cmdSetChannel)
          ..writeByte(5)
          ..writeCString('long', 32)
          ..writeBytes(psk32))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    expect(bridge.channels[5], isNull);

    client.send((BufferWriter()
          ..writeByte(cmdSetChannel)
          ..writeByte(6)
          ..writeCString('bad', 32)
          ..writeBytes(Uint8List(15)))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdSetChannel, 0, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    bridge.setChannelError = const CompanionOperationError(errCodeFileIoError);
    client.send((BufferWriter()
          ..writeByte(cmdSetChannel)
          ..writeByte(7)
          ..writeCString('err', 32)
          ..writeBytes(psk16))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeFileIoError]);
  });

  test('SEND_CHANNEL_TXT_MSG validates type, channel, and send result',
      () async {
    bridge.channels[0] = Channel(name: 'Public', secret: Uint8List(16));

    client.send([cmdSendChannelTxtMsg, txtTypePlain, 0, 0, 0, 0]);
    // Too short (only 5 data bytes).
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send((BufferWriter()
          ..writeByte(cmdSendChannelTxtMsg)
          ..writeByte(txtTypeSigned)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeCString('hi', 3))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send((BufferWriter()
          ..writeByte(cmdSendChannelTxtMsg)
          ..writeByte(txtTypePlain)
          ..writeByte(9)
          ..writeUInt32Le(0)
          ..writeCString('hi', 3))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    bridge.channelMessageResult = false;
    client.send((BufferWriter()
          ..writeByte(cmdSendChannelTxtMsg)
          ..writeByte(txtTypePlain)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeCString('hi', 3))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);
    expect(
      serverLogs.any((line) => line.contains('channel message send failed')),
      isTrue,
    );
  });

  test('SEND_TXT_MSG validates length and reports contact/send failures',
      () async {
    final pubkey = Uint8List(32)..[0] = 7;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));

    client.send([cmdSendTxtMsg, 0, 0, 0, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send((BufferWriter()
          ..writeByte(cmdSendTxtMsg)
          ..writeByte(txtTypePlain)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeBytes(Uint8List(6)..fillRange(0, 6, 0x55))
          ..writeCString('hi', 3))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    // Stock firmware only accepts plain and CLI direct text types; a signed
    // direct send is receive-only and must be rejected.
    bridge.sentText = null;
    client.send((BufferWriter()
          ..writeByte(cmdSendTxtMsg)
          ..writeByte(txtTypeSigned)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeBytes(pubkey.sublist(0, 6))
          ..writeCString('hi', 3))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    expect(bridge.sentText, isNull);

    bridge.sentTextResult = const SentResult.failure();
    client.send((BufferWriter()
          ..writeByte(cmdSendTxtMsg)
          ..writeByte(txtTypePlain)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeBytes(pubkey.sublist(0, 6))
          ..writeCString('hi', 3))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    // Flood sends with null optional fields fall back to the wire defaults.
    bridge.sentTextResult = const SentResult(success: true, isFlood: true);
    client.send((BufferWriter()
          ..writeByte(cmdSendTxtMsg)
          ..writeByte(txtTypePlain)
          ..writeByte(0)
          ..writeUInt32Le(0)
          ..writeBytes(pubkey.sublist(0, 6))
          ..writeCString('hi', 3))
        .toBytes());
    final sent = await client.frames.next();
    expect(sent[0], respCodeSent);
    expect(sent[1], 1);
    final r = BufferReader(sent)..skipBytes(2);
    expect(r.readUInt32Le(), 0);
    expect(r.readUInt32Le(), 5000);
  });

  test('SEND_CHANNEL_DATA validates paths, payload size, and send result',
      () async {
    bridge.channels[0] = Channel(name: 'Public', secret: Uint8List(16));
    final payload = [1, 2, 3, 4];

    client.send([cmdSendChannelData, 0, 0, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    // Reserved path hash width.
    client.send([cmdSendChannelData, 0, 0xC0, 1, 1, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    // Declared path bytes are missing.
    client.send([cmdSendChannelData, 0, 2, 0xAA, 0xBB]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    // No data type field left.
    client.send([cmdSendChannelData, 0, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    // Reserved data type.
    client.send([cmdSendChannelData, 0, 0, 0, 0, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    // Stock checks the channel first, so an unknown channel with a reserved
    // data type still reports not-found.
    client.send([cmdSendChannelData, 7, 0, 0, 0, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    // Payload beyond the group-data limit.
    client.send([cmdSendChannelData, 0, 0, 1, 0, ...List.filled(158, 1)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    bridge.channels[0] = Channel(name: 'Public', secret: Uint8List(16));
    bridge.channelDataResult = false;
    client.send([cmdSendChannelData, 0, 0, 1, 0, ...payload]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    bridge.channels.remove(0);
    client.send([cmdSendChannelData, 0, 0, 1, 0, ...payload]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    bridge.channels[0] = Channel(name: 'Public', secret: Uint8List(16));
    bridge.channelDataResult = true;
    client.send([cmdSendChannelData, 0, 2, 0xAA, 0xBB, 1, 0, ...payload]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.sentChannelDataPath, [0xAA, 0xBB]);
    expect(bridge.sentChannelDataPathLen, 2);
    expect(bridge.sentChannelDataType, 1);
    expect(bridge.sentChannelDataPayload, payload);
  });

  test('SEND_CONTROL_DATA requires the control marker', () async {
    client.send([cmdSendControlData]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdSendControlData, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdSendControlData, 0x80, 1, 2]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.controlData, [0x80, 1, 2]);

    bridge.controlDataResult = false;
    client.send([cmdSendControlData, 0x80]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
  });

  test('SYNC_NEXT_MESSAGE covers V3 data, legacy layouts, and errors',
      () async {
    bridge.nextMessage = QueuedMessage(
      senderKey: Uint8List(32),
      isChannel: true,
      channelIdx: 2,
      pathLen: 300,
      isChannelData: true,
      channelDataType: 0x1234,
      channelDataPayload: Uint8List.fromList(List.filled(200, 0xAB)),
    );
    client.send([cmdSyncNextMessage]);
    final data = await client.frames.next();
    expect(data[0], respCodeChannelDataRecv);
    expect(data.length, channelDataRxHeaderSize + maxChannelDataLength);
    expect(data[4], 2);
    expect(data[5], 0xFF); // path length > 255 clamps to 0xFF
    expect(data.sublist(6, 8), [0x34, 0x12]);
    expect(data[8], maxChannelDataLength);

    // Legacy (pre-V3) channel text layout.
    bridge.nextMessage = QueuedMessage(
      senderKey: Uint8List(32),
      isChannel: true,
      channelIdx: 1,
      pathLen: 2,
      timestamp: 0x11223344,
      text: 'hello',
    );
    client.send([cmdSyncNextMessage]);
    final channel = await client.frames.next();
    expect(channel[0], respCodeChannelMsgRecv);
    expect(channel.sublist(1, 5), [1, 2, txtTypePlain, 0x44]);

    // Legacy direct text pads a short sender key to six bytes.
    bridge.nextMessage = QueuedMessage(
      senderKey: Uint8List.fromList([1, 2, 3]),
      timestamp: 0x11223344,
      text: 'hi',
    );
    client.send([cmdSyncNextMessage]);
    final direct = await client.frames.next();
    expect(direct[0], respCodeContactMsgRecv);
    expect(direct.sublist(1, 7), [1, 2, 3, 0, 0, 0]);
    expect(direct[7], 0);
    expect(direct.sublist(9, 13), [0x44, 0x33, 0x22, 0x11]);

    // V3 direct text with a short sender key.
    client.send([cmdDeviceQuery, 3]);
    await client.frames.next();
    bridge.nextMessage = QueuedMessage(
      senderKey: Uint8List.fromList([1, 2]),
      timestamp: 1,
      text: 'x',
    );
    client.send([cmdSyncNextMessage]);
    final v3 = await client.frames.next();
    expect(v3[0], respCodeContactMsgRecvV3);
    expect(v3.sublist(4, 10), [1, 2, 0, 0, 0, 0]);

    bridge.syncNextError = const CompanionOperationError(errCodeTableFull);
    client.send([cmdSyncNextMessage]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
  });

  test('SIGN_DATA bounds and SIGN_FINISH errors', () async {
    client.send([cmdSignData]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdSignStart]);
    await client.frames.next();
    // Fill the 8 KiB signing buffer in frame-sized chunks.
    var sent = 0;
    while (sent + 175 <= 8 * 1024) {
      client.send([cmdSignData, ...List.filled(175, 0x61)]);
      expect((await client.frames.next())[0], respCodeOk);
      sent += 175;
    }
    final remaining = 8 * 1024 - sent;
    client.send([cmdSignData, ...List.filled(remaining, 0x61)]);
    expect((await client.frames.next())[0], respCodeOk);
    client.send([cmdSignData, 0x61]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    client.send([cmdSignStart]);
    await client.frames.next();
    bridge.signError = StateError('signer unavailable');
    client.send([cmdSignFinish]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
  });

  test('RUN_CLI_COMMAND clears a partial signing buffer on lifecycle change',
      () async {
    client.send([cmdSignStart]);
    await client.frames.next();
    client.send([cmdSignData, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeOk]);

    bridge.cliReply = 'OK';
    bridge.cliLifecycleBump = 1;
    client.send([cmdRunCliCommand, ...utf8Bytes('reboot')]);
    expect((await client.frames.next())[0], respCodeCliReply);

    client.send([cmdSignFinish]);
    expect((await client.frames.next())[0], respCodeSignature);
    expect(bridge.lastSignedMessage, isEmpty);
  });

  test('private-key export validates the length and maps bridge errors',
      () async {
    bridge.exportKeyOverride = Uint8List(63);
    client.send([cmdExportPrivateKey]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);

    bridge.exportKeyOverride = null;
    bridge.exportKeyError = const CompanionOperationError(errCodeFileIoError);
    client.send([cmdExportPrivateKey]);
    expect(await client.frames.next(), [respCodeErr, errCodeFileIoError]);

    client.send([cmdImportPrivateKey, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
  });

  test('GET_STATS rejects unknown types and emits packet counters', () async {
    client.send([cmdGetStats, 99]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdGetStats]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdGetStats, statsTypePackets]);
    final stats = await client.frames.next();
    expect(stats[0], respCodeStats);
    expect(stats[1], statsTypePackets);
    expect(stats.length, 2 + 7 * 4);
    expect(stats.sublist(2), everyElement(0));
  });

  test('GET_ADVERT_PATH validates and frames the cached path', () async {
    final prefix = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);

    client.send([cmdGetAdvertPath, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdGetAdvertPath, 0, ...prefix, ...Uint8List(25)]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    bridge.advertPaths[bytesToHex(prefix)] = AdvertPath(
      publicKeyPrefix: prefix,
      pathLen: 2,
      path: Uint8List.fromList([0xAA, 0xBB, 0xCC]),
      recvTimestamp: 0x11223344,
    );
    client.send([cmdGetAdvertPath, 0, ...prefix, ...Uint8List(25)]);
    final frame = await client.frames.next();
    expect(frame[0], respCodeAdvertPath);
    final r = BufferReader(frame)..skipBytes(1);
    expect(r.readUInt32Le(), 0x11223344);
    expect(r.readByte(), 2);
    expect(r.readBytes(2), [0xAA, 0xBB]);
    expect(r.remaining, 0);
  });

  test('EXPORT/IMPORT/SHARE_CONTACT cover failure results', () async {
    client.send([cmdImportContact]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    bridge.importContactResult = false;
    client.send([cmdImportContact, ...List<int>.filled(98, 0)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    bridge.shareContactResult = false;
    client.send([cmdShareContact, ...Uint8List(32)]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);
  });

  test('binary and anonymous requests report not-found on failure', () async {
    final pubkey = Uint8List(32)..[0] = 7;

    client.send([cmdSendBinaryReq, ...pubkey.sublist(0, 3)]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));
    bridge.binaryResult = const SentResult.failure();
    client.send([cmdSendBinaryReq, ...pubkey, 1]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    final unknown = Uint8List(32)..[0] = 8;
    client.send([cmdSendBinaryReq, ...unknown, 1]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    client.send([cmdSendAnonReq, ...pubkey]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    bridge.anonResult = const SentResult.failure();
    client.send([cmdSendAnonReq, ...pubkey, 1]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
  });

  test('telemetry requests validate length and report not-found', () async {
    client.send([cmdSendTelemetryReq, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    final pubkey = Uint8List(32)..[0] = 7;
    client.send([cmdSendTelemetryReq, 0, 0, 0, ...pubkey.sublist(0, 31)]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    bridge.telemetryResult = const SentResult.failure();
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));
    client.send([cmdSendTelemetryReq, 0, 0, 0, ...pubkey]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    final unknown = Uint8List(32)..[0] = 8;
    client.send([cmdSendTelemetryReq, 0, 0, 0, ...unknown]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);
  });

  test('path discovery validates the index and reports not-found', () async {
    final pubkey = Uint8List(32)..[0] = 7;

    client.send([cmdSendPathDiscoveryReq, 0, ...pubkey.sublist(0, 3)]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    client.send([cmdSendPathDiscoveryReq, 1, ...pubkey]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    bridge.pathDiscoveryResult = const SentResult.failure();
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));
    client.send([cmdSendPathDiscoveryReq, 0, ...pubkey]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    final unknown = Uint8List(32)..[0] = 8;
    client.send([cmdSendPathDiscoveryReq, 0, ...unknown]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    bridge.pathDiscoveryResult = const SentResult(success: true);
    client.send([cmdSendPathDiscoveryReq, 0, ...pubkey]);
    final sent = await client.frames.next();
    expect(sent[0], respCodeSent);
    expect((BufferReader(sent)..skipBytes(2)).readUInt32Le(), 0);
  });

  test('login, status, and logout validate and forward', () async {
    final pubkey = Uint8List(32)..[0] = 7;

    client.send([cmdSendLogin, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    client.send([cmdSendStatusReq, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    client.send([cmdLogout, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));
    client.send([cmdSendLogin, ...pubkey, ...utf8Bytes('secret'), 0, 9]);
    final login = await client.frames.next();
    expect(login[0], respCodeSent);
    expect(
      (BufferReader(login)..skipBytes(2)).readUInt32Le(),
      pubkey[0] | (pubkey[1] << 8) | (pubkey[2] << 16) | (pubkey[3] << 24),
    );
    expect(bridge.loginPassword, 'secret');

    client.send([cmdSendStatusReq, ...pubkey]);
    final status = await client.frames.next();
    expect(status[0], respCodeSent);
    expect(status[1], 1);
    expect((BufferReader(status)..skipBytes(2)).readUInt32Le(), 0x8888);

    bridge.loginResult = const SentResult.failure();
    client.send([cmdSendLogin, ...pubkey, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
    bridge.statusResult = const SentResult.failure();
    client.send([cmdSendStatusReq, ...pubkey]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    final unknown = Uint8List(32)..[0] = 8;
    client.send([cmdSendLogin, ...unknown, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);
    client.send([cmdSendStatusReq, ...unknown]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    client.send([cmdLogout, ...pubkey]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.logoutCount, 1);
  });

  test('RUN_CLI_COMMAND maps every bridge error kind', () async {
    final cases = <(CompanionOperationError, String)>[
      (
        const CompanionOperationError(errCodeUnsupportedCmd),
        'Error: unsupported'
      ),
      (const CompanionOperationError(errCodeNotFound), 'Error: unsupported'),
      (
        const CompanionOperationError(errCodeTableFull),
        'Error: storage failure'
      ),
      (
        const CompanionOperationError(errCodeBadState),
        'Error: device unavailable'
      ),
      (
        const CompanionOperationError(errCodeFileIoError),
        'Error: storage failure'
      ),
      (
        const CompanionOperationError(errCodeIllegalArg),
        'Error: illegal argument'
      ),
      (
        const CompanionOperationError(respCodeDisabled, disabled: true),
        'Error: disabled'
      ),
    ];
    for (final (error, expected) in cases) {
      bridge.cliError = error;
      bridge.cliGenericError = null;
      client.send([cmdRunCliCommand, ...utf8Bytes('ver')]);
      final reply = await client.frames.next();
      expect(reply[0], respCodeCliReply);
      expect(utf8.decode(reply.sublist(1)), expected);
    }

    bridge.cliError = null;
    bridge.cliGenericError = StateError('exploded');
    client.send([cmdRunCliCommand, ...utf8Bytes('ver')]);
    expect(
      utf8.decode((await client.frames.next()).sublist(1)),
      'Error: illegal argument',
    );
  });

  test('SET_CUSTOM_VAR validates encoding and maps operation errors', () async {
    client.send([cmdSetCustomVar, 0x61, 0x62]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    client.send([cmdSetCustomVar, 0xFF, 0xFF, 0xFF]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdSetCustomVar, ...utf8Bytes('nocolon')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdSetCustomVar, ...utf8Bytes(':value')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    bridge.customVarError = const CompanionOperationError(errCodeTableFull);
    client.send([cmdSetCustomVar, ...utf8Bytes('key:value')]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
  });

  test('GET_CUSTOM_VARS truncates the CSV to 140 bytes', () async {
    bridge.supportedCustomKeys.add('long');
    bridge.customVars['long'] = 'x' * 200;
    client.send([cmdGetCustomVars]);
    final resp = await client.frames.next();
    expect(resp[0], respCodeCustomVars);
    expect(resp.length, 1 + 140);
    expect(String.fromCharCodes(resp.sublist(1)), startsWith('long:xxx'));
  });

  test('SET_OTHER_PARAMS and SET_AUTO_ADD_CONFIG validate and map errors',
      () async {
    client.send([cmdSetOtherParams]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    bridge.otherParamsError = const CompanionOperationError(errCodeBadState);
    client.send([cmdSetOtherParams, 1]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);

    client.send([cmdSetAutoAddConfig]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    bridge.autoAddError = const CompanionOperationError(errCodeTableFull);
    client.send([cmdSetAutoAddConfig, 1]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
  });

  test('SET_RADIO_PARAMS rejects every out-of-range field', () async {
    Uint8List frame({
      int freq = 915000,
      int bw = 250000,
      int sf = 10,
      int cr = 5,
      List<int> suffix = const [],
    }) =>
        (BufferWriter()
              ..writeByte(cmdSetRadioParams)
              ..writeUInt32Le(freq)
              ..writeUInt32Le(bw)
              ..writeByte(sf)
              ..writeByte(cr)
              ..writeBytes(suffix))
            .toBytes();

    client.send([cmdSetRadioParams, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    for (final bad in [
      frame(freq: 149999),
      frame(freq: 2500001),
      frame(bw: 6999),
      frame(bw: 500001),
      frame(sf: 4),
      frame(sf: 13),
      frame(cr: 4),
      frame(cr: 9),
    ]) {
      client.send(bad);
      expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    }

    bridge.radioError =
        const CompanionOperationError(errCodeIllegalArg, message: 'rejected');
    client.send(frame());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('SET_RADIO_TX_POWER decodes signed bytes and maps errors', () async {
    client.send([cmdSetRadioTxPower]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdSetRadioTxPower, 0x80]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.txPower, -128);

    bridge.txError = const CompanionOperationError(errCodeBadState);
    client.send([cmdSetRadioTxPower, 10]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
  });

  test('SET_TUNING_PARAMS and SET_PATH_HASH_MODE validate and map errors',
      () async {
    client.send([cmdSetTuningParams, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    bridge.tuningError = const CompanionOperationError(errCodeBadState);
    client.send((BufferWriter()
          ..writeByte(cmdSetTuningParams)
          ..writeUInt32Le(1)
          ..writeUInt32Le(2))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);

    client.send([cmdSetPathHashMode, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
  });

  test('advert setters and the advert send map bridge failures', () async {
    bridge.advertNameError = const CompanionOperationError(errCodeIllegalArg);
    client.send([cmdSetAdvertName, ...utf8Bytes('name')]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    bridge.advertLatLonError = const CompanionOperationError(errCodeBadState);
    client.send((BufferWriter()
          ..writeByte(cmdSetAdvertLatLon)
          ..writeInt32Le(0)
          ..writeInt32Le(0))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);

    bridge.advertiseResult = false;
    client.send([cmdSendSelfAdvert]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
  });

  test('flood-scope commands validate their arguments', () async {
    client.send([cmdSetFloodScope]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    client.send([cmdSetFloodScope, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);

    // 31 non-NUL bytes cannot be a valid display name.
    client.send((BufferWriter()
          ..writeByte(cmdSetDefaultFloodScope)
          ..writeBytes(List.filled(31, 0x61))
          ..writeBytes(Uint8List(16)))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send((BufferWriter()
          ..writeByte(cmdSetDefaultFloodScope)
          ..writeBytes(Uint8List(31))
          ..writeBytes(Uint8List(16)))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    bridge.defaultFloodScopeError =
        const CompanionOperationError(errCodeFileIoError);
    client.send((BufferWriter()
          ..writeByte(cmdSetDefaultFloodScope)
          ..writeCString('Region', 31)
          ..writeBytes(Uint8List(16)))
        .toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeFileIoError]);

    bridge.defaultScopeName = 'Region';
    bridge.defaultScopeKey = null;
    client.send([cmdGetDefaultFloodScope]);
    expect(await client.frames.next(), [respCodeDefaultFloodScope]);
  });

  test('raw-data and raw-packet send failures map to table-full', () async {
    bridge.rawDataResult = false;
    client.send([cmdSendRawData, 0x00, 1, 2, 3, 4]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
    client.send([cmdSendRawData, 0x00, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    // A one-byte path leaves too little room for the required 4-byte payload.
    client.send([cmdSendRawData, 0x01, 0xAA, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    final raw = (Packet()
          ..header = Packet.createHeader(payloadTypeTxtMsg, routeTypeDirect)
          ..payload = Uint8List.fromList([1]))
        .writeTo();
    bridge.rawPacketResult = false;
    client.send([cmdSendRawPacket, 0, ...raw]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
    client.send([cmdSendRawPacket, 0, 1]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    // Enough length to dispatch, but the packet bytes are not a valid frame.
    client.send([cmdSendRawPacket, 0, 0x00, 0xC0]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
  });

  test('trace send failures map to table-full', () async {
    final w = BufferWriter()
      ..writeByte(cmdSendTracePath)
      ..writeUInt32Le(1)
      ..writeUInt32Le(2)
      ..writeByte(0)
      ..writeBytes([1, 2, 3]);
    bridge.traceResult = false;
    client.send(w.toBytes());
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);
  });

  test('GET_ALLOWED_REPEAT_FREQ maps bridge errors', () async {
    bridge.allowedRepeatFreqError =
        const CompanionOperationError(errCodeBadState);
    client.send([cmdGetAllowedRepeatFreq]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
  });

  test('idle timeout disconnects the client', () async {
    final idleBridge = TestBridge(await LocalIdentity.fromSeed(Uint8List(32)));
    final logs = <String>[];
    final scheduler = FakeScheduler();
    final idleServer = CompanionServer(
      bridge: idleBridge,
      config: const CompanionServerConfig(
        port: 0,
        clientIdleTimeout: Duration(milliseconds: 40),
      ),
      onLog: logs.add,
      timerFactory: scheduler.create,
    );
    await idleServer.start();
    final idleClient = FramedClient(
      await Socket.connect('127.0.0.1', idleServer.port!),
    );
    addTearDown(() async {
      await idleClient.close();
      await idleServer.stop();
    });

    while (!idleServer.hasClient) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    scheduler.elapse(const Duration(milliseconds: 39));
    expect(idleServer.hasClient, isTrue);

    scheduler.elapse(const Duration(milliseconds: 1));
    expect(idleServer.hasClient, isFalse);
    expect(logs.any((line) => line.contains('idle timeout')), isTrue);
  });

  test('heartbeat pushes CURR_TIME periodically', () async {
    final heartbeatBridge =
        TestBridge(await LocalIdentity.fromSeed(Uint8List(32)..[0] = 5));
    final scheduler = FakeScheduler();
    final heartbeatServer = CompanionServer(
      bridge: heartbeatBridge,
      config: const CompanionServerConfig(
        port: 0,
        heartbeatInterval: Duration(milliseconds: 30),
      ),
      periodicTimerFactory: scheduler.createPeriodic,
    );
    await heartbeatServer.start();
    final heartbeatClient = FramedClient(
      await Socket.connect('127.0.0.1', heartbeatServer.port!),
    );
    addTearDown(() async {
      await heartbeatClient.close();
      await heartbeatServer.stop();
    });

    while (!heartbeatServer.hasClient) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    scheduler.elapse(const Duration(milliseconds: 30));
    final frame = await heartbeatClient.frames.nextWithin(
      const Duration(seconds: 2),
    );
    expect(frame, isNotNull);
    expect(frame![0], respCodeCurrTime);
    expect(frame.length, 5);
  });

  test('start is idempotent and disconnectClient is safe without a client',
      () async {
    final port = server.port;
    await server.start();
    expect(server.port, port);

    await server.disconnectClient(reason: 'already stopped');
    expect(server.hasClient, isFalse);
  });

  test('switchBridge disconnects the client and serves the new identity',
      () async {
    final secondIdentity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 2);
    final secondBridge = TestBridge(secondIdentity)
      ..selfInfo = NodePrefs(nodeName: 'Second');

    await server.switchBridge(secondBridge);

    final next = FramedClient(await Socket.connect('127.0.0.1', server.port!));
    addTearDown(next.close);
    final info = await appStart(next);
    expect(info[0], respCodeSelfInfo);
    expect(info.sublist(4, 36), secondIdentity.publicKey);
    expect(server.bridge, same(secondBridge));
  });

  test('a client connecting mid-switch waits for the new bridge', () async {
    final oldClient = client;
    bridge.advertiseGate = Completer<void>();
    bridge.advertiseEntered = Completer<void>();
    oldClient.send([cmdSendSelfAdvert, 0]);
    await bridge.advertiseEntered!.future;

    final secondIdentity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 3);
    final secondBridge = TestBridge(secondIdentity)
      ..deviceInfo = const DeviceInfo(maxChannels: 4);
    final switching = server.switchBridge(secondBridge);

    final next = FramedClient(await Socket.connect('127.0.0.1', server.port!));
    addTearDown(next.close);
    next.send([cmdDeviceQuery, appProtocolVersion]);
    expect(
      await next.frames.nextWithin(const Duration(milliseconds: 50)),
      isNull,
      reason: 'commands from a mid-switch client must wait for the barrier',
    );

    bridge.advertiseGate!.complete();
    await switching;

    final deviceInfo = await next.frames.next();
    expect(deviceInfo[0], respCodeDeviceInfo);
    expect(deviceInfo[3], 4, reason: 'served by the new bridge');
    expect(
      serverLogs.any((line) => line.contains('dropping reply')),
      isTrue,
      reason: 'the old in-flight reply must not reach the new client',
    );
  });

  test('disconnectClient keeps the listener available for a reconnect',
      () async {
    await server.disconnectClient(reason: 'clear local data');
    expect(server.hasClient, isFalse);

    final next = FramedClient(await Socket.connect('127.0.0.1', server.port!));
    addTearDown(next.close);
    final info = await appStart(next);
    expect(info[0], respCodeSelfInfo);
  });

  test('a closed client is reported as a closed session', () async {
    await client.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(server.hasClient, isFalse);
    expect(server.metrics.lastDisconnectReason, 'closed');
  });

  test('switchBridge reports a failing push sink and still completes',
      () async {
    final failing = FailingSinkBridge(identity);
    await server.switchBridge(failing);
    expect(server.bridge, same(failing));
    failing.failSetPushSink = false;
    await Future<void>.delayed(Duration.zero);
    expect(
      serverLogs.any((line) => line.contains('bridge switch error')),
      isTrue,
    );
  });

  test('remaining push frames match the firmware layouts', () async {
    final prefix = Uint8List.fromList([1, 2, 3, 4, 5, 6]);

    server.pushMsgWaiting();
    expect(await client.frames.next(), [pushCodeMsgWaiting]);

    final pubkey = Uint8List(32)..[0] = 9;
    server.pushAdvert(pubkey);
    expect(await client.frames.next(), [pushCodeAdvert, ...pubkey]);

    server.pushPathUpdated(pubkey);
    expect(await client.frames.next(), [pushCodePathUpdated, ...pubkey]);

    server.pushTelemetryResponse(prefix, Uint8List.fromList([7, 8]));
    expect(await client.frames.next(),
        [pushCodeTelemetryResponse, 0, ...prefix, 7, 8]);

    server.pushPathDiscoveryResponse(
      prefix,
      2,
      Uint8List.fromList([0xAA, 0xBB]),
      1,
      Uint8List.fromList([0xCC]),
    );
    expect(await client.frames.next(),
        [pushCodePathDiscoveryResponse, 0, ...prefix, 2, 0xAA, 0xBB, 1, 0xCC]);

    server.pushLoginSuccess(
      prefix,
      permissions: 3,
      serverTag: 0x11223344,
      acl: 5,
      firmwareVer: 14,
    );
    expect(await client.frames.next(), [
      pushCodeLoginSuccess,
      3,
      ...prefix,
      0x44,
      0x33,
      0x22,
      0x11,
      5,
      14,
    ]);

    server.pushLoginSuccess(prefix, legacy: true);
    expect(await client.frames.next(), [pushCodeLoginSuccess, 0, ...prefix]);

    server.pushLoginFail(prefix);
    expect(await client.frames.next(), [pushCodeLoginFail, 0, ...prefix]);

    server.pushStatusResponse(prefix, Uint8List.fromList([9]));
    expect(
        await client.frames.next(), [pushCodeStatusResponse, 0, ...prefix, 9]);

    server.pushControlData(-1.0, -70, 2, Uint8List.fromList([1, 2]));
    expect(
        await client.frames.next(), [pushCodeControlData, 252, 186, 2, 1, 2]);
  });

  test('unexpected bridge errors answer ERR bad state and count internally',
      () async {
    client.send(const []);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    bridge.contactsError = StateError('backend exploded');
    client.send([cmdGetContacts, 0, 0, 0, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
    expect(server.metrics.internalErrors, 1);
    expect(
      serverLogs.any((line) =>
          line.contains('internal error') && line.contains('backend exploded')),
      isTrue,
    );

    // Malformed input is still the client's error, not an internal failure.
    bridge.contactsError = const FormatException('bad input');
    client.send([cmdGetContacts, 0, 0, 0, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(server.metrics.internalErrors, 1);

    bridge.contactsError = RangeError('bad range');
    client.send([cmdGetContacts, 0, 0, 0, 0]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    expect(server.metrics.internalErrors, 1);
  });

  test('operation errors preserve codes and disabled/uncertain flags',
      () async {
    final pubkey = Uint8List(32)..[0] = 9;
    bridge.addContactError = const CompanionOperationError(errCodeTableFull);
    client.send([cmdAddUpdateContact, ..._contactBody(pubkey)]);
    expect(await client.frames.next(), [respCodeErr, errCodeTableFull]);

    bridge.removeContactError = const CompanionOperationError(
      errCodeBadState,
      message: 'uncertain write',
      uncertain: true,
    );
    client.send([cmdRemoveContact, ...pubkey]);
    expect(await client.frames.next(), [respCodeErr, errCodeBadState]);
    expect(
      serverLogs.any((line) => line.contains('no automatic retry')),
      isTrue,
    );

    bridge.resetPathError =
        const CompanionOperationError(errCodeIllegalArg, disabled: true);
    client.send([cmdResetPath, ...pubkey]);
    expect(await client.frames.next(), [respCodeDisabled]);
  });

  test('GET_CONTACT_BY_KEY validates, looks up, and frames the contact',
      () async {
    final pubkey = Uint8List(32)..[0] = 9;

    client.send([cmdGetContactByKey, 1, 2, 3]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdGetContactByKey, ...pubkey]);
    expect(await client.frames.next(), [respCodeErr, errCodeNotFound]);

    final contact = Contact(publicKey: pubkey, name: 'peer', lastmod: 42);
    bridge.contacts.add(contact);
    client.send([cmdGetContactByKey, ...pubkey]);
    final frame = await client.frames.next();
    expect(frame[0], respCodeContact);
    expect(frame.sublist(1, 33), pubkey);
    expect(frame.sublist(35, 39), [0xFF, 0, 0, 0]);
    expect(frame.sublist(100, 104), [0x70, 0x65, 0x65, 0x72]);
  });

  test('ADD_UPDATE_CONTACT accepts unknown routes and partial records',
      () async {
    final pubkey = Uint8List(32)..[0] = 9;

    client.send([cmdAddUpdateContact, ..._contactBody(pubkey, pathLen: 0xFF)]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.addedContact!.outPathLen, -1);
    expect(bridge.addedContact!.outPath, isEmpty);
    expect(bridge.addedContactHasGps, isFalse);

    // A truncated name field is padded rather than rejected.
    final partial = _contactBody(pubkey, name: 'peer').sublist(0, 99 + 4);
    client.send([cmdAddUpdateContact, ...partial]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.addedContact!.name, 'peer');
    expect(bridge.addedContact!.lastmod, bridge.currentTime);

    // The name field may be omitted entirely when the path field ends early.
    client.send([cmdAddUpdateContact, ..._contactBody(pubkey).sublist(0, 99)]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.addedContact!.name, '');

    // Timestamp, GPS, and lastmod fields are all optional but decoded when
    // present.
    final full = (BufferWriter()
          ..writeBytes(_contactBody(pubkey, name: 'peer'))
          ..writeUInt32Le(0x11223344)
          ..writeInt32Le(40500000)
          ..writeInt32Le(-96250000)
          ..writeUInt32Le(0x55667788))
        .toBytes();
    client.send([cmdAddUpdateContact, ...full]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.addedContact!.lastAdvertTimestamp, 0x11223344);
    expect(bridge.addedContact!.gpsLat, closeTo(40.5, 1e-9));
    expect(bridge.addedContact!.gpsLon, closeTo(-96.25, 1e-9));
    expect(bridge.addedContact!.lastmod, 0x55667788);
    expect(bridge.addedContactHasGps, isTrue);
  });

  test('ADD_UPDATE_CONTACT rejects truncated paths and short records',
      () async {
    final pubkey = Uint8List(32)..[0] = 9;

    client.send([cmdAddUpdateContact, ..._contactBody(pubkey).sublist(0, 34)]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd],
        reason: 'records shorter than 35 bytes are rejected');

    // Stock's guard is `len >= 1+32+2+1`, i.e. a 35-byte body is accepted.
    client.send([cmdAddUpdateContact, ..._contactBody(pubkey).sublist(0, 35)]);
    expect(await client.frames.next(), [respCodeOk]);

    final twoHop = _contactBody(pubkey, pathLen: 2);
    client.send([cmdAddUpdateContact, ...twoHop.sublist(0, 36)]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);

    client.send([cmdAddUpdateContact, ...const <int>[]]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
  });

  test('REMOVE_CONTACT and RESET_PATH validate and forward the key', () async {
    final pubkey = Uint8List(32)..[0] = 9;
    bridge.contacts.add(Contact(publicKey: pubkey, name: 'peer'));

    client.send([cmdRemoveContact, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeIllegalArg]);
    client.send([cmdRemoveContact, ...pubkey]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.removedContact, pubkey);
    expect(bridge.contacts, isEmpty);

    client.send([cmdResetPath, 1, 2]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
    client.send([cmdResetPath, ...pubkey]);
    expect(await client.frames.next(), [respCodeOk]);
    expect(bridge.resetPathFor, pubkey);
  });

  test(
      'the command table declares every supported command and enforces '
      'its minimum payload length', () async {
    expect(
        server.commandSpecs.keys,
        containsAll(const [
          cmdDeviceQuery,
          cmdAppStart,
          cmdGetDeviceTime,
          cmdSetDeviceTime,
          cmdGetBattAndStorage,
          cmdGetCustomVars,
          cmdSetCustomVar,
          cmdGetAutoAddConfig,
          cmdSetAutoAddConfig,
          cmdSetOtherParams,
          cmdSetRadioParams,
          cmdSetRadioTxPower,
          cmdSetDevicePin,
          cmdFactoryReset,
          cmdExportPrivateKey,
          cmdImportPrivateKey,
          cmdGetTuningParams,
          cmdSetTuningParams,
          cmdSetPathHashMode,
          cmdRunCliCommand,
          cmdGetContacts,
          cmdGetContactByKey,
          cmdAddUpdateContact,
          cmdRemoveContact,
          cmdResetPath,
          cmdGetChannel,
          cmdSetChannel,
          cmdSendSelfAdvert,
          cmdSetAdvertName,
          cmdSetAdvertLatLon,
          cmdSendTxtMsg,
          cmdSendChannelTxtMsg,
          cmdSendChannelData,
          cmdSendControlData,
          cmdSyncNextMessage,
          cmdSignStart,
          cmdSignData,
          cmdSignFinish,
          cmdGetStats,
          cmdGetAllowedRepeatFreq,
          cmdGetAdvertPath,
          cmdExportContact,
          cmdImportContact,
          cmdShareContact,
          cmdSendBinaryReq,
          cmdSendAnonReq,
          cmdSendTelemetryReq,
          cmdSendTracePath,
          cmdSendPathDiscoveryReq,
          cmdSendLogin,
          cmdSendStatusReq,
          cmdSendRawData,
          cmdSendRawPacket,
          cmdLogout,
          cmdHasConnection,
          cmdSetFloodScope,
          cmdSetDefaultFloodScope,
          cmdGetDefaultFloodScope,
          cmdReboot,
        ]));
    expect(server.commandSpecs.length, 59);
    expect(server.commandSpecs[cmdSendTxtMsg]!.minDataLength, 13);
    expect(server.commandSpecs[cmdImportPrivateKey]!.minDataLength, 64);
    expect(server.commandSpecs[cmdGetContactByKey]!.minDataLength, pubKeySize);
    expect(server.commandSpecs[cmdSendAnonReq]!.minDataLength, pubKeySize + 1);
    expect(server.commandSpecs[cmdReboot]!.minDataLength, 0);

    for (final entry in server.commandSpecs.entries) {
      final min = entry.value.minDataLength;
      expect(min, greaterThanOrEqualTo(0),
          reason: 'cmd 0x${entry.key.toRadixString(16)}');
      if (min == 0) continue;
      client.send([entry.key, ...List.filled(min - 1, 0)]);
      expect(
        await client.frames.next(),
        [respCodeErr, entry.value.shortErrorCode],
        reason: 'cmd 0x${entry.key.toRadixString(16)} with ${min - 1} bytes',
      );
    }

    client.send([0xFF]);
    expect(await client.frames.next(), [respCodeErr, errCodeUnsupportedCmd]);
  });
}

Future<Uint8List> appStart(FramedClient client) async {
  final w = BufferWriter()
    ..writeByte(cmdAppStart)
    ..writeBytes(List.filled(7, 0))
    ..writeString('test')
    ..writeByte(0);
  client.send(w.toBytes());
  return client.frames.next();
}

/// Build an `ADD_UPDATE_CONTACT` body with the fixed path/name fields.
Uint8List _contactBody(
  Uint8List publicKey, {
  int pathLen = 0,
  String name = '',
  int advType = advTypeChat,
}) {
  return (BufferWriter()
        ..writeBytes(publicKey)
        ..writeByte(advType)
        ..writeByte(0)
        ..writeByte(pathLen)
        ..writeBytes(Uint8List(64))
        ..writeCString(name, 32))
      .toBytes();
}

List<int> utf8Bytes(String s) => utf8.encode(s);
