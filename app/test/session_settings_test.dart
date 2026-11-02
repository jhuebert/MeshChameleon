import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/session_settings.dart';
import 'package:meshchameleon/services/session_store.dart';

class _FailingSessionStore extends SessionStore {
  _FailingSessionStore() : super(file: File('/tmp/unused-session.json'));

  @override
  Future<void> save(SessionConfig config) async {
    throw const FileSystemException('disk full');
  }
}

void main() {
  late Directory dir;
  late SessionStore store;
  late List<String> logs;
  late SessionSettings settings;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session_settings_');
    store = SessionStore(file: File('${dir.path}/session.json'));
    logs = [];
    settings = SessionSettings(store: store, onLog: logs.add);
  });

  tearDown(() => dir.delete(recursive: true));

  test('load restores the saved session settings', () async {
    await store.save(const SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: '192.168.1.2',
      devicePort: 5000,
      proxyPort: 5100,
      autoResume: true,
      intentionallyOff: true,
    ));

    await settings.load();

    expect(settings.lastSession!.host, '192.168.1.2');
    expect(settings.port, 5100);
    expect(settings.autoResume, isTrue);
    expect(settings.intentionallyOff, isTrue);
  });

  test('a missing session clears resume and shutdown flags', () async {
    settings.port = 5100;
    await settings.setAutoResume(true);
    await settings.load();

    expect(settings.lastSession, isNull);
    expect(settings.port, 5100);
    expect(settings.autoResume, isFalse);
    expect(settings.intentionallyOff, isFalse);
  });

  test('record saves the session and clears a shutdown', () async {
    await settings.markPoweredOff();
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
      proxyPort: 5100,
    ));

    expect(settings.intentionallyOff, isFalse);
    expect((await store.load())!.kind, DeviceTargetKind.simulated);
  });

  test('setPort validates and updates the saved session', () async {
    settings.port = 5100;
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
      proxyPort: 5100,
    ));

    expect(await settings.setPort(0), isFalse);
    expect(await settings.setPort(70000), isFalse);
    expect(settings.port, 5100);

    expect(await settings.setPort(5200), isTrue);
    expect(settings.port, 5200);
    expect((await store.load())!.proxyPort, 5200);
  });

  test('setAutoResume updates the saved session', () async {
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
      autoResume: false,
    ));

    await settings.setAutoResume(true);

    expect(settings.autoResume, isTrue);
    expect((await store.load())!.autoResume, isTrue);
  });

  test('markPoweredOff suppresses resume synchronously and persists', () async {
    await settings.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
    ));

    final persisted = settings.markPoweredOff();
    expect(settings.intentionallyOff, isTrue);
    await persisted;

    expect((await store.load())!.intentionallyOff, isTrue);
  });

  test('save failures are logged without throwing', () async {
    final failing = SessionSettings(
      store: _FailingSessionStore(),
      onLog: logs.add,
    );

    await failing.record(const SessionConfig(
      kind: DeviceTargetKind.simulated,
    ));
    expect(await failing.setPort(5200), isTrue);
    await failing.setAutoResume(true);
    await failing.markPoweredOff();

    expect(logs, hasLength(4));
    expect(logs, everyElement(contains('Could not')));
    expect(failing.port, 5200);
    expect(failing.autoResume, isTrue);
    expect(failing.intentionallyOff, isTrue);
  });
}
