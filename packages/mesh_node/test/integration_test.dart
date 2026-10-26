import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

/// End-to-end: a meshcore-cli style framed TCP client talks to the proxy,
/// which uses a MeshNode over a simulated device link, against a peer node on
/// the same simulated radio bus.
class FramedClient {
  FramedClient(this._socket) {
    _socket.listen((data) {
      for (final f in _codec.ingest(data)) {
        _controller.add(f);
      }
    });
  }

  final Socket _socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final _controller = StreamController<Uint8List>.broadcast();
  late final _frames = _Queue(_controller.stream);
  int rawRxFrames = 0;

  void send(List<int> payload) =>
      _socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));

  Future<Uint8List> next() async {
    while (true) {
      final frame = await _frames.next();
      if (frame[0] == pushCodeLogRxData) {
        rawRxFrames++;
        continue;
      }
      return frame;
    }
  }

  Future<void> close() async {
    await _controller.close();
    await _socket.close();
  }
}

class _Queue<T> {
  _Queue(Stream<T> stream) {
    _sub = stream.listen(_add);
  }
  late final StreamSubscription<T> _sub;
  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];

  Future<T> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final c = Completer<T>();
    _waiters.add(c);
    return c.future;
  }

  void _add(T value) {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(value);
    } else {
      _buffer.add(value);
    }
  }

  Future<void> cancel() => _sub.cancel();
}

Future<void> pump() => Future<void>.delayed(const Duration(milliseconds: 25));

