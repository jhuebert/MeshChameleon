import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

import '../tool/proxy_cli.dart';

/// Minimal framed client, standing in for `meshcore-cli`/`meshcore-open`.
class _Client {
  _Client(this._socket) {
    _socket.listen((data) {
      for (final frame in _codec.ingest(data)) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(frame);
        } else {
          _buffer.add(frame);
        }
      }
    });
  }

  final Socket _socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final List<Uint8List> _buffer = [];
  final List<Completer<Uint8List>> _waiters = [];

  void send(List<int> payload) =>
      _socket.add(_codec.encodeFrame(payload, prefix: frameInboundPrefix));

  Future<Uint8List> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final completer = Completer<Uint8List>();
    _waiters.add(completer);
    return completer.future;
  }

  Future<void> close() => _socket.close();
}

void main() {
  group('ProxyCliOptions.parse', () {
    test('defaults to the simulated companion', () {
      final options = ProxyCliOptions.parse(const []);
      expect(options.usesSimulatedCompanion, isTrue);
      expect(options.proxyPort, defaultCompanionPort);
    });

    test('accepts an explicit simulated companion', () {
      final options = ProxyCliOptions.parse(const ['--simulated']);
      expect(options.usesSimulatedCompanion, isTrue);
    });

    test('parses a device host and port', () {
      final options = ProxyCliOptions.parse(
        const ['--device', '192.168.1.50:9505', '--proxy-port', '7000'],
      );
      expect(options.usesSimulatedCompanion, isFalse);
      expect(options.deviceHost, '192.168.1.50');
      expect(options.devicePort, 9505);
      expect(options.proxyPort, 7000);
    });

    test('defaults the device port', () {
      final options = ProxyCliOptions.parse(const ['--device', 'radio.local']);
      expect(options.deviceHost, 'radio.local');
      expect(options.devicePort, defaultCompanionPort);
    });

    test('rejects conflicting transports', () {
      expect(
        () => ProxyCliOptions.parse(const [
          '--simulated',
          '--device',
          'radio.local',
        ]),
        throwsFormatException,
      );
    });

    test('rejects invalid ports and unknown flags', () {
      expect(
        () => ProxyCliOptions.parse(const ['--proxy-port', 'x']),
        throwsFormatException,
      );
      expect(
        () => ProxyCliOptions.parse(const ['--proxy-port', '70000']),
        throwsFormatException,
      );
      expect(
        () => ProxyCliOptions.parse(const ['--nope']),
        throwsFormatException,
      );
    });
  });

  test('serves the companion protocol over the simulated companion', () async {
    final handle = await startProxyCli(
      ProxyCliOptions.parse(const ['--simulated', '--proxy-port', '0']),
    );
    addTearDown(handle.close);
    expect(handle.port, isNotNull);

    final socket = await Socket.connect('127.0.0.1', handle.port!);
    final client = _Client(socket);
    addTearDown(client.close);

    client.send([cmdDeviceQuery, appProtocolVersion]);
    expect((await client.next())[0], respCodeDeviceInfo);

    client.send([cmdAppStart, appProtocolVersion]);
    final selfInfo = await client.next();
    expect(selfInfo[0], respCodeSelfInfo);
    expect(ParsedSelfInfo.parse(selfInfo), isNotNull);
  });

  test('persists the proxy identity when asked to', () async {
    final dir = await Directory.systemTemp.createTemp('meshchameleon_cli_');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/identity.hex';
    final options = ProxyCliOptions.parse(
      ['--identity-file', path, '--proxy-port', '0'],
    );

    final first = await startProxyCli(options);
    final initialKey = first.node.identity.publicKey;
    final written = File(path);
    expect(await written.exists(), isTrue);
    expect((await written.stat()).mode & 0x1FF, 0x180, reason: 'mode 0600');

    final socket = await Socket.connect('127.0.0.1', first.port!);
    final client = _Client(socket);
    addTearDown(client.close);
    final replacement =
        await LocalIdentity.fromSeed(Uint8List(32)..[0] = 42);
    client.send([cmdImportPrivateKey, ...replacement.meshcore64]);
    expect(await client.next(), [respCodeOk]);
    expect(first.node.identity.publicKey, replacement.publicKey);
    expect(first.node.identity.publicKey, isNot(initialKey));
    await client.close();
    await first.close();

    expect(await written.readAsString(),
        bytesToHex(replacement.meshcore64));
    expect((await written.stat()).mode & 0x1FF, 0x180,
        reason: 'atomic replacement preserves mode 0600');

    final second = await startProxyCli(options);
    addTearDown(second.close);
    expect(second.node.identity.publicKey, replacement.publicKey);
  });

  test('headless ephemeral import lasts until the proxy exits', () async {
    final options = ProxyCliOptions.parse(
      const ['--simulated', '--proxy-port', '0'],
    );
    final handle = await startProxyCli(options);
    final socket = await Socket.connect('127.0.0.1', handle.port!);
    final client = _Client(socket);
    addTearDown(client.close);

    final replacement =
        await LocalIdentity.fromSeed(Uint8List(32)..[0] = 43);
    client.send([cmdImportPrivateKey, ...replacement.meshcore64]);
    expect(await client.next(), [respCodeOk]);
    expect(handle.node.identity.publicKey, replacement.publicKey);

    client.send([cmdExportPrivateKey]);
    final exported = await client.next();
    expect(exported[0], respCodePrivateKey);
    expect(exported.sublist(1), replacement.meshcore64);

    await client.close();
    await handle.close();
  });
}
