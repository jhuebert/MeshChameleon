import 'dart:io';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/identity_screen.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:provider/provider.dart';

const _capabilities = DeviceCapabilities(
  supportsBle: false,
  supportsSimulatedCompanion: true,
);

class _FailIdentityStore extends IdentityStore {
  _FailIdentityStore(this.old);

  final LocalIdentity old;

  @override
  Future<LocalIdentity?> load() async => old;

  @override
  Future<void> save(LocalIdentity identity) async {
    throw const FileSystemException('secure key write failed');
  }
}

Future<NodeState> _populatedState(LocalIdentity peer) async => NodeState(
      prefs: NodePrefs(nodeName: 'Old Name', pathHashMode: 2),
      contacts: [Contact(publicKey: peer.publicKey, name: 'Old Contact')],
      channels: {
        3: Channel(
          name: 'Old Channel',
          secret: Uint8List.fromList(List.filled(16, 9)),
        ),
      },
      queue: [QueuedMessage(senderKey: peer.publicKey, text: 'Old Queue')],
      advertPaths: {
        'aabbccddeeff00': AdvertPath(
          publicKeyPrefix: Uint8List.fromList(
            [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF, 0],
          ),
          name: 'Old Path',
          pathLen: 1,
          path: Uint8List.fromList([1]),
        ),
      },
    );

class _FailingNodeStore implements NodeStore {
  _FailingNodeStore(this.old);

  final NodeState old;

  @override
  Future<NodeState?> load() async => old.copy();

  @override
  Future<void> save(NodeState state) async {
    throw const FileSystemException('state reset save failed');
  }

