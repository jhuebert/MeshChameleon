import 'dart:async';
import 'dart:typed_data';

import 'package:meshchameleon/app_state.dart';
import 'package:meshchameleon/services/backup_service.dart';
import 'package:meshchameleon/services/diagnostics_snapshot.dart';
import 'package:meshchameleon/services/identity_index.dart';
import 'package:meshchameleon/services/identity_runtime.dart';

/// The shared widget-test double for [AppState].
///
/// Screens receive this through `ChangeNotifierProvider<AppState>`; tests set
/// the fields or callbacks for the workflow under test instead of subclassing
/// the production composition root.
class FakeAppState extends AppState {
  FakeAppState({this.diagnosticsBuilder});

  // Identity catalog.
  List<IdentitySummary> summaries = [];
  IdentitySummary? activeSummary;
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

  // Connection and notification controls.
  int stopProxyCalls = 0;
  int disconnectCalls = 0;
  int batteryRefreshes = 0;

  // Backup workflow.
  final createPassphrases = <String>[];
  final inspectCalls = <(Uint8List, String)>[];
  Object? createError;
  Object? inspectError;
  BackupPreview? inspectResult;
  bool restoreResult = true;
  int restoreCalls = 0;
  Completer<void>? createGate;

  // Diagnostics.
  final DiagnosticsSnapshot Function()? diagnosticsBuilder;
  int refreshes = 0;

  @override
  List<IdentitySummary> get identities => summaries;

  @override
  IdentitySummary? get activeIdentity => activeSummary;

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

  @override
  Future<void> stopProxy() async {
    stopProxyCalls++;
    proxyStatus = ProxyStatus.stopped;
    notifyListeners();
  }

  @override
  Future<void> disconnectDevice() async {
    disconnectCalls++;
    deviceConnected = false;
    notifyListeners();
  }

  @override
  Future<void> refreshBatteryOptimizationStatus() async {
    batteryRefreshes++;
  }

  @override
  Future<Uint8List> createBackup(String passphrase) async {
    createPassphrases.add(passphrase);
    if (createGate != null) await createGate!.future;
    if (createError != null) throw createError!;
    return Uint8List.fromList([1, 2, 3]);
  }

  @override
  Future<BackupPreview> inspectBackup(
    Uint8List bytes,
    String passphrase,
  ) async {
    inspectCalls.add((bytes, passphrase));
    if (inspectError != null) throw inspectError!;
    return inspectResult!;
  }

  @override
  Future<bool> restoreBackup(BackupPreview preview) async {
    restoreCalls++;
    return restoreResult;
  }

  @override
  DiagnosticsSnapshot diagnosticsSnapshot() {
    refreshes++;
    return diagnosticsBuilder!();
  }
}
