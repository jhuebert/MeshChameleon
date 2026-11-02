import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/main.dart';
import 'package:meshchameleon/screens/identities_screen.dart';
import 'package:meshchameleon/services/device_capabilities.dart';
import 'package:meshchameleon/services/identity_index.dart';
import 'package:meshchameleon/services/identity_runtime.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:provider/provider.dart';

const _capabilities = DeviceCapabilities(
  supportsBle: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late IdentityRepository repository;
  late AppState app;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    dir = await Directory.systemTemp.createTemp('mesh_identities_ui_');
    repository = IdentityRepository(
      supportDirectory: dir,
      secureStore: IdentityStore(),
    );
    app = AppState(
      repository: repository,
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore: NetworkConnectionStore(
        file: File('${dir.path}/network_connections.json'),
      ),
      capabilities: _capabilities,
    );
    await app.loadIdentities();
  });

  tearDown(() async {
    await app.disconnectDevice();
    await app.manager?.dispose();
    await dir.delete(recursive: true);
  });

  Widget wrap(Widget child) => ChangeNotifierProvider<AppState>.value(
        value: app,
        child: MaterialApp(home: child),
      );

  Future<void> tapAsync(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
  }

  testWidgets('home card shows the active name and prefix and opens the list',
      (tester) async {
    await tester.pumpWidget(wrap(const HomeScreen()));
    final summary = app.identities.single;
    expect(find.text(summary.name), findsWidgets);
    expect(find.textContaining('#${summary.prefixHex}'), findsWidgets);
    expect(find.textContaining('Ed25519'), findsNothing);

    await tester.tap(find.widgetWithText(Card, summary.name));
    await tester.pumpAndSettle();
    expect(find.byType(IdentitiesScreen), findsOneWidget);
    expect(find.text('Identities'), findsOneWidget);
  });

  testWidgets('list is active-first then alphabetical with live counts',
      (tester) async {
    final first = app.identities.single.id;
    await tester.runAsync(() async {
      await repository.create(name: 'beta');
      final alpha = await repository.create(name: 'Alpha');
      await repository.saveState(
        alpha.id,
        NodeState(
          prefs: NodePrefs(nodeName: 'Alpha'),
          channels: {
            0: Channel(
              name: 'Public',
              secret: Uint8List.fromList(
                LocalIdentity.defaultPublicChannelSecret,
              ),
            ),
          },
          contacts: [
            Contact(
              publicKey: (await LocalIdentity.generate()).publicKey,
              name: 'Peer',
            ),
          ],
          queue: [
            QueuedMessage(senderKey: Uint8List(0), text: 'dm'),
            QueuedMessage(
              senderKey: Uint8List(0),
              text: 'channel',
              isChannel: true,
            ),
          ],
        ),
      );
      await app.loadIdentities();
    });
    final alphaSummary =
        app.identities.firstWhere((summary) => summary.name == 'Alpha');
    expect(alphaSummary.channelCount, 1);
    expect(alphaSummary.contactCount, 1);
    expect(alphaSummary.queuedDirect, 1);
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();

    final titles = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .toList();
    final firstIndex = titles.indexOf('MeshChameleon');
    final alphaIndex = titles.indexOf('Alpha');
    final betaIndex = titles.indexOf('beta');
    expect(firstIndex, greaterThanOrEqualTo(0));
    expect(alphaIndex, greaterThan(firstIndex));
    expect(betaIndex, greaterThan(alphaIndex));
    expect(find.text('Active'), findsOneWidget);
    expect(find.text('1 channels · 1 contacts'), findsOneWidget);
    expect(
        find.text('1 DMs queued · 1 channel messages queued'), findsOneWidget);
    expect(find.textContaining(first), findsNothing);
  });

  testWidgets('create wizard prefills a unique default and creates inactive',
      (tester) async {
    await tester.runAsync(() async {
      await repository.create(name: 'Second');
      await app.loadIdentities();
    });
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();

    await tapAsync(tester, find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('New identity'), findsOneWidget);
    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'MeshChameleon 2');

    await tester.enterText(find.byType(TextField), 'Custom Node');
    await tapAsync(tester, find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Custom Node'), findsOneWidget);
    expect(app.identities, hasLength(3));
    expect(
        app.activeIdentityId,
        isNot(
          app.identities
              .firstWhere((summary) => summary.name == 'Custom Node')
              .id,
        ));
  });

  testWidgets('create wizard limits names by UTF-8 bytes and shows a counter',
      (tester) async {
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();
    await tapAsync(tester, find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('15/31 bytes'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'x' * 32);
    await tester.pumpAndSettle();
    expect(find.text('31/31 bytes'), findsOneWidget);

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, hasLength(31));

    await tapAsync(tester, find.text('Create'));
    await tester.pumpAndSettle();

    expect(app.identities, hasLength(2));
    expect(
      app.identities.any((summary) => summary.name == 'x' * 31),
      isTrue,
    );
  });

  testWidgets('create wizard counts multibyte characters in UTF-8 bytes',
      (tester) async {
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();
    await tapAsync(tester, find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'é' * 20);
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'é' * 15);
    expect(find.text('30/31 bytes'), findsOneWidget);
  });

  testWidgets('create wizard rejects control characters', (tester) async {
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();
    await tapAsync(tester, find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'bad\u0001name');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.text('Enter a valid name'), findsOneWidget);
    expect(find.text('New identity'), findsOneWidget);
    expect(app.identities, hasLength(1));
  });

  testWidgets('tapping an inactive identity activates it and returns home',
      (tester) async {
    late String secondId;
    await tester.runAsync(() async {
      secondId = (await repository.create(name: 'Second')).id;
      await app.loadIdentities();
    });
    await tester.pumpWidget(wrap(const HomeScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(Card, 'MeshChameleon'));
    await tester.pumpAndSettle();

    await tapAsync(tester, find.text('Second'));
    await tester.pumpAndSettle();

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(app.activeIdentityId, secondId);
    expect(
        find.textContaining('#${app.activeIdentity!.prefixHex}'), findsWidgets);
  });

  testWidgets('delete is disabled for the active identity and clear is present',
      (tester) async {
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('Clear local data'), findsOneWidget);
    final disableItem = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Disable identity'),
    );
    expect(disableItem.enabled, isFalse);
    final deleteItem = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Delete identity'),
    );
    expect(deleteItem.enabled, isFalse);
  });

  testWidgets('a non-active identity can be disabled and re-enabled',
      (tester) async {
    late String secondId;
    await tester.runAsync(() async {
      secondId = (await repository.create(name: 'Second')).id;
      await app.loadIdentities();
    });
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();

    final secondCardMenu = find.descendant(
      of: find.ancestor(of: find.text('Second'), matching: find.byType(Card)),
      matching: find.byType(PopupMenuButton<String>),
    );
    await tester.tap(secondCardMenu);
    await tester.pumpAndSettle();
    expect(find.text('Disable identity'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    final disabled = await tester.runAsync(
      () => app.setIdentityEnabled(secondId, false),
    );
    await tester.pump();

    expect(disabled, isTrue);
    expect(
      app.identities.firstWhere((summary) => summary.id == secondId).enabled,
      isFalse,
    );
    expect(find.textContaining('Disabled'), findsWidgets);

    await tester.tap(secondCardMenu);
    await tester.pumpAndSettle();
    expect(find.text('Enable identity'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    final enabled = await tester.runAsync(
      () => app.setIdentityEnabled(secondId, true),
    );
    await tester.pump();

    expect(enabled, isTrue);
    expect(
      app.identities.firstWhere((summary) => summary.id == secondId).enabled,
      isTrue,
    );
    expect(find.textContaining('Disabled'), findsNothing);
  });

  testWidgets('an unavailable key cannot activate but may be deleted',
      (tester) async {
    late String secondId;
    await tester.runAsync(() async {
      secondId = (await repository.create(name: 'Second')).id;
      await IdentityStore().deleteById(secondId);
      await app.loadIdentities();
    });
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();

    expect(find.text('Key unavailable'), findsOneWidget);
    final activeBefore = app.activeIdentityId;
    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(app.activeIdentityId, activeBefore);

    final secondCardMenu = find.descendant(
      of: find.ancestor(of: find.text('Second'), matching: find.byType(Card)),
      matching: find.byType(PopupMenuButton<String>),
    );
    await tester.tap(secondCardMenu);
    await tester.pumpAndSettle();
    final deleteItem = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, 'Delete identity'),
    );
    expect(deleteItem.enabled, isTrue);
  });

  testWidgets('no legacy identity controls or algorithm labels remain',
      (tester) async {
    await tester.pumpWidget(wrap(const IdentitiesScreen()));
    await tester.pumpAndSettle();

    expect(find.textContaining('Ed25519'), findsNothing);
    expect(find.textContaining('Generate'), findsNothing);
    expect(find.textContaining('Import'), findsNothing);
    expect(find.textContaining('Export'), findsNothing);
    expect(find.textContaining('Reset virtual data'), findsNothing);
  });

  testWidgets('corrupt catalog shows a recovery screen with retry',
      (tester) async {
    final corruptApp = AppState(
      repository: IdentityRepository(
        supportDirectory: Directory('${dir.path}/corrupt'),
        secureStore: IdentityStore(),
      ),
      sessionStore: SessionStore(file: File('${dir.path}/session.json')),
      networkConnectionStore: NetworkConnectionStore(
        file: File('${dir.path}/network_connections.json'),
      ),
      capabilities: _capabilities,
    );
    await tester.runAsync(() async {
      final index = File('${dir.path}/corrupt/identities/index.json');
      await index.parent.create(recursive: true);
      await index.writeAsString('{broken');
      await corruptApp.loadIdentities();
    });
    addTearDown(corruptApp.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppState>.value(
        value: corruptApp,
        child: const MaterialApp(home: IdentitiesScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Identity database unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('loading, empty, and busy states render their controls',
      (tester) async {
    final fake = _FakeIdentitiesAppState()..loaded = false;
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    fake
      ..loaded = true
      ..summaries = [];
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();
    expect(find.text('No identities yet'), findsOneWidget);
    expect(
        find.widgetWithText(FilledButton, 'Create identity'), findsOneWidget);

    fake.busy = true;
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    final fab = tester.widget<FloatingActionButton>(
      find.byType(FloatingActionButton),
    );
    expect(fab.onPressed, isNull);
  });

  testWidgets('the database retry button reloads identities', (tester) async {
    final fake = _FakeIdentitiesAppState()
      ..dbError = 'catalog damaged'
      ..busy = false;
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    expect(find.text('catalog damaged'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(fake.loadCalls, 1);

    fake.busy = true;
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Retry'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('activation failures and disabled identities show feedback',
      (tester) async {
    final fake = _FakeIdentitiesAppState()
      ..summaries = [
        _summary(id: 'a' * 32, name: 'Active', active: true, live: true),
        _summary(id: 'b' * 32, name: 'Second'),
        _summary(
          id: 'c' * 32,
          name: 'Disabled',
          enabled: false,
        ),
      ]
      ..activateResult = false;
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    await tester.tap(find.text('Second'));
    await tester.pumpAndSettle();
    expect(fake.activateCalls, ['b' * 32]);
    expect(find.text('Could not activate Second'), findsOneWidget);

    // A disabled identity cannot be activated.
    await tester.tap(find.text('Disabled'));
    await tester.pumpAndSettle();
    expect(fake.activateCalls, hasLength(1));
  });

  testWidgets('toggle failures show feedback', (tester) async {
    final fake = _FakeIdentitiesAppState()
      ..summaries = [
        _summary(id: 'a' * 32, name: 'Active', active: true, live: true),
        _summary(id: 'b' * 32, name: 'Second'),
      ]
      ..toggleResult = false;
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    await _openMenu(tester, 'Second');
    await tester.tap(find.text('Disable identity'));
    await tester.pumpAndSettle();
    expect(fake.toggleCalls, [('b' * 32, false)]);
    expect(find.text('Could not disable Second'), findsOneWidget);
  });

  testWidgets('create failures and cancellation show feedback', (tester) async {
    final fake = _FakeIdentitiesAppState()..summaries = [];
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    fake.suggestError = StateError('database');
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('Could not read the identity database'), findsOneWidget);
    _clearSnackBars(tester);

    fake.suggestError = null;
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.createdNames, isEmpty);

    fake.createResult = null;
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Could not create the identity'), findsOneWidget);
    _clearSnackBars(tester);

    fake.createResult = IdentityRecord(
      id: 'd' * 32,
      publicKey: Uint8List(32),
      name: 'Made',
      createdAt: 1,
    );
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Created Made (inactive)'), findsOneWidget);
  });

  testWidgets('clear local data confirms and reports both outcomes',
      (tester) async {
    final fake = _FakeIdentitiesAppState()
      ..summaries = [
        _summary(id: 'a' * 32, name: 'Active', active: true, live: true),
      ];
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    await _openMenu(tester, 'Active');
    await tester.tap(find.text('Clear local data'));
    await tester.pumpAndSettle();
    expect(find.text('Clear local data?'), findsOneWidget);
    expect(
        find.textContaining('The MeshCore app will reconnect'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.clearCalls, isEmpty);

    await _openMenu(tester, 'Active');
    await tester.tap(find.text('Clear local data'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(fake.clearCalls, ['a' * 32]);
    expect(find.text('Cleared local data for Active'), findsOneWidget);
    _clearSnackBars(tester);

    fake.clearResult = false;
    await _openMenu(tester, 'Active');
    await tester.tap(find.text('Clear local data'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Could not clear local data'), findsOneWidget);
  });

  testWidgets('delete confirms and reports both outcomes', (tester) async {
    final fake = _FakeIdentitiesAppState()
      ..summaries = [
        _summary(id: 'a' * 32, name: 'Active', active: true, live: true),
        _summary(id: 'b' * 32, name: 'Second'),
      ];
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    await _openMenu(tester, 'Second');
    await tester.tap(find.text('Delete identity'));
    await tester.pumpAndSettle();
    expect(find.text('Delete identity?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fake.deleteCalls, isEmpty);

    await _openMenu(tester, 'Second');
    await tester.tap(find.text('Delete identity'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(fake.deleteCalls, ['b' * 32]);
    expect(find.text('Deleted Second'), findsOneWidget);
    _clearSnackBars(tester);

    fake.deleteResult = false;
    await _openMenu(tester, 'Second');
    await tester.tap(find.text('Delete identity'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Could not delete Second'), findsOneWidget);
  });

  testWidgets('identity cards show live, inactive, and unavailable reasons',
      (tester) async {
    final fake = _FakeIdentitiesAppState()
      ..summaries = [
        _summary(id: 'a' * 32, name: 'Active', active: true, live: true),
        _summary(id: 'b' * 32, name: 'Live', live: true, enabled: false),
        _summary(
          id: 'c' * 32,
          name: 'Unavailable',
          unavailableReason: 'startup failed',
        ),
      ];
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    expect(find.textContaining('· Live'), findsOneWidget);
    expect(find.textContaining('· Disabled'), findsOneWidget);
    expect(find.text('startup failed'), findsOneWidget);
    expect(find.text('Key unavailable'), findsNothing);
  });

  testWidgets('the name dialog accepts Enter and rejects whitespace-only input',
      (tester) async {
    final fake = _FakeIdentitiesAppState()
      ..suggestion = 'Suggested Name'
      ..summaries = [];
    await tester.pumpWidget(_wrapFake(fake, const IdentitiesScreen()));
    await tester.pump();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.text('14/31 bytes'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(fake.createdNames, ['Suggested Name']);

    fake.createResult = null;
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(fake.createdNames, ['Suggested Name', 'Suggested Name']);
  });
}

void _clearSnackBars(WidgetTester tester) {
  final context = tester.element(find.byType(IdentitiesScreen));
  ScaffoldMessenger.of(context).clearSnackBars();
}

Widget _wrapFake(AppState app, Widget child) =>
    ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(home: child),
    );

Future<void> _openMenu(WidgetTester tester, String name) async {
  final menu = find.descendant(
    of: find.ancestor(of: find.text(name), matching: find.byType(Card)),
    matching: find.byType(PopupMenuButton<String>),
  );
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

IdentitySummary _summary({
  required String id,
  required String name,
  bool active = false,
  bool live = false,
  bool enabled = true,
  String? unavailableReason,
}) =>
    IdentitySummary(
      id: id,
      name: name,
      publicKey: Uint8List(32),
      createdAt: 1,
      active: active,
      live: live,
      enabled: enabled,
      keyAvailable: true,
      channelCount: 0,
      contactCount: 0,
      queuedDirect: 0,
      queuedChannel: 0,
      unavailableReason: unavailableReason,
    );

class _FakeIdentitiesAppState extends AppState {
  List<IdentitySummary> summaries = [];
  bool loaded = true;
  String? dbError;
  Object? suggestError;
  String suggestion = 'MeshChameleon 2';
  IdentityRecord? createResult;
  bool activateResult = true;
  bool toggleResult = true;
  bool deleteResult = true;
  bool clearResult = true;
  int loadCalls = 0;
  final activateCalls = <String>[];
  final toggleCalls = <(String, bool)>[];
  final deleteCalls = <String>[];
  final clearCalls = <String>[];
  final createdNames = <String?>[];

  @override
  List<IdentitySummary> get identities => summaries;

  @override
  bool get identitiesLoaded => loaded;

  @override
  String? get identityDatabaseError => dbError;

  @override
  Future<void> loadIdentities({bool resume = true}) async {
    loadCalls++;
  }

  @override
  Future<String> suggestIdentityName() async {
    if (suggestError != null) throw suggestError!;
    return suggestion;
  }

  @override
  Future<IdentityRecord?> createIdentity({String? name}) async {
    createdNames.add(name);
    return createResult;
  }

  @override
  Future<bool> activateIdentity(String id) async {
    activateCalls.add(id);
    return activateResult;
  }

  @override
  Future<bool> setIdentityEnabled(String id, bool enabled) async {
    toggleCalls.add((id, enabled));
    return toggleResult;
  }

  @override
  Future<bool> deleteIdentity(String id) async {
    deleteCalls.add(id);
    return deleteResult;
  }

  @override
  Future<bool> clearLocalData(String id) async {
    clearCalls.add(id);
    return clearResult;
  }
}
