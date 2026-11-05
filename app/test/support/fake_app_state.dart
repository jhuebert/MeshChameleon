import 'dart:async';

import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:meshchameleon/app_view_state.dart';
import 'package:meshchameleon/services/build_info.dart';
import 'package:meshchameleon/services/diagnostics_snapshot.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// The shared widget-test double for [AppViewState].
///
/// Screens receive this through `ChangeNotifierProvider<AppViewState>`; tests
/// set the fields or callbacks for the workflow under test instead of
/// constructing the real composition root and its storage graph.
class FakeAppState extends ChangeNotifier implements AppViewState {
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
  int cancelCalls = 0;
  int rearmCalls = 0;
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
  final List<String> logs = [];

  @override
  final BuildInfo buildInfo = BuildInfo.fallback();

  @override
  ProxyStatus proxyStatus = ProxyStatus.stopped;

  @override
  String? deviceLabel;

  @override
  bool deviceConnected = false;

  @override
  bool deviceReconnecting = false;

  @override
  bool deviceWaiting = false;

  @override
  bool deviceConnecting = false;

  /// Explicit phase for tests that need waiting/connecting without the
  /// convenience booleans.
  DeviceLinkPhase phase = DeviceLinkPhase.idle;

  @override
  DeviceLinkPhase get devicePhase {
    if (phase != DeviceLinkPhase.idle) return phase;
    if (deviceConnecting) return DeviceLinkPhase.connecting;
    if (deviceReconnecting) return DeviceLinkPhase.reconnecting;
    if (deviceWaiting) return DeviceLinkPhase.waiting;
    if (deviceConnected) return DeviceLinkPhase.connected;
    return DeviceLinkPhase.idle;
  }

  @override
  bool busy = false;

  @override
  int port = defaultCompanionPort;

  @override
  bool autoResume = false;

  @override
  SessionConfig? lastSession;

  @override
  bool? batteryOptimizationsIgnored;

  @override
  final List<SavedNetworkConnection> savedNetworkConnections = [];

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
  Future<bool> connectTcp({required String host, int? tcpPort}) async => false;

  @override
  Future<bool> connectBle(
    BluetoothDevice device, {
    String? displayName,
  }) async =>
      false;

  @override
  Future<bool> connectSimulated({RadioLink? simulatedLink}) async => false;

  @override
  Future<void> cancelPendingConnection() => cancelDeviceAttempt();

  @override
  Future<void> cancelDeviceAttempt() async {
    cancelCalls++;
    deviceConnected = false;
    deviceReconnecting = false;
    deviceWaiting = false;
    deviceConnecting = false;
    phase = DeviceLinkPhase.idle;
    notifyListeners();
  }

  @override
  Future<void> stopProxy() async {
    stopProxyCalls++;
    proxyStatus = ProxyStatus.stopped;
    notifyListeners();
  }

  @override
  Future<void> startProxy({int? serverPort}) async {
    proxyStatus = ProxyStatus.running;
    notifyListeners();
  }

  @override
  Future<void> disconnectDevice() async {
    disconnectCalls++;
    deviceConnected = false;
    deviceReconnecting = false;
    deviceWaiting = false;
    deviceConnecting = false;
    phase = DeviceLinkPhase.idle;
    notifyListeners();
  }

  @override
  Future<void> rearmAfterLinkLoss() async {
    rearmCalls++;
  }

  @override
  Future<bool> setProxyPort(int value) async {
    port = value;
    notifyListeners();
    return true;
  }

  @override
  Future<void> setAutoResume(bool value) async {
    autoResume = value;
    notifyListeners();
  }

  @override
  Future<bool> removeSavedNetworkConnection(
    SavedNetworkConnection connection,
  ) async {
    savedNetworkConnections.remove(connection);
    notifyListeners();
    return true;
  }

  @override
  Future<bool> restoreSavedNetworkConnection(
    SavedNetworkConnection connection,
  ) async {
    savedNetworkConnections.add(connection);
    notifyListeners();
    return true;
  }

  @override
  Future<void> refreshBatteryOptimizationStatus() async {
    batteryRefreshes++;
  }

  @override
  Future<void> openBatteryOptimizationSettings() async {}

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
