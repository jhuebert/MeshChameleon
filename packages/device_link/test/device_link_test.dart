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

  test('DeviceFrames.reboot encodes CMD_REBOOT + "reboot"', () {
    final frame = DeviceFrames.reboot();
    expect(frame[0], cmdReboot);
    expect(String.fromCharCodes(frame.sublist(1)), 'reboot');
  });

  test('DeviceFrames.runCliCommand wraps the command', () {
    final frame = DeviceFrames.runCliCommand('ver');
    expect(frame[0], cmdRunCliCommand);
    expect(String.fromCharCodes(frame.sublist(1)), 'ver');
  });

  test('DeviceFrames.shutdown sends CLI poweroff without a reply', () {
    final frame = DeviceFrames.shutdown();
    expect(frame[0], cmdRunCliCommand);
    expect(String.fromCharCodes(frame.sublist(1)), 'poweroff');
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

  test('DeviceFrames.setRadioParams appends repeat only when supplied', () {
    const params = RadioParams(
      frequencyHz: 915000000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
    );
    expect(DeviceFrames.setRadioParams(params).length, 11);
    final enabled = DeviceFrames.setRadioParams(params, clientRepeat: true);
    expect(enabled.length, 12);
    expect(enabled[11], 1);
    final disabled = DeviceFrames.setRadioParams(params, clientRepeat: false);
    expect(disabled.length, 12);
    expect(disabled[11], 0);
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

    await link.shutdown();
    expect(link.shutdownRequests, 1);
    expect(link.cliCommands, ['adv_int 0', 'poweroff']);
    expect(link.currentState, LinkState.disconnected);
  });

  test('parsePrivateKeyReply returns the key or null when disabled', () {
    final key = Uint8List.fromList(List.generate(64, (i) => i));
    final reply = Uint8List.fromList([respCodePrivateKey, ...key]);
    expect(parsePrivateKeyReply(reply), key);
    expect(
        parsePrivateKeyReply(Uint8List.fromList([respCodeDisabled])), isNull);
    expect(
      () =>
          parsePrivateKeyReply(Uint8List.fromList([respCodePrivateKey, 1, 2])),
      throwsA(isA<StateError>()),
    );
  });

  test('FakeDeviceLink exposes a configurable private key', () async {
    final key = Uint8List.fromList(List.generate(64, (i) => (i * 3) % 256));
    final link = FakeDeviceLink(devicePrivateKey: key);
    await link.connect();
    expect(await link.exportPrivateKey(), key);
    expect(link.exportPrivateKeyRequests, 1);

    final disabled = FakeDeviceLink(exportPrivateKeyDisabled: true);
    await disabled.connect();
    expect(await disabled.exportPrivateKey(), isNull);
  });

  test('FakeDeviceLink exposes allowed repeat frequencies', () async {
    final ranges = Uint8List.fromList([1, 0, 0, 0, 2, 0, 0, 0]);
    final link = FakeDeviceLink(allowedRepeatFreq: ranges);
    await link.connect();
    expect(await link.getAllowedRepeatFreq(), ranges);
    expect(DeviceFrames.getAllowedRepeatFreq(), [cmdGetAllowedRepeatFreq]);
  });

  test('FakeDeviceLink reports self info before radio params are read',
      () async {
    final link = FakeDeviceLink(deviceNodeName: 'sim-nc1');
    final self = await link.selfInfo();
    expect(self.nodeName, 'sim-nc1');
    expect(self.radioParams.frequencyHz, 915000000);
    expect(link.initialRadioParams.frequencyHz, 915000000);
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

  test('connectWithBackoff stops retrying when cancelled', () async {
    final link = FakeDeviceLink(connectFailures: 3);
    var cancelled = false;
    await expectLater(
      connectWithBackoff(
        link,
        initialDelay: const Duration(milliseconds: 1),
        onLog: (_) => cancelled = true,
        shouldCancel: () => cancelled,
      ),
      throwsStateError,
    );
    expect(link.currentState, LinkState.disconnected);
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
    final frame =
        Uint8List.fromList([pushCodeLogRxData, 24, 0xFF & -70, 1, 2, 3]);
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

  test('TcpDeviceLink frames device requests with the inbound prefix',
      () async {
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

  test('TcpDeviceLink flushes shutdown poweroff without a reply', () async {
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
    await link.shutdown();
    final bytes = await received.future.timeout(const Duration(seconds: 2));
    expect(bytes[0], frameInboundPrefix);
    expect(bytes.sublist(3), [cmdRunCliCommand, ...'poweroff'.codeUnits]);

    await link.disconnect();
    await server.close();
  });

  test('TcpDeviceLink sends raw TX as an inbound frame and awaits OK',
      () async {
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
          socket
              .add(Uint8List.fromList([frameOutboundPrefix, 1, 0, respCodeOk]));
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

  test('TcpDeviceLink requests and parses the exported private key', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final key = Uint8List.fromList(List.generate(64, (i) => (i * 7 + 1) % 256));
    final requested = Completer<Uint8List>();
    server.listen((socket) {
      final buffer = <int>[];
      socket.listen((data) {
        buffer.addAll(data);
        while (buffer.length >= 3) {
          final length = buffer[1] | (buffer[2] << 8);
          if (buffer.length < 3 + length) break;
          final frame = Uint8List.fromList(buffer.sublist(3, 3 + length));
          buffer.removeRange(0, 3 + length);
          if (!requested.isCompleted) requested.complete(frame);
          final reply = Uint8List.fromList([respCodePrivateKey, ...key]);
          socket.add(Uint8List.fromList([
            frameOutboundPrefix,
            reply.length & 0xFF,
            reply.length >> 8,
            ...reply,
          ]));
        }
      });
    });

    final link = TcpDeviceLink(
      host: '127.0.0.1',
      port: server.port,
      requestTimeout: const Duration(seconds: 2),
    );
    await link.connect();
    expect(await link.exportPrivateKey(), key);
    expect((await requested.future)[0], cmdExportPrivateKey);

    await link.disconnect();
    await server.close();
  });

  test('device_rejects_inbound_prefix', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      final buffer = <int>[];
      socket.listen((data) {
        buffer.addAll(data);
        while (buffer.length >= 3) {
          final length = buffer[1] | (buffer[2] << 8);
          if (buffer.length < 3 + length) break;
          buffer.removeRange(0, 3 + length);

          Uint8List info(int fw) => (BufferWriter()
                ..writeByte(respCodeDeviceInfo)
                ..writeByte(fw)
                ..writeByte(1)
                ..writeByte(1)
                ..writeUInt32Le(0)
                ..writeCString('build', 12)
                ..writeCString('Acme', 40)
                ..writeCString('fw 1.0', 20)
                ..writeByte(0)
                ..writeByte(0))
              .toBytes();

          // A reply in the app→device direction is not a device reply.
          final wrong = info(99);
          socket.add([
            frameInboundPrefix,
            wrong.length & 0xFF,
            wrong.length >> 8,
            ...wrong,
          ]);
          final correct = info(11);
          socket.add([
            frameOutboundPrefix,
            correct.length & 0xFF,
            correct.length >> 8,
            ...correct,
          ]);
        }
      });
    });

    final link = TcpDeviceLink(
      host: '127.0.0.1',
      port: server.port,
      requestTimeout: const Duration(seconds: 2),
    );
    await link.connect();
    final info = await link.deviceInfo();
    expect(info.firmwareVerCode, 11);

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

  test('TcpDeviceLink forwards the explicit client repeat byte', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = Completer<Uint8List>();
    server.listen((socket) {
      final buffer = <int>[];
      socket.listen((data) {
        buffer.addAll(data);
        if (buffer.length < 3) return;
        final length = buffer[1] | (buffer[2] << 8);
        if (buffer.length < 3 + length) return;
        if (!received.isCompleted) {
          received.complete(Uint8List.fromList(buffer.sublist(3, 3 + length)));
        }
        socket.add([frameOutboundPrefix, 1, 0, respCodeOk]);
      });
    });
    final link = TcpDeviceLink(
      host: '127.0.0.1',
      port: server.port,
      requestTimeout: const Duration(seconds: 2),
    );
    await link.connect();
    await link.setRadioParams(
      const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      ),
      clientRepeat: true,
    );
    final frame = await received.future;
    expect(frame[0], cmdSetRadioParams);
    expect(frame.last, 1);
    await link.disconnect();
    await server.close();
  });

  test('device_err6_is_preserved_and_cache_unchanged', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) => _replyOnce(socket, [respCodeErr, 6]));
    final link = TcpDeviceLink(
      host: '127.0.0.1',
      port: server.port,
      requestTimeout: const Duration(seconds: 2),
    );
    await link.connect();

    await expectLater(
      link.setRadioParams(const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      )),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.device)
          .having((e) => e.code, 'code', 6)
          .having((e) => e.mayHaveApplied, 'mayHaveApplied', isFalse)),
    );

    await link.disconnect();
    await server.close();
  });

  test('malformed_err_and_self_info_fail_safely', () async {
    final errServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    errServer.listen((socket) => _replyOnce(socket, [respCodeErr]));
    final errLink = TcpDeviceLink(
      host: '127.0.0.1',
      port: errServer.port,
      requestTimeout: const Duration(seconds: 1),
    );
    await errLink.connect();
    await expectLater(
      errLink.setTxPower(10),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.malformed)),
    );
    await errLink.disconnect();
    await errServer.close();

    final infoServer = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    infoServer.listen((socket) => _replyOnce(socket, [respCodeSelfInfo, 1, 2]));
    final infoLink = TcpDeviceLink(
      host: '127.0.0.1',
      port: infoServer.port,
      requestTimeout: const Duration(seconds: 1),
    );
    await infoLink.connect();
    await expectLater(
      infoLink.selfInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.malformed)),
    );
    await infoLink.disconnect();
    await infoServer.close();
  });

  test('tx_and_tuning_setters_also_await_ack', () async {
    await _expectSetterAwaitsAck(
      (link) => link.setRadioParams(const RadioParams(
        frequencyHz: 915000000,
        bandwidthHz: 250000,
        spreadingFactor: 10,
        codingRate: 5,
      )),
    );
    await _expectSetterAwaitsAck((link) => link.setTxPower(10));
    await _expectSetterAwaitsAck(
      (link) => link.setTuningParams(
        const TuningParams(rxDelayBaseMs: 100, airtimeFactorMs: 200),
      ),
    );
  });
}

