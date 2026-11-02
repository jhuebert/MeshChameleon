import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  late _ScriptedDevice device;
  late TcpDeviceLink link;

  tearDown(() async {
    await link.disconnect();
    await device.close();
  });

  Future<TcpDeviceLink> newLink({
    Duration requestTimeout = const Duration(seconds: 2),
    void Function(String message)? onLog,
    bool connect = true,
  }) async {
    link = TcpDeviceLink(
      host: '127.0.0.1',
      port: device.port,
      requestTimeout: requestTimeout,
      onLog: onLog,
    );
    if (connect) await link.connect();
    return link;
  }

  test('connect failures surface and leave the link disconnected', () async {
    device = await _ScriptedDevice.start((frame, socket) {});
    await newLink();

    final unused = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = unused.port;
    await unused.close();

    final failing = TcpDeviceLink(host: '127.0.0.1', port: port);
    await expectLater(failing.connect(), throwsA(isA<SocketException>()));
    expect(failing.currentState, LinkState.disconnected);
  });

  test('handshake, stats, tuning, and radio params parse device replies',
      () async {
    device = await _ScriptedDevice.start((frame, socket) {
      switch (frame[0]) {
        case cmdDeviceQuery:
          _reply(socket, _deviceInfo());
        case cmdAppStart:
          _reply(socket, _selfInfo());
        case cmdGetStats:
          _reply(socket, _radioStats());
        case cmdGetTuningParams:
          _reply(socket, _tuning());
      }
    });
    await newLink();

    final info = await link.deviceInfo();
    expect(info.firmwareVerCode, targetFirmwareVerCode);
    expect(info.manufacturer, 'Acme');
    expect(info.maxContacts, 510);

    final self = await link.selfInfo();
    expect(self.nodeName, 'dev');
    expect(self.radioParams.frequencyHz, 915000000);

    final params = await link.radioParams();
    expect(params.spreadingFactor, 10);

    final stats = await link.radioStats();
    expect(stats.noiseFloorDbm, -110);

    final tuning = await link.tuningParams();
    expect(tuning.rxDelayBaseMs, 100);
    expect(tuning.airtimeFactorMs, 200);
  });

  test('a non-matching frame does not complete the pending request', () async {
    var queries = 0;
    device = await _ScriptedDevice.start((frame, socket) {
      if (frame[0] != cmdDeviceQuery) return;
      queries++;
      _reply(socket, [respCodeOk]);
      Future<void>.delayed(const Duration(milliseconds: 10), () {
        _reply(socket, _deviceInfo());
      });
    });
    await newLink();

    final info = await link.deviceInfo();
    expect(info.firmwareVerCode, targetFirmwareVerCode);
    expect(queries, 1);
  });

  test('radio RX pushes reach the listener and empty frames are ignored',
      () async {
    device = await _ScriptedDevice.start((frame, socket) {
      if (frame[0] != cmdDeviceQuery) return;
      socket.add(Uint8List.fromList([frameOutboundPrefix, 0, 0])); // empty
      _reply(socket, [pushCodeLogRxData, 24, 186, 1, 2, 3]);
      _reply(socket, _deviceInfo());
    });
    await newLink();
    final received = <(double, int, Uint8List)>[];
    link.setRawRxListener((snr, rssi, raw) => received.add((snr, rssi, raw)));

    await link.deviceInfo();
    expect(received, hasLength(1));
    expect(received.single.$1, 6.0);
    expect(received.single.$2, -70);
    expect(received.single.$3, [1, 2, 3]);
  });

  test('setters accept OK and reject DISABLED', () async {
    var disabled = false;
    device = await _ScriptedDevice.start((frame, socket) {
      switch (frame[0]) {
        case cmdSetRadioParams:
        case cmdSetTuningParams:
        case cmdSetPathHashMode:
          _reply(socket, [disabled ? respCodeDisabled : respCodeOk]);
        case cmdSetRadioTxPower:
          _reply(socket, [respCodeOk]);
      }
    });
    await newLink();

    await link.setRadioParams(_params(), clientRepeat: true);
    await link.setTxPower(17);
    await link.setTuningParams(
      const TuningParams(rxDelayBaseMs: 1, airtimeFactorMs: 2),
    );
    await link.setPathHashMode(1);

    disabled = true;
    await expectLater(
      link.setRadioParams(_params()),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disabled)),
    );
  });

  test('battery returns a reading, logs failures, and tolerates truncation',
      () async {
    final logs = <String>[];
    var reply = _batteryFrame().toList();
    device = await _ScriptedDevice.start((frame, socket) {
      if (frame[0] != cmdGetBattAndStorage) return;
      _reply(socket, reply);
    });
    await newLink(onLog: logs.add);

    final reading = await link.battery();
    expect(reading!.millivolts, 3700);
    expect(reading.storageUsedKb, 2);
    expect(reading.storageTotalKb, 4096);

    reply = [respCodeBattAndStorage, 1];
    expect(await link.battery(), isNull);
    expect(logs, isNotEmpty);
  });

  test('CLI, allowed repeat frequencies, and raw TX use their reply types',
      () async {
    device = await _ScriptedDevice.start((frame, socket) {
      switch (frame[0]) {
        case cmdRunCliCommand:
          _reply(socket, [respCodeCliReply, ...'OK'.codeUnits]);
        case cmdGetAllowedRepeatFreq:
          _reply(socket, [respCodeAllowedRepeatFreq, 1, 2, 3]);
        case cmdSendRawPacket:
          _reply(socket, [respCodeErr, errCodeTableFull]);
      }
    });
    await newLink();

    expect(await link.runCliCommand('ver'), 'OK');
    expect(await link.getAllowedRepeatFreq(), [1, 2, 3]);
    await expectLater(
      link.sendRawPacket(Uint8List.fromList([1, 2])),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.code, 'code', errCodeTableFull)),
    );
  });

  test('disabled CLI replies preserve the disabled kind', () async {
    device = await _ScriptedDevice.start((frame, socket) {
      if (frame[0] == cmdRunCliCommand) {
        _reply(socket, [respCodeDisabled]);
      }
    });
    await newLink();

    await expectLater(
      link.runCliCommand('ver'),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disabled)),
    );
  });

  test('malformed stats and tuning replies are rejected', () async {
    device = await _ScriptedDevice.start((frame, socket) {
      if (frame[0] == cmdGetStats) _reply(socket, [respCodeStats]);
      if (frame[0] == cmdGetTuningParams) {
        _reply(socket, [respCodeTuningParams]);
      }
    });
    await newLink();

    await expectLater(link.radioStats(), throwsA(isA<DeviceCommandError>()));
    await expectLater(link.tuningParams(), throwsA(isA<DeviceCommandError>()));
  });

  test('timeouts map to timeout errors', () async {
    device = await _ScriptedDevice.start((frame, socket) {});
    await newLink(requestTimeout: const Duration(milliseconds: 30));

    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.timeout)
          .having((e) => e.mayHaveApplied, 'mayHaveApplied', isTrue)),
    );
  });

  test('a timeout drops the link so a late reply cannot satisfy the next call',
      () async {
    device = await _ScriptedDevice.start((frame, socket) {
      if (frame[0] != cmdDeviceQuery) return;
      Future<void>.delayed(const Duration(milliseconds: 80), () {
        _reply(socket, _deviceInfo());
      });
    });
    await newLink(requestTimeout: const Duration(milliseconds: 20));

    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.timeout)),
    );
    expect(link.currentState, LinkState.disconnected);

    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disconnected)),
    );
  });

  test('a closed device link fails the pending request', () async {
    device = await _ScriptedDevice.start((frame, socket) {
      if (frame[0] == cmdDeviceQuery) socket.destroy();
    });
    await newLink();

    await expectLater(
      link.deviceInfo(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disconnected)),
    );
    expect(link.currentState, LinkState.disconnected);
  });

  test('operations before connect report a disconnected link', () async {
    device = await _ScriptedDevice.start((frame, socket) {});
    await newLink(connect: false);

    await expectLater(
      link.reboot(),
      throwsA(isA<DeviceCommandError>()
          .having((e) => e.kind, 'kind', DeviceCommandErrorKind.disconnected)),
    );
    await expectLater(
      link.shutdown(),
      throwsA(isA<DeviceCommandError>()),
    );
    expect(link.currentState, LinkState.disconnected);
    await link.disconnect();
  });

  test('connect is idempotent and disconnect is safe twice', () async {
    device = await _ScriptedDevice.start((frame, socket) {});
    await newLink();
    await link.connect();
    final first = link.currentState;
    await link.connect();
    expect(link.currentState, first);
    await link.disconnect();
    await link.disconnect();
    expect(link.currentState, LinkState.disconnected);
  });

  test('parseDeviceInfo tolerates short and empty frames', () {
    expect(
      () => TcpDeviceLink.parseDeviceInfo(Uint8List(3)),
      throwsA(isA<DeviceCommandError>()),
    );

    final minimal = Uint8List.fromList([respCodeDeviceInfo, 11, 0, 0]);
    final info = TcpDeviceLink.parseDeviceInfo(minimal);
    expect(info.maxContacts, const DeviceInfo().maxContacts);
    expect(info.maxChannels, const DeviceInfo().maxChannels);
    expect(info.manufacturer, '');
    expect(info.version, '');
    expect(info.clientRepeat, 0);
    expect(info.pathHashMode, 0);
  });

  test('parseDeviceInfo clamps path-hash mode and reads repeat', () {
    final frame = _deviceInfo(clientRepeat: 1, pathHashMode: 0xFF);
    final info = TcpDeviceLink.parseDeviceInfo(frame);
    expect(info.clientRepeat, 1);
    expect(info.pathHashMode, 3);
  });

  test('reboot flushes the lifecycle frame without awaiting a reply', () async {
    final received = Completer<Uint8List>();
    device = await _ScriptedDevice.start((frame, socket) {
      if (!received.isCompleted) received.complete(frame);
    });
    await newLink();

    await link.reboot();
    final frame = await received.future;
    expect(frame[0], cmdReboot);
    expect(String.fromCharCodes(frame.sublist(1)), 'reboot');
  });

  test('raw writes report disconnected when the socket write fails', () async {
    device = await _ScriptedDevice.start((frame, socket) {});
    await newLink();
    await link.connect();
    // Destroy the server side but keep the client's socket object around so
    // the write path is exercised before the close is observed.
    await device.destroySockets();
    await expectLater(
      link.sendRawPacket(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<DeviceCommandError>()),
    );
  });
}

