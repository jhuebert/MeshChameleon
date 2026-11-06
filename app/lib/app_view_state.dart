import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import 'services/backup_service.dart';
import 'services/build_info.dart';
import 'services/device_link_phase.dart';
import 'services/diagnostics_snapshot.dart';
import 'services/identity_index.dart';
import 'services/identity_runtime.dart';
import 'services/network_connection_store.dart';
import 'services/proxy_status.dart';
import 'services/session_store.dart';

export 'services/backup_service.dart' show BackupPreview;
export 'services/identity_index.dart' show IdentityRecord;
export 'services/identity_runtime.dart' show IdentitySummary;
export 'services/network_connection_store.dart' show SavedNetworkConnection;
export 'services/device_link_phase.dart';
export 'services/proxy_status.dart';
export 'services/session_store.dart' show DeviceTargetKind, SessionConfig;

/// The read/write surface screens use from the application state.
///
/// [AppState] implements this as the composition root; widget tests provide a
/// fake that implements only this interface instead of extending the real
/// storage graph. Keep this list to what screens actually need: application
/// services and platform adapters stay off it.
abstract class AppViewState extends ChangeNotifier {
  List<String> get logs;

  BuildInfo get buildInfo;

  DiagnosticsSnapshot diagnosticsSnapshot();

  // Identity catalog.
  List<IdentitySummary> get identities;
  IdentitySummary? get activeIdentity;
  bool get identitiesLoaded;
  String? get identityDatabaseError;

  Future<void> loadIdentities({bool resume = true});
  Future<String> suggestIdentityName();
  Future<IdentityRecord?> createIdentity({String? name});
  Future<bool> activateIdentity(String id);
  Future<bool> setIdentityEnabled(String id, bool enabled);
  Future<bool> deleteIdentity(String id);
  Future<bool> clearLocalData(String id);

  // Backup and restore.
  Future<Uint8List> createBackup(String passphrase);
  Future<BackupPreview> inspectBackup(Uint8List bytes, String passphrase);
  Future<bool> restoreBackup(BackupPreview preview);

  // Device session.
  ProxyStatus get proxyStatus;
  bool get busy;
  String? get deviceLabel;
  DeviceLinkPhase get devicePhase;
  bool get deviceConnected;

  /// True while an unexpected drop is being retried. The proxy stays up during
  /// this window, but the UI should show the link as reconnecting.
  bool get deviceReconnecting;

  /// True while a parked session waits for the companion to return.
  bool get deviceWaiting;
  bool get deviceConnecting;
  int get port;
  bool get autoResume;
  SessionConfig? get lastSession;

  Future<bool> connectTcp({required String host, int? tcpPort});
  Future<bool> connectBle(BluetoothDevice device, {String? displayName});
  Future<bool> connectSimulated({RadioLink? simulatedLink});
  Future<void> cancelPendingConnection();
  Future<void> cancelDeviceAttempt();
  Future<void> disconnectDevice();

  /// Nudge a parked recovery when the app returns to the foreground: run an
  /// immediate TCP attempt or re-arm the BLE `autoConnect` request.
  Future<void> rearmAfterLinkLoss();
  Future<bool> setProxyPort(int value);
  Future<void> setAutoResume(bool value);
  Future<void> startProxy({int? serverPort});
  Future<void> stopProxy();

  // Saved network targets.
  List<SavedNetworkConnection> get savedNetworkConnections;
  Future<bool> removeSavedNetworkConnection(SavedNetworkConnection connection);
  Future<bool> restoreSavedNetworkConnection(
    SavedNetworkConnection connection,
  );

  // Battery optimization state.
  bool? get batteryOptimizationsIgnored;
  Future<void> refreshBatteryOptimizationStatus();
  Future<void> openBatteryOptimizationSettings();

  // Phone telemetry.
  int? get phoneBatteryPercent;
  bool get phoneGpsRequested;
  String get phoneLocationPermissionLabel;
  int? get phoneGpsIntervalSeconds;
  Duration? get phoneGpsLastFixAge;
  String? get phoneGpsLastError;
  bool get foregroundIncludesLocation;
  Future<void> refreshPhoneTelemetry();
  Future<bool> requestPhoneLocationPermission();
  Future<bool> openPhoneLocationSettings();
  Future<bool> setPhoneGpsEnabled(bool enabled);
  Future<bool> setPhoneGpsInterval(int seconds);
}
