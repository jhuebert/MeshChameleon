import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('DeviceFrames.sendRawPacket wraps the packet', () {
    final packet = Uint8List.fromList([0x04, 0x00, 0x01, 0x02]);
    final frame = DeviceFrames.sendRawPacket(packet, 1);
    expect(frame[0], cmdSendRawPacket);
    expect(frame[1], 1);
    expect(frame.sublist(2), packet);
  });

  test('DeviceFrames.setRadioParams encodes kHz frequency', () {
    final frame = DeviceFrames.setRadioParams(
      const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      ),
    );
    expect(frame[0], cmdSetRadioParams);
    final r = BufferReader(frame)..skipBytes(1);
    expect(r.readUInt32Le(), 915000); // kHz
    expect(r.readUInt32Le(), 250000); // Hz
  });

  test('DeviceFrames.setTuningParams encodes ms values little-endian', () {
    final frame = DeviceFrames.setTuningParams(
      const TuningParams(rxDelayBaseMs: 500, airtimeFactorMs: 333),
    );
    expect(frame[0], cmdSetTuningParams);
    final r = BufferReader(frame)..skipBytes(1);
    expect(r.readUInt32Le(), 500);
    expect(r.readUInt32Le(), 333);
  });

  test('TuningParams.parse reads a TUNING_PARAMS frame', () {
    final w = BufferWriter()
      ..writeByte(respCodeTuningParams)
      ..writeUInt32Le(1000)
      ..writeUInt32Le(2000);
    final parsed = TuningParams.parse(w.toBytes());
    expect(parsed, isNotNull);
    expect(parsed!.rxDelayBaseMs, 1000);
    expect(parsed.airtimeFactorMs, 2000);
  });

  test('DeviceFrames.setPathHashMode encodes the reserved byte', () {
    final frame = DeviceFrames.setPathHashMode(2);
    expect(frame, [cmdSetPathHashMode, 0, 2]);
  });

  test('FakeDeviceLink records tuning, path-hash mode, and CLI commands',
      () async {
    final link = FakeDeviceLink();
    await link.connect();
    await link.setTuningParams(
      const TuningParams(rxDelayBaseMs: 12, airtimeFactorMs: 34),
    );
    final tuning = await link.tuningParams();
    expect(tuning.rxDelayBaseMs, 12);
    expect(tuning.airtimeFactorMs, 34);

    await link.setPathHashMode(2);
    expect(link.pathHashMode, 2);

    await link.runCliCommand('adv_int 0');
    expect(link.cliCommands, ['adv_int 0']);
  });

  test('connectWithBackoff retries transient failures', () async {
    final link = FakeDeviceLink(connectFailures: 2);
    await connectWithBackoff(
      link,
      initialDelay: const Duration(milliseconds: 1),
      maxDelay: const Duration(milliseconds: 2),
    );
    expect(link.currentState, LinkState.connected);
  });

  test('connectWithBackoff gives up after maxAttempts', () async {
    final link = FakeDeviceLink(connectFailures: 5);
    await expectLater(
      connectWithBackoff(
        link,
        maxAttempts: 2,
        initialDelay: const Duration(milliseconds: 1),
      ),
      throwsA(isA<StateError>()),
    );
    expect(link.currentState, LinkState.disconnected);
  });

  test('ParsedSelfInfo normalises frequency to Hz', () {
    final w = BufferWriter()
      ..writeByte(respCodeSelfInfo)
      ..writeByte(advTypeChat)
      ..writeByte(20)
      ..writeByte(22)
      ..writeBytes(Uint8List(32)..[0] = 7)
      ..writeInt32Le(0)
      ..writeInt32Le(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeByte(0)
      ..writeUInt32Le(915000) // kHz
      ..writeUInt32Le(250000) // Hz
      ..writeByte(10)
      ..writeByte(5)
      ..writeCString('dev', 4);
    final info = ParsedSelfInfo.parse(w.toBytes());
    expect(info, isNotNull);
    expect(info!.radioParams.frequencyHz, 915000000);
    expect(info.radioParams.bandwidthHz, 250000);
    expect(info.nodeName, 'dev');
    expect(info.publicKey[0], 7);
  });

  test('RawRxFrame parses SNR/RSSI and payload', () {
    final frame = Uint8List.fromList([pushCodeLogRxData, 24, 0xFF & -70, 1, 2, 3]);
    final parsed = RawRxFrame.parse(frame);
    expect(parsed, isNotNull);
    expect(parsed!.snr, 6.0);
    expect(parsed.rssi, -70);
    expect(parsed.raw, [1, 2, 3]);
  });

  test('FakeRadioBus delivers frames between links', () async {
    final bus = FakeRadioBus();
    final a = FakeDeviceLink(bus: bus);
    final b = FakeDeviceLink(bus: bus);
    await a.connect();
    await b.connect();
    final received = <Uint8List>[];
    b.setRawRxListener((snr, rssi, raw) => received.add(raw));
    await a.sendRawPacket(Uint8List.fromList([9, 8, 7]));
    expect(received.single, [9, 8, 7]);
  });

  test('TcpDeviceLink frames device requests with the inbound prefix', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Uint8List>();
    server.listen((socket) {
      socket.listen((data) {
        if (!received.isCompleted) {
          received.complete(Uint8List.fromList(data));
        }
      });
    });

    final link = TcpDeviceLink(
      host: '127.0.0.1',
      port: server.port,
      requestTimeout: const Duration(milliseconds: 300),
    );
    await link.connect();
    link.deviceInfo().then((_) {}, onError: (Object _) {});

    final bytes = await received.future.timeout(const Duration(seconds: 2));
    expect(bytes[0], frameInboundPrefix, reason: 'app→device frames use "<"');
    expect(bytes[1], 2);
    expect(bytes.sublist(3), [cmdDeviceQuery, appProtocolVersion]);

    await link.disconnect();
    await server.close();
  });

  test('TcpDeviceLink sends raw TX as an inbound frame and awaits OK', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final frames = <Uint8List>[];
    final firstFrame = Completer<void>();
    server.listen((socket) {
      final buffer = <int>[];
      socket.listen((data) {
        buffer.addAll(data);
        while (buffer.length >= 3) {
          final length = buffer[1] | (buffer[2] << 8);
          if (buffer.length < 3 + length) break;
          frames.add(Uint8List.fromList(buffer.sublist(3, 3 + length)));
          buffer.removeRange(0, 3 + length);
          if (!firstFrame.isCompleted) firstFrame.complete();
          socket.add(
              Uint8List.fromList([frameOutboundPrefix, 1, 0, respCodeOk]));
        }
      });
    });

    final link = TcpDeviceLink(
      host: '127.0.0.1',
      port: server.port,
      requestTimeout: const Duration(seconds: 2),
    );
    await link.connect();
    final packet = Uint8List.fromList([0x04, 0x00, 0xAA, 0xBB]);
    await link.sendRawPacket(packet, 1);
    await firstFrame.future;

    expect(frames.single[0], cmdSendRawPacket);
    expect(frames.single[1], 1);
    expect(frames.single.sublist(2), packet);

    await link.disconnect();
    await server.close();
  });

  test('TcpDeviceLink parses DEVICE_INFO', () {
    final w = BufferWriter()
      ..writeByte(respCodeDeviceInfo)
      ..writeByte(11)
      ..writeByte(255)
      ..writeByte(8)
      ..writeUInt32Le(0)
      ..writeCString('build', 12)
      ..writeCString('Acme', 40)
      ..writeCString('fw 1.0', 20)
      ..writeByte(0)
      ..writeByte(1);
    final info = TcpDeviceLink.parseDeviceInfo(w.toBytes());
    expect(info.firmwareVerCode, 11);
    expect(info.maxContacts, 510);
    expect(info.maxChannels, 8);
    expect(info.manufacturer, 'Acme');
    expect(info.version, 'fw 1.0');
    expect(info.pathHashMode, 1);
  });
}
