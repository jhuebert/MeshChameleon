import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/screens/backup_screen.dart';
import 'package:meshchameleon/services/backup_codec.dart';
import 'package:meshchameleon/services/backup_service.dart';
import 'package:meshchameleon/services/identity_index.dart';
import 'package:meshchameleon/services/identity_repository.dart';
import 'package:meshchameleon/services/identity_store.dart';
import 'package:meshchameleon/services/network_connection_store.dart';
import 'package:meshchameleon/services/session_store.dart';
import 'package:provider/provider.dart';

import 'support/fake_app_state.dart';

const _channel = MethodChannel('flutter_file_dialog');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late BackupService service;
  late BackupPreview preview;
  late FakeAppState app;
  String? savePath;
  String? pickPath;
  Object? pickError;
  final dialogCalls = <MethodCall>[];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('backup_ui_');
    final repository = IdentityRepository(
      supportDirectory: temp,
      secureStore: IdentityStore(),
    );
    service = BackupService(
      repository: repository,
      identityStore: IdentityStore(),
      sessionStore: SessionStore(file: File('${temp.path}/session.json')),
      networkConnectionStore: NetworkConnectionStore(
        file: File('${temp.path}/network_connections.json'),
      ),
    );
    preview = await _makePreview(service);
    app = FakeAppState()..inspectResult = preview;
    savePath = '/tmp/backup.mcbackup';
    pickPath = null;
    pickError = null;
    dialogCalls.clear();

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
      dialogCalls.add(call);
      switch (call.method) {
        case 'saveFile':
          return savePath;
        case 'pickFile':
          if (pickError != null) throw pickError!;
          return pickPath;
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await temp.delete(recursive: true);
    app.dispose();
  });

  Widget wrap() => ChangeNotifierProvider<AppState>.value(
        value: app,
        child: const MaterialApp(home: BackupScreen()),
      );

  testWidgets('creates a named backup and confirms the save', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(app.createPassphrases, ['correct horse']);
    expect(dialogCalls.map((call) => call.method), contains('saveFile'));
    final params = dialogCalls
        .firstWhere((call) => call.method == 'saveFile')
        .arguments as Map;
    expect(params['fileName'],
        matches(r'^meshchameleon-\d{4}-\d{2}-\d{2}\.mcbackup$'));
    expect(find.text('Backup saved'), findsOneWidget);
  });

  testWidgets('a cancelled save leaves the screen idle', (tester) async {
    savePath = null;
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Backup saved'), findsNothing);
  });

  testWidgets('passphrase validation reports each problem', (tester) async {
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the passphrase'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'short');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Use at least 8 characters'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'long enough');
    await tester.enterText(find.byType(TextField).at(1), 'different');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('The passphrases do not match'), findsOneWidget);

    await tester.tap(find.byTooltip('Show passphrase'));
    await tester.pump();
    expect(find.byTooltip('Hide passphrase'), findsOneWidget);
    expect(app.createPassphrases, isEmpty);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.createPassphrases, isEmpty);
  });

  testWidgets('backup errors are surfaced with specific and generic text',
      (tester) async {
    app.createError = const BackupException('passphrase rejected');
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('passphrase rejected'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    app.createError = StateError('unexpected');
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse');
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.text('Could not create the backup.'), findsOneWidget);
  });

  testWidgets('the working state disables both actions', (tester) async {
    final gate = Completer<void>();
    app.createGate = gate;
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('Back up now'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'correct horse');
    await tester.enterText(find.byType(TextField).at(1), 'correct horse');
    await tester.tap(find.text('Continue'));
    await tester.pump();

    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Back up now'))
          .onPressed,
      isNull,
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('restores a picked backup after showing the summary',
      (tester) async {
    final file = File('${temp.path}/backup.mcbackup');
    await tester.runAsync(() => file.writeAsBytes([1, 2, 3]));
    pickPath = file.path;
    await tester.pumpWidget(wrap());

    await _openRestore(tester);
    expect(find.text('Enter backup passphrase'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'correct horse');
    await _submitPassphrase(tester);

    expect(app.inspectCalls.single.$2, 'correct horse');
    expect(find.text('Restore this backup?'), findsOneWidget);
    expect(find.text('1 identity'), findsOneWidget);
    expect(find.text('0 contacts'), findsOneWidget);
    expect(find.text('0 channels'), findsOneWidget);
    expect(find.text('0 messages'), findsOneWidget);
    expect(
      find.textContaining('A recovery copy of the current identity files'),
      findsOneWidget,
    );

    await tester.tap(find.text('Replace local data'));
    await _finishRestore(tester);
    expect(app.restoreCalls, 1);
    expect(find.text('Backup restored'), findsOneWidget);
  });

  testWidgets('a rejected restore keeps local data and reports failure',
      (tester) async {
    final file = File('${temp.path}/backup.mcbackup');
    await tester.runAsync(() => file.writeAsBytes([1]));
    pickPath = file.path;
    app.restoreResult = false;
    await tester.pumpWidget(wrap());

    await _openRestore(tester);
    await tester.enterText(find.byType(TextField), 'correct horse');
    await _submitPassphrase(tester);
    await tester.tap(find.text('Replace local data'));
    await _finishRestore(tester);

    expect(
        find.text('Could not restore the backup. Your previous data was kept.'),
        findsOneWidget);
  });

  testWidgets('cancelling the summary does not restore', (tester) async {
    final file = File('${temp.path}/backup.mcbackup');
    await tester.runAsync(() => file.writeAsBytes([1]));
    pickPath = file.path;
    await tester.pumpWidget(wrap());

    await _openRestore(tester);
    await tester.enterText(find.byType(TextField), 'correct horse');
    await _submitPassphrase(tester);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await _finishRestore(tester);

    expect(app.restoreCalls, 0);
  });

  testWidgets('restore picker and file failures are reported', (tester) async {
    await tester.pumpWidget(wrap());

    pickError = StateError('picker broke');
    await _openRestore(tester);
    expect(find.text('Could not open the file picker.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    pickError = null;
    pickPath = '${temp.path}/missing.mcbackup';
    await _openRestore(tester);
    expect(find.text('Could not read that file.'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    final large = File('${temp.path}/large.mcbackup');
    await tester.runAsync(() async {
      final handle = await large.open(mode: FileMode.write);
      await handle.truncate(maxBackupBytes + 1);
      await handle.close();
    });
    pickPath = large.path;
    await _openRestore(tester);
    expect(find.text('That backup file is too large.'), findsOneWidget);
  });

  testWidgets('cancelling the restore passphrase does nothing', (tester) async {
    final file = File('${temp.path}/backup.mcbackup');
    await tester.runAsync(() => file.writeAsBytes([1]));
    pickPath = file.path;
    await tester.pumpWidget(wrap());

    await _openRestore(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(app.inspectCalls, isEmpty);
    expect(app.restoreCalls, 0);
  });

  testWidgets('inspect errors show specific and generic messages',
      (tester) async {
    final file = File('${temp.path}/backup.mcbackup');
    await tester.runAsync(() => file.writeAsBytes([1]));
    pickPath = file.path;
    app.inspectError = const BackupException('that file is damaged');
    await tester.pumpWidget(wrap());

    await _openRestore(tester);
    await tester.enterText(find.byType(TextField), 'correct horse');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('that file is damaged'), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    app.inspectError = StateError('unexpected');
    await _openRestore(tester);
    await tester.enterText(find.byType(TextField), 'correct horse');
    await _submitPassphrase(tester);
    expect(find.text('Could not restore the backup.'), findsOneWidget);
  });
}

Future<void> _finishRestore(WidgetTester tester) async {
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _submitPassphrase(WidgetTester tester) async {
  await tester.tap(find.text('Open backup'));
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

Future<void> _openRestore(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Restore from backup'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
}

Future<BackupPreview> _makePreview(BackupService service) async {
  final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
  const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final index = IdentityIndex(
    activeId: id,
    identities: [
      IdentityRecord(
        id: id,
        publicKey: identity.publicKey,
        name: 'Test',
        createdAt: 1,
      ),
    ],
  );
  final state = NodeState(prefs: NodePrefs(nodeName: 'Test'));
  final bytes = await BackupCodec.seal(
    payload: {
      'index': index.toJson(),
      'identities': {
        id: {
          'key': bytesToHex(identity.meshcore64),
          'state': state.toJson(),
        },
      },
      'network_connections': null,
      'session': null,
    },
    passphrase: 'correct horse',
    appVersion: '0.2.0',
  );
  return service.inspect(bytes: bytes, passphrase: 'correct horse');
}