RadioParams _params() => const RadioParams(
      frequencyHz: 915000000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
    );

Uint8List _deviceInfo({int clientRepeat = 0, int pathHashMode = 0}) =>
    (BufferWriter()
          ..writeByte(respCodeDeviceInfo)
          ..writeByte(targetFirmwareVerCode)
          ..writeByte(255)
          ..writeByte(8)
          ..writeUInt32Le(0)
          ..writeCString('build', 12)
          ..writeCString('Acme', 40)
          ..writeCString('fw 1.0', 20)
          ..writeByte(clientRepeat)
          ..writeByte(pathHashMode))
        .toBytes();

Uint8List _selfInfo() => (BufferWriter()
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
      ..writeUInt32Le(915000)
      ..writeUInt32Le(250000)
      ..writeByte(10)
      ..writeByte(5)
      ..writeCString('dev', 4))
    .toBytes();

Uint8List _radioStats() => (BufferWriter()
      ..writeByte(respCodeStats)
      ..writeByte(statsTypeRadio)
      ..writeUInt16Le(0xFF92)
      ..writeByte(0xC0)
      ..writeByte(24)
      ..writeUInt32Le(1)
      ..writeUInt32Le(2))
    .toBytes();

Uint8List _tuning() => (BufferWriter()
      ..writeByte(respCodeTuningParams)
      ..writeUInt32Le(100)
      ..writeUInt32Le(200))
    .toBytes();