  @override
  Future<void> flush() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppState cancelApp;
  late InMemoryNodeStore cancelStore;
  late LocalIdentity cancelIdentity;
  late Directory cancelDir;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    cancelDir = await Directory.systemTemp.createTemp('mesh_reset_ui_');
    cancelIdentity = await LocalIdentity.generate();
    final peer = await LocalIdentity.generate();
    final store = IdentityStore();
    await store.save(cancelIdentity);
    cancelStore = InMemoryNodeStore();
    await cancelStore.save(await _populatedState(peer));
    cancelApp = AppState(
      store: store,
      nodeStore: cancelStore,
      sessionStore: SessionStore(file: File('${cancelDir.path}/session.json')),
      capabilities: _capabilities,
    )..identity = cancelIdentity;
  });

  tearDown(() async {
    await cancelDir.delete(recursive: true);
  });

  testWidgets('cancel_reset_has_no_effect', (tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: cancelApp,
        child: const MaterialApp(home: IdentityScreen()),
      ),
    );
    expect(find.text('Reset virtual data'), findsOneWidget);
    await tester.drag(find.byType(ListView), const Offset(0, -400));
    await tester.pump();
    await tester.tap(find.text('Reset virtual data'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Reset virtual data?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final state = await cancelStore.load();
    expect(state!.prefs.nodeName, 'Old Name');
    expect(state.contacts.single.name, 'Old Contact');
    expect(state.queue.single.text, 'Old Queue');
    expect(cancelApp.identity!.publicKey, cancelIdentity.publicKey);
  });

  test('state_save_failure_preserves_old_state_and_reports_failure', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('mesh_reset_fail_');
    addTearDown(() => dir.delete(recursive: true));
    final identity = await LocalIdentity.generate();
    final peer = await LocalIdentity.generate();
    final nodeStore = _FailingNodeStore(await _populatedState(peer));
    final app = AppState(
      store: IdentityStore(),
      nodeStore: nodeStore,
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      capabilities: _capabilities,
    )..identity = identity;

    await expectLater(
      app.resetVirtualData(),
      throwsA(isA<CompanionOperationError>()
          .having((e) => e.code, 'code', errCodeFileIoError)),
    );
    expect(app.identity!.publicKey, identity.publicKey);
    expect(app.node, isNull);
    final retained = await nodeStore.load();
    expect(retained!.prefs.nodeName, 'Old Name');
    expect(retained.contacts.single.name, 'Old Contact');
  });

  test('reset_scopes_preserve_session_and_make_zero_physical_writes', () async {
    final values = <String, String>{};
    FlutterSecureStorage.setMockInitialValues(values);
    final dir = await Directory.systemTemp.createTemp('mesh_reset_app_');
    addTearDown(() => dir.delete(recursive: true));
    final sessionFile = File('${dir.path}/session.json');
    final store = IdentityStore();
    final identity = await LocalIdentity.generate();
    await store.save(identity);
    final app = AppState(
      store: store,
      nodeStore: InMemoryNodeStore(),
      sessionStore: SessionStore(file: sessionFile),
      capabilities: _capabilities,
    );
    app
      ..identity = identity
      ..port = 5555
      ..autoResume = true;
    final link = FakeDeviceLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    await app.connectSimulated(simulatedLink: link);
    addTearDown(app.disconnectDevice);
    final node = app.node!;
    await node.setAdvertName('Old Virtual');
    await node.addUpdateContact(Contact(
      publicKey: (await LocalIdentity.generate()).publicKey,
      name: 'Old Contact',
    ));
    final sessionBefore = await SessionStore(file: sessionFile).load();
    final callsBefore = List<String>.of(link.calls);

    final dataOnly = await app.resetVirtualData();
    expect(dataOnly.success, isTrue);
    expect(dataOnly.identityRotated, isFalse);
    expect(app.identity!.publicKey, identity.publicKey);
    expect(app.node!.identity.publicKey, identity.publicKey);
    expect(app.node!.prefs.nodeName, 'MeshChameleon');
    expect(app.node!.contacts, isEmpty);
    expect(app.deviceConnected, isTrue);

    final rotated = await app.resetVirtualData(rotateIdentity: true);
    expect(rotated.success, isTrue);
    expect(rotated.identityRotated, isTrue);
    expect(app.identity!.publicKey, isNot(identity.publicKey));
    expect(app.node!.identity.publicKey, app.identity!.publicKey);
    expect(app.node!.contacts, isEmpty);
    expect(app.port, 5555);
    expect(app.deviceConnected, isTrue);

    final sessionAfter = await SessionStore(file: sessionFile).load();
    expect(sessionAfter!.kind, sessionBefore!.kind);
    expect(sessionAfter.host, sessionBefore.host);
    expect(sessionAfter.devicePort, sessionBefore.devicePort);
    expect(sessionAfter.proxyPort, sessionBefore.proxyPort);
    expect(sessionAfter.autoResume, sessionBefore.autoResume);
    expect(sessionAfter.intentionallyOff, isFalse);
    expect(
      link.calls.sublist(callsBefore.length).where((c) =>
          c == 'sendRawPacket' ||
          c == 'reboot' ||
          c == 'shutdown' ||
          c == 'runCliCommand' ||
          c == 'setRadioParams' ||
          c == 'setTxPower' ||
          c == 'setTuningParams'),
      isEmpty,
    );
  });

  test('key_save_failure_after_data_reset_reports_partial_result_honestly',
      () async {
    FlutterSecureStorage.setMockInitialValues({});
    final dir = await Directory.systemTemp.createTemp('mesh_reset_partial_');
    addTearDown(() => dir.delete(recursive: true));
    final old = await LocalIdentity.generate();
    final peer = await LocalIdentity.generate();
    final failStore = _FailIdentityStore(old);
    final nodeStore = InMemoryNodeStore();
    await nodeStore.save(await _populatedState(peer));
    final app = AppState(
      store: failStore,
      nodeStore: nodeStore,
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      capabilities: _capabilities,
    )..identity = old;

    final result = await app.resetVirtualData(rotateIdentity: true);

    expect(result.dataReset, isTrue);
    expect(result.identityRotated, isFalse);
    expect(result.partialKeyFailure, isTrue);
    expect(result.keyError?.code, errCodeFileIoError);
    expect(app.identity!.publicKey, old.publicKey,
        reason: 'old identity remains active after partial key failure');
    final state = await nodeStore.load();
    expect(state!.prefs.nodeName, 'MeshChameleon');
    expect(state.contacts, isEmpty);
    expect(state.channels.keys, [0]);
    expect(state.queue, isEmpty);
    expect(app.node, isNull, reason: 'a disconnected reset stays disconnected');
  });
}