void main() {
  test('full stack: CLI connects, sees identity, exchanges messages', () async {
    final bus = FakeRadioBus();
    final aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
    final bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 2);
    final aliceLink = FakeDeviceLink(bus: bus);
    final bobLink = FakeDeviceLink(bus: bus);
    await aliceLink.connect();
    await bobLink.connect();

    final alice = MeshNode(
      identity: aliceId,
      link: aliceLink,
      prefs: NodePrefs(nodeName: 'alice'),
    )..start();
    final bob = MeshNode(
      identity: bobId,
      link: bobLink,
      prefs: NodePrefs(nodeName: 'bob'),
    )..start();

    // Both nodes advertise before the client connects, so the contact table is
    // populated without pushing advert notifications to the client.
    await alice.advertise();
    await bob.advertise();
    await pump();

    final server = CompanionServer(
      bridge: alice,
      config: const CompanionServerConfig(port: 0),
    );
    await server.start();
    final socket = await Socket.connect('127.0.0.1', server.port!);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final client = FramedClient(socket);

    try {
      // Handshake.
      client.send([cmdDeviceQuery, appProtocolVersion]);
      expect((await client.next())[0], respCodeDeviceInfo);

      client.send([cmdAppStart, appProtocolVersion]);
      final selfInfo = await client.next();
      expect(selfInfo[0], respCodeSelfInfo);
      expect(selfInfo.sublist(4, 36), aliceId.publicKey);

      client.send([cmdGetBattAndStorage]);
      expect((await client.next())[0], respCodeBattAndStorage);

      client.send([cmdGetCustomVars]);
      expect((await client.next())[0], respCodeCustomVars);

      client.send([cmdGetAutoAddConfig]);
      expect((await client.next())[0], respCodeAutoAddConfig);

      // Both nodes advertise so they learn each other. (Already done before the
      // client connected; re-advertising here would push advert notifications.)

      // The client sees bob as a contact.
      client.send([cmdGetContacts, 0, 0, 0, 0]);
      expect((await client.next())[0], respCodeContactsStart);
      final contact = await client.next();
      expect(contact[0], respCodeContact);
      expect(contact.sublist(1, 33), bobId.publicKey);
      expect((await client.next())[0], respCodeEndOfContacts);

      // The client sends a direct message to bob. The proxy must echo the app's
      // timestamp and attempt verbatim so the client's precomputed ACK hash
      // matches RESP_CODE_SENT.
      const timestamp = 1700000123;
      const attempt = 1;
      final w = BufferWriter()
        ..writeByte(cmdSendTxtMsg)
        ..writeByte(txtTypePlain)
        ..writeByte(attempt)
        ..writeUInt32Le(timestamp)
        ..writeBytes(bobId.publicKey.sublist(0, 6))
        ..writeString('hi from cli')
        ..writeByte(0);
      client.send(w.toBytes());
      final sent = await client.next();
      expect(sent[0], respCodeSent);
      final sentReader = BufferReader(sent)..skipBytes(2);
      expect(
        sentReader.readUInt32Le(),
        PacketBuilder.computeAckCrc(
          timestamp: timestamp,
          flagsByte: (txtTypePlain << 2) | attempt,
          message: 'hi from cli',
          selfPubkey: aliceId.publicKey,
        ),
        reason: 'client-precomputed ACK hash must match',
      );
      await pump();
      final bobMsg = await bob.syncNextMessage();
      expect(bobMsg, isNotNull);
      expect(bobMsg!.text, 'hi from cli');

      // Bob acknowledged the message, so the proxy pushed SEND_CONFIRMED.
      // Learning the zero-hop route also pushes PATH_UPDATED first.
      var confirmed = await client.next();
      while (confirmed[0] == pushCodePathUpdated) {
        confirmed = await client.next();
      }
      expect(confirmed[0], pushCodeSendConfirmed);
      expect(client.rawRxFrames, greaterThan(0));

      // Forcing flood resets the contact route. The send must use the flood
      // timeout and still return the client's expected ACK hash.
      client.send([cmdResetPath, ...bobId.publicKey]);
      expect((await client.next())[0], respCodeOk);
      const floodTimestamp = timestamp + 1;
      final fw = BufferWriter()
        ..writeByte(cmdSendTxtMsg)
        ..writeByte(txtTypePlain)
        ..writeByte(0)
        ..writeUInt32Le(floodTimestamp)
        ..writeBytes(bobId.publicKey.sublist(0, 6))
        ..writeString('flood from cli')
        ..writeByte(0);
      client.send(fw.toBytes());
      final floodSent = await client.next();
      expect(floodSent[0], respCodeSent);
      expect(floodSent[1], 1, reason: 'reset path forces flood');
      final floodReader = BufferReader(floodSent)..skipBytes(2);
      expect(
        floodReader.readUInt32Le(),
        PacketBuilder.computeAckCrc(
          timestamp: floodTimestamp,
          flagsByte: txtTypePlain << 2,
          message: 'flood from cli',
          selfPubkey: aliceId.publicKey,
        ),
      );
      final floodTimeoutMs = floodReader.readUInt32Le();
      expect(floodTimeoutMs, greaterThan(0));
      await pump();
      expect((await bob.syncNextMessage())!.text, 'flood from cli');
      var floodConfirmed = await client.next();
      while (floodConfirmed[0] == pushCodePathUpdated) {
        floodConfirmed = await client.next();
      }
      expect(floodConfirmed[0], pushCodeSendConfirmed);

      // Bob replies; the proxy pushes MSG_WAITING and serves the message.
      final reply = await bob.sendTextMessage(aliceId.publicKey, 'hi alice');
      expect(reply.success, isTrue);
      await pump();
      expect((await client.next())[0], pushCodeMsgWaiting);

      client.send([cmdSyncNextMessage]);
      final recv = await client.next();
      expect(recv[0], respCodeContactMsgRecvV3);
      final r = BufferReader(recv)..skipBytes(4); // code + snr + 2 reserved
      expect(r.readBytes(6), bobId.publicKey.sublist(0, 6));
      r.skipBytes(1); // path len
      r.skipBytes(1); // txt type
      r.skipBytes(4); // timestamp
      expect(r.readCString(), 'hi alice');

      // A scoped channel send carries the active region key through the server
      // to the raw radio packet.
      final regionKey =
          Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
      client.send([cmdSetFloodScope, 0, ...regionKey]);
      expect((await client.next())[0], respCodeOk);

      // Channel message from the client is delivered to the peer.
      final cw = BufferWriter()
        ..writeByte(cmdSendChannelTxtMsg)
        ..writeByte(txtTypePlain)
        ..writeByte(0)
        ..writeUInt32Le(0)
        ..writeString('channel hi')
        ..writeByte(0);
      client.send(cw.toBytes());
      expect((await client.next())[0], respCodeOk);
      final scopedPacket = Packet.readFrom(aliceLink.transmitted.last)!;
      expect(scopedPacket.routeType, routeTypeTransportFlood);
      expect(
        scopedPacket.transportCode0,
        CryptoUtils.transportCode(
          regionKey,
          scopedPacket.payloadType,
          scopedPacket.payload,
        ),
      );
      client.send([cmdSetFloodScope, 0]);
      expect((await client.next())[0], respCodeOk);
      await pump();
      final chanMsg = await bob.syncNextMessage();
      expect(chanMsg, isNotNull);
      expect(chanMsg!.isChannel, isTrue);
      expect(chanMsg.text, 'alice: channel hi');

      // Binary channel data sent by the client reaches the peer.
      final dw = BufferWriter()
        ..writeByte(cmdSendChannelData)
        ..writeByte(0) // channel 0
        ..writeByte(0xFF) // flood
        ..writeUInt16Le(0x1234)
        ..writeBytes([9, 9, 9]);
      client.send(dw.toBytes());
      expect((await client.next())[0], respCodeOk);
      await pump();
      final dataMsg = await bob.syncNextMessage();
      expect(dataMsg, isNotNull);
      expect(dataMsg!.channelDataType, 0x1234);
      expect(dataMsg.channelDataPayload, [9, 9, 9]);

      // Conversely, channel data from the peer is served to the client as
      // RESP_CODE_CHANNEL_DATA_RECV.
      expect(await bob.sendChannelData(0, 0x00AB, Uint8List.fromList([7, 7])),
          isTrue);
      await pump();
      expect((await client.next())[0], pushCodeMsgWaiting);
      client.send([cmdSyncNextMessage]);
      final dataRecv = await client.next();
      expect(dataRecv[0], respCodeChannelDataRecv);
      final dr = BufferReader(dataRecv)
        ..skipBytes(4); // code + snr + 2 reserved
      expect(dr.readByte(), 0); // channel index
      dr.skipBytes(1); // path len
      expect(dr.readUInt16Le(), 0x00AB);
      expect(dr.readByte(), 2);
      expect(dr.readBytes(2), [7, 7]);

      // Control data: the client can send it (zero-hop) and receives a push for
      // control data heard on the air.
      client.send([cmdSendControlData, 0x80, 9, 8]);
      expect((await client.next())[0], respCodeOk);
      await pump();

      expect(await bob.sendControlData(Uint8List.fromList([0x80, 5])), isTrue);
      await pump();
      final cd = await client.next();
      expect(cd[0], pushCodeControlData);
      expect(cd[3], 0); // zero-hop => empty path
      expect(cd.sublist(4), [0x80, 5]);

      // Signing round trip.
      client.send([cmdSignStart]);
      expect((await client.next())[0], respCodeSignStart);
      client.send([cmdSignData, ...'data'.codeUnits]);
      expect((await client.next())[0], respCodeOk);
      client.send([cmdSignFinish]);
      final sig = await client.next();
      expect(sig[0], respCodeSignature);
      expect(
        await LocalIdentity.verify(
          Uint8List.fromList('data'.codeUnits),
          sig.sublist(1),
          aliceId.publicKey,
        ),
        isTrue,
      );
    } finally {
      await client.close();
      await server.stop();
      alice.stop();
      bob.stop();
    }
  });

  test('full stack: T16 TCP conformance session', () async {
    final bus = FakeRadioBus();
    final aliceId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 61);
    final bobId = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 62);
    const deviceInfo = DeviceInfo(
      firmwareVerCode: 14,
      clientRepeat: 1,
    );
    final aliceLink = FakeDeviceLink(
      bus: bus,
      deviceInfo_: deviceInfo,
      batteryReading_: const BatteryReading(
        millivolts: 3711,
        storageUsedKb: 0,
        storageTotalKb: 1024,
      ),
      radioParams_: const RadioParams(
        frequencyHz: 869525000,
        bandwidthHz: 125000,
        spreadingFactor: 9,
        codingRate: 5,
        txPowerDbm: -3,
      ),
      maxTxPower: 17,
    );
    final bobLink = FakeDeviceLink(
      bus: bus,
      deviceInfo_: deviceInfo,
      radioParams_: const RadioParams(
        frequencyHz: 869525000,
        bandwidthHz: 125000,
        spreadingFactor: 9,
        codingRate: 5,
      ),
    );
    await aliceLink.connect();
    await bobLink.connect();
    final alice = MeshNode(
      identity: aliceId,
      link: aliceLink,
      physical: PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: 17,
      ),
      prefs: NodePrefs(nodeName: 'alice'),
    );
    final bob = MeshNode(
      identity: bobId,
      link: bobLink,
      physical: PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: 17,
      ),
      prefs: NodePrefs(nodeName: 'bob'),
    );
    await alice.load();
    await bob.load();
    alice
      ..adoptPhysicalCapabilities(PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: 17,
      ))
      ..syncRadioParams(await aliceLink.radioParams());
    bob
      ..adoptPhysicalCapabilities(PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: 17,
      ))
      ..syncRadioParams(await bobLink.radioParams());

    // Establish mutual contacts and remote-CLI / telemetry permissions before
    // the client connects, so no advert pushes interleave with responses.
    await alice.advertise();
    await bob.advertise();
    await pump();
    await alice.addUpdateContact(Contact(
      publicKey: bobId.publicKey,
      name: 'bob',
      flags: 0x10,
      lastmod: 100,
      outPathLen: 0,
    ));
    await bob.addUpdateContact(Contact(
      publicKey: aliceId.publicKey,
      name: 'alice',
      flags: 0x12, // remote CLI + base telemetry
      lastmod: 100,
      outPathLen: 0,
    ));
    bob.prefs.telemetryModeBase = teleModeAllowAll;
    bob.prefs.latitude = 1.25;
    bob.prefs.longitude = -2.5;
    alice.start();
    bob.start();

    final server = CompanionServer(
      bridge: alice,
      config: const CompanionServerConfig(port: 0),
    );
    await server.start();
    final socket = await Socket.connect('127.0.0.1', server.port!);
    socket.setOption(SocketOption.tcpNoDelay, true);
    final client = FramedClient(socket);

    Future<Uint8List> command(List<int> payload) async {
      client.send(payload);
      return client.next();
    }

    try {
      // Target-info golden.
      final info = await command([cmdDeviceQuery, appProtocolVersion]);
      expect(info[0], respCodeDeviceInfo);
      expect(info[1], targetFirmwareVerCode);
      expect(info[2], 175); // virtual 350 contacts / 2
      expect(info[3], virtualMaxChannels);
      expect(info.sublist(4, 8), [0, 0, 0, 0]);
      expect(
        String.fromCharCodes(info.sublist(20, 60).takeWhile((b) => b != 0)),
        virtualBoardName,
      );
      expect(
        String.fromCharCodes(info.sublist(60, 80).takeWhile((b) => b != 0)),
        targetCompatibilityVersion,
      );
      expect(info[80], 1, reason: 'physical repeat byte');
      expect(info[81], 0, reason: 'virtual path mode');

      final start = await command([cmdAppStart, appProtocolVersion]);
      expect(start[0], respCodeSelfInfo);
      expect(start.sublist(4, 36), aliceId.publicKey);
      expect(start[2], 0xFD, reason: 'signed -3 dBm TX power byte');
      expect(start[3], 17, reason: 'physical max TX');
      final sr = BufferReader(start)..skipBytes(4 + 32 + 8);
      expect(sr.readByte(), 0); // multi-acks
      expect(sr.readByte(), advertLocNone);
      expect(sr.readByte(), 0); // telemetry modes
      expect(sr.readByte(), 0); // manual add
      expect(sr.readUInt32Le(), 869525, reason: 'kHz wire frequency');
      expect(sr.readUInt32Le(), 125000);
      expect(sr.readByte(), 9);
      expect(sr.readByte(), 5);
      expect(sr.readCString(), 'alice');

      // OTHER/AUTOADD round trips.
      expect(
          (await command([cmdSetOtherParams, 1, 0x26, 1, 2]))[0], respCodeOk);
      final autoAdd = await command([cmdSetAutoAddConfig, 0x06, 2]);
      expect(autoAdd[0], respCodeOk);
      expect(await command([cmdGetAutoAddConfig]), [25, 0x06, 2]);
      final startedAgain = await command([cmdAppStart, appProtocolVersion]);
      final prefsReader = BufferReader(startedAgain)..skipBytes(4 + 32 + 8);
      prefsReader.skipBytes(4);
      expect(prefsReader.readUInt32Le(), 869525);
      prefsReader.skipBytes(4 + 1 + 1);
      expect(prefsReader.readCString(), 'alice');
      expect(startedAgain[44], 2, reason: 'multi-acks persisted');
      expect(startedAgain[45], advertLocShare);
      expect(startedAgain[46], 0x26, reason: 'telemetry mode byte');
      expect(startedAgain[47], 1, reason: 'manual add');

      // Time is virtual and readable/settable.
      final time = await command([cmdGetDeviceTime]);
      expect(time[0], respCodeCurrTime);
      final now = BufferReader(time.sublist(1)).readUInt32Le();
      final future = now + 100;
      expect(
          (await command([
            cmdSetDeviceTime,
            future & 0xFF,
            (future >> 8) & 0xFF,
            (future >> 16) & 0xFF,
            (future >> 24) & 0xFF,
          ]))[0],
          respCodeOk);
      final afterTime = await command([cmdGetDeviceTime]);
      expect(BufferReader(afterTime.sublist(1)).readUInt32Le(), future);

      // Battery voltage is physical/fresh; storage is the virtual quota.
      final battery = await command([cmdGetBattAndStorage]);
      expect(battery[0], respCodeBattAndStorage);
      expect(BufferReader(battery.sublist(1)).readUInt16Le(), 3711);
      final storage = BufferReader(battery)..skipBytes(1 + 2);
      expect(storage.readUInt32Le(), greaterThan(0));
      expect(storage.readUInt32Le(), virtualStorageTotalKb);

      // Contacts/channels.
      final contacts = await command([cmdGetContacts, 0, 0, 0, 0]);
      expect(contacts[0], respCodeContactsStart);
      final bobContact = await client.next();
      expect(bobContact[0], respCodeContact);
      expect(bobContact.sublist(1, 33), bobId.publicKey);
      expect((await client.next())[0], respCodeEndOfContacts);
      final byKey = await command([cmdGetContactByKey, ...bobId.publicKey]);
      expect(byKey[0], respCodeContact);
      expect(byKey.sublist(1, 33), bobId.publicKey);

      final psk = Uint8List.fromList(List.generate(16, (i) => i + 40));
      final setChannel = BufferWriter()
        ..writeByte(cmdSetChannel)
        ..writeByte(5)
        ..writeCString('T16', 32)
        ..writeBytes(psk);
      expect((await command(setChannel.toBytes()))[0], respCodeOk);
      final channel = await command([cmdGetChannel, 5]);
      expect(channel[0], respCodeChannelInfo);
      expect(channel[1], 5);
      expect(
        String.fromCharCodes(channel.sublist(2, 34).takeWhile((b) => b != 0)),
        'T16',
      );
      expect(channel.sublist(34, 50), psk);

      // Virtual path mode never reaches the physical device.
      aliceLink.calls.clear();
      expect((await command([cmdSetPathHashMode, 0, 2]))[0], respCodeOk);
      final pathInfo = await command([cmdDeviceQuery, appProtocolVersion]);
      expect(pathInfo[81], 2);
      expect(aliceLink.calls, isNot(contains('setPathHashMode')));

      // CLI: virtual commands are local and bounded.
      final cliName = BufferWriter()
        ..writeByte(cmdRunCliCommand)
        ..writeString('AB|set name T16 Alice')
        ..writeByte(0);
      final cliReply = await command(cliName.toBytes());
      expect(cliReply[0], respCodeCliReply);
      expect(utf8.decode(cliReply.sublist(1)), 'AB|OK');
      final ver = BufferWriter()
        ..writeByte(cmdRunCliCommand)
        ..writeString('ver')
        ..writeByte(0);
      expect(utf8.decode((await command(ver.toBytes())).sublist(1)),
          virtualCliVersion);

      // Message send and receive.
      final send = BufferWriter()
        ..writeByte(cmdSendTxtMsg)
        ..writeByte(txtTypePlain)
        ..writeByte(0)
        ..writeUInt32Le(0)
        ..writeBytes(bobId.publicKey.sublist(0, 6))
        ..writeString('t16 direct')
        ..writeByte(0);
      final sent = await command(send.toBytes());
      expect(sent[0], respCodeSent);
      await pump();
      expect((await bob.syncNextMessage())?.text, 't16 direct');
      expect((await client.next())[0], pushCodeSendConfirmed);
      await bob.sendTextMessage(aliceId.publicKey, 't16 reply');
      await pump();
      expect((await client.next())[0], pushCodeMsgWaiting);
      final received = await command([cmdSyncNextMessage]);
      expect(received[0], respCodeContactMsgRecvV3);
      final rr = BufferReader(received)..skipBytes(4 + 6 + 1 + 1 + 4);
      expect(rr.readCString(), 't16 reply');

      // Remote CLI executes on the peer and replies CLI_DATA after 600 ms.
      final remote = await bob.sendTextMessage(
        aliceId.publicKey,
        'AB|set name T16 Remote',
        txtType: txtTypeCliCommand,
      );
      expect(remote.success, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 700));
      final remoteReply = await bob.syncNextMessage();
      expect(remoteReply?.txtType, txtTypeCliData);
      expect(remoteReply?.text, 'AB|OK');
      final afterRemote = await command([cmdAppStart, appProtocolVersion]);
      expect(
        String.fromCharCodes(afterRemote.sublist(58).takeWhile((b) => b != 0)),
        'T16 Remote',
      );

      // Incoming telemetry request: matched push with virtual coordinates.
      final telemetryReq = await command([
        cmdSendTelemetryReq,
        0,
        0,
        0,
        ...bobId.publicKey,
      ]);
      expect(telemetryReq[0], respCodeSent);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final telemetryPush = await client.next();
      expect(telemetryPush[0], pushCodeTelemetryResponse);
      expect(telemetryPush.sublist(2, 8), bobId.publicKey.sublist(0, 6));
      expect(telemetryPush.sublist(8), contains(0x74));

      // Unsolicited authenticated response -> 0x8C with exact tag/data prefix.
      const pushTag = 0x56789ABC;
      final unsolicitedBody = BufferWriter()
        ..writeUInt32Le(pushTag)
        ..writeBytes([0x11, 0x22, 0x74, 0x00]);
      final unsolicited = await PacketBuilder.createProtocolResponse(
        contact: Contact(
          publicKey: aliceId.publicKey,
          outPathLen: 0,
        ),
        identity: bobId,
        data: unsolicitedBody.toBytes(),
        flood: false,
      );
      expect(await bob.sendRawPacket(unsolicited, 0), isTrue);
      await pump();
      final pushed = await client.next();
      expect(pushed[0], pushCodeBinaryResponse);
      expect(pushed[1], 0);
      expect(BufferReader(pushed.sublist(2)).readUInt32Le(), pushTag);
      expect(pushed.sublist(6, 10), [0x11, 0x22, 0x74, 0x00]);

      // Default flood scope.
      final scopeKey = Uint8List.fromList(List.generate(16, (i) => i + 1));
      final setScope = BufferWriter()
        ..writeByte(cmdSetDefaultFloodScope)
        ..writeCString('T16Region', 31)
        ..writeBytes(scopeKey);
      expect((await command(setScope.toBytes()))[0], respCodeOk);
      final gotScope = await command([cmdGetDefaultFloodScope]);
      expect(gotScope[0], respCodeDefaultFloodScope);
      expect(
        String.fromCharCodes(gotScope.sublist(1, 32).takeWhile((b) => b != 0)),
        'T16Region',
      );
      expect(gotScope.sublist(32), scopeKey);

      // Raw packet preserves supplied route/path and priority.
      final rawPacket = Packet()
        ..header = Packet.createHeader(payloadTypeRawCustom, routeTypeDirect)
        ..setPath([0xAA, 0xBB], 1)
        ..payload = Uint8List.fromList([1, 2, 3, 4]);
      aliceLink.transmitted.clear();
      aliceLink.transmitPriorities.clear();
      expect((await command([cmdSendRawPacket, 3, ...rawPacket.writeTo()]))[0],
          respCodeOk);
      expect(aliceLink.transmitPriorities.last, 3);
      expect(aliceLink.transmitted.last, rawPacket.writeTo());

      // Control discovery pass-through is zero-hop and gets no auto response.
      expect((await command([cmdSendControlData, 0x80, 1, 2]))[0], respCodeOk);

      // Signing uses the active virtual key.
      expect((await command([cmdSignStart]))[0], respCodeSignStart);
      expect((await command([cmdSignData, ...'t16'.codeUnits]))[0], respCodeOk);
      final signature = await command([cmdSignFinish]);
      expect(signature[0], respCodeSignature);
      expect(
        await LocalIdentity.verify(
          Uint8List.fromList('t16'.codeUnits),
          signature.sublist(1),
          aliceId.publicKey,
        ),
        isTrue,
      );

      // Virtual key export/import never touches the physical identity.
      aliceLink.calls.clear();
      final exported = await command([cmdExportPrivateKey]);
      expect(exported[0], respCodePrivateKey);
      expect(exported.sublist(1, 65), aliceId.meshcore64);
      final replacement = await LocalIdentity.generate();
      expect(
          (await command([
            cmdImportPrivateKey,
            ...replacement.meshcore64,
          ]))[0],
          respCodeOk);
      expect(
        aliceLink.calls,
        isEmpty,
        reason: 'virtual key commands must not touch the radio',
      );
      final replacedInfo = await command([cmdDeviceQuery, appProtocolVersion]);
      expect(replacedInfo[1], targetFirmwareVerCode);
      final replacedSelf = await command([cmdAppStart, appProtocolVersion]);
      expect(replacedSelf.sublist(4, 36), replacement.publicKey);
      expect(alice.getPublicKey(), replacement.publicKey);
      // Virtual state survives the identity switch.
      final retained = await command([cmdGetContactByKey, ...bobId.publicKey]);
      expect(retained[0], respCodeContact);

      // A representative V/X sweep must not perform physical state writes.
      aliceLink.calls.clear();
      expect((await command([cmdSetOtherParams, 0, 0, 0, 0]))[0], respCodeOk);
      expect((await command([cmdSetAutoAddConfig, 0]))[0], respCodeOk);
      expect(
          (await command([
            cmdSetAdvertName,
            ...'T16 Final'.codeUnits,
            0,
          ]))[0],
          respCodeOk);
      final latLon = BufferWriter()
        ..writeByte(cmdSetAdvertLatLon)
        ..writeInt32Le(1250000)
        ..writeInt32Le(-2500000);
      expect((await command(latLon.toBytes()))[0], respCodeOk);
      expect((await command([cmdSetPathHashMode, 0, 1]))[0], respCodeOk);
      expect((await command([cmdGetCustomVars]))[0], respCodeCustomVars);
      final customSet = BufferWriter()
        ..writeByte(cmdSetCustomVar)
        ..writeString('gps:1');
      expect((await command(customSet.toBytes()))[0], respCodeErr);
      expect((await command([cmdGetStats, statsTypeCore]))[0], respCodeStats);
      expect((await command([cmdGetAllowedRepeatFreq]))[0],
          respCodeAllowedRepeatFreq);
      expect((await command([cmdGetTuningParams]))[0], respCodeTuningParams);
      expect(
          (await command([cmdResetPath, ...bobId.publicKey]))[0], respCodeOk);
      expect((await command([cmdGetDefaultFloodScope]))[0],
          respCodeDefaultFloodScope);
      expect((await command([cmdSetFloodScope, 0]))[0], respCodeOk);
      expect((await command([cmdHasConnection, ...bobId.publicKey]))[0],
          respCodeErr);
      expect((await command([cmdLogout, ...bobId.publicKey]))[0], respCodeOk);
      expect((await command([cmdExportContact]))[0], respCodeExportContact);
      expect((await command([cmdSendSelfAdvert, 0]))[0], respCodeOk);
      expect(
        aliceLink.calls.where((c) =>
            c == 'setRadioParams' ||
            c == 'setTxPower' ||
            c == 'setTuningParams' ||
            c == 'setPathHashMode' ||
            c == 'reboot' ||
            c == 'shutdown' ||
            c == 'runCliCommand'),
        isEmpty,
        reason: 'V/X commands must not mutate physical radio state',
      );

      // Radio writes wait for the simulated device ACK.
      final ack = Completer<void>();
      aliceLink.radioParamsAck = ack;
      final radio = BufferWriter()
        ..writeByte(cmdSetRadioParams)
        ..writeUInt32Le(915000)
        ..writeUInt32Le(125000)
        ..writeByte(10)
        ..writeByte(5);
      client.send(radio.toBytes());
      await Future<void>.delayed(const Duration(milliseconds: 25));
      ack.complete();
      expect((await client.next())[0], respCodeOk);

      // Disabled destructive commands remain disabled after all virtual state.
      expect(await command([cmdFactoryReset]), [respCodeDisabled]);
      expect(await command([cmdSetDevicePin, 1, 2, 3, 4]), [respCodeDisabled]);
    } finally {
      await client.close();
      await server.stop();
      alice.stop();
      bob.stop();
    }
  });
}