/// Reply once to the first framed request with [reply].
void _replyOnce(Socket socket, List<int> reply) {
  final buffer = <int>[];
  var replied = false;
  socket.listen((data) {
    buffer.addAll(data);
    if (replied || buffer.length < 3) return;
    final length = buffer[1] | (buffer[2] << 8);
    if (buffer.length < 3 + length) return;
    replied = true;
    socket.add([
      frameOutboundPrefix,
      reply.length & 0xFF,
      reply.length >> 8,
      ...reply,
    ]);
  });
}

Future<void> _expectSetterAwaitsAck(
  Future<void> Function(TcpDeviceLink link) action,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final requestSeen = Completer<void>();
  late Socket serverSocket;
  server.listen((socket) {
    serverSocket = socket;
    final buffer = <int>[];
    socket.listen((data) {
      buffer.addAll(data);
      if (buffer.length < 3) return;
      final length = buffer[1] | (buffer[2] << 8);
      if (buffer.length < 3 + length) return;
      if (!requestSeen.isCompleted) requestSeen.complete();
    });
  });
  final link = TcpDeviceLink(
    host: '127.0.0.1',
    port: server.port,
    requestTimeout: const Duration(seconds: 2),
  );
  await link.connect();

  var completed = false;
  final future = action(link).then((_) {
    completed = true;
  });
  await requestSeen.future.timeout(const Duration(seconds: 2));
  await Future<void>.delayed(const Duration(milliseconds: 20));
  expect(completed, isFalse, reason: 'no reply before the device ACK');
  serverSocket.add([frameOutboundPrefix, 1, 0, respCodeOk]);
  await future;

  await link.disconnect();
  await server.close();
}
