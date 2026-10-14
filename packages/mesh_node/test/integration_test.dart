import 'dart:async';
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
  final SerialFrameCodec _codec = SerialFrameCodec();
  final _controller = StreamController<Uint8List>.broadcast();
  late final _frames = _Queue(_controller.stream);

  void send(List<int> payload) =>
      _socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));

  Future<Uint8List> next() => _frames.next();

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

      // The client sends a direct message to bob.
      final w = BufferWriter()
        ..writeByte(cmdSendTxtMsg)
        ..writeByte(txtTypePlain)
        ..writeByte(0)
        ..writeUInt32Le(0)
        ..writeBytes(bobId.publicKey.sublist(0, 6))
        ..writeString('hi from cli')
        ..writeByte(0);
      client.send(w.toBytes());
      final sent = await client.next();
      expect(sent[0], respCodeSent);
      await pump();
      final bobMsg = bob.syncNextMessage();
      expect(bobMsg, isNotNull);
      expect(bobMsg!.text, 'hi from cli');

      // Bob acknowledged the message, so the proxy pushed SEND_CONFIRMED.
      expect((await client.next())[0], pushCodeSendConfirmed);

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
      await pump();
      final chanMsg = bob.syncNextMessage();
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
      final dataMsg = bob.syncNextMessage();
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
      final dr = BufferReader(dataRecv)..skipBytes(4); // code + snr + 2 reserved
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
}