Uint8List _batteryFrame() => (BufferWriter()
      ..writeByte(respCodeBattAndStorage)
      ..writeUInt16Le(3700)
      ..writeUInt32Le(2)
      ..writeUInt32Le(4096))
    .toBytes();

void _reply(Socket socket, List<int> payload) {
  socket.add([
    frameOutboundPrefix,
    payload.length & 0xFF,
    (payload.length >> 8) & 0xFF,
    ...payload,
  ]);
}

class _ScriptedDevice {
  _ScriptedDevice._(this._server) {
    _server.listen(_accept);
  }

  final ServerSocket _server;
  final List<Socket> _sockets = [];

  int get port => _server.port;

  static Future<_ScriptedDevice> start(
    void Function(Uint8List frame, Socket socket) handler,
  ) async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final device = _ScriptedDevice._(server);
    device._handler = handler;
    return device;
  }

  late final void Function(Uint8List frame, Socket socket) _handler;

  void _accept(Socket socket) {
    _sockets.add(socket);
    final buffer = <int>[];
    socket.listen((data) {
      buffer.addAll(data);
      while (buffer.length >= 3) {
        final length = buffer[1] | (buffer[2] << 8);
        if (buffer.length < 3 + length) return;
        final frame = Uint8List.fromList(buffer.sublist(3, 3 + length));
        buffer.removeRange(0, 3 + length);
        _handler(frame, socket);
      }
    }, onError: (_) {});
  }

  Future<void> destroySockets() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
  }

  Future<void> close() async {
    await destroySockets();
    await _server.close();
  }
}
