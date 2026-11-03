import 'dart:async';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path_provider/path_provider.dart';

import 'app_view_state.dart';
import 'services/backup_controller.dart';
import 'services/build_info.dart';
import 'services/connection_controller.dart';
import 'services/device_capabilities.dart';
import 'services/diagnostics_snapshot.dart';
import 'services/foreground_service.dart';
import 'services/identity_controller.dart';
import 'services/identity_manager.dart';
import 'services/identity_repository.dart';
import 'services/identity_runtime.dart';
import 'services/identity_store.dart';
import 'services/network_connection_history.dart';
import 'services/network_connection_store.dart';
import 'services/notification_content.dart';
import 'services/session_settings.dart';
import 'services/session_store.dart';

export 'app_view_state.dart';
export 'services/connection_controller.dart' show TcpDeviceLinkFactory;
export 'services/notification_content.dart';
export 'services/proxy_status.dart';

/// Owns the device session, identity manager, proxy server, and backup state,
/// and exposes them to the UI.
class AppState extends ChangeNotifier implements AppViewState, ConnectionHost {
  AppState({
    IdentityRepository? repository,
    IdentityStore? identityStore,
    SessionStore? sessionStore,
    NetworkConnectionStore? networkConnectionStore,
    TcpDeviceLinkFactory? tcpLinkFactory,
    DeviceCapabilities? capabilities,
    BuildInfo? buildInfo,
    CompanionMetrics? companionMetrics,
    LinkMetrics? linkMetrics,
    ForegroundService? foregroundService,
    DateTime? startedAt,
    this.reconnectDelay = const Duration(seconds: 3),
  })  : _repository = repository,
        identityStore = identityStore ?? IdentityStore(),
        sessionStore = sessionStore ?? SessionStore(),
        networkConnectionStore =
            networkConnectionStore ?? NetworkConnectionStore(),
        _tcpLinkFactory = tcpLinkFactory ?? _defaultTcpLinkFactory,
        _foreground = foregroundService ?? ForegroundService(),
        capabilities = capabilities ?? DeviceCapabilities.current(),
        buildInfo = buildInfo ?? BuildInfo.fallback(),
        companionMetrics = companionMetrics ?? CompanionMetrics(),
        linkMetrics = linkMetrics ?? LinkMetrics(),
        startedAt = startedAt ?? DateTime.now();

  final IdentityStore identityStore;
  final SessionStore sessionStore;
  final NetworkConnectionStore networkConnectionStore;
  final TcpDeviceLinkFactory _tcpLinkFactory;

  /// Installed build identity shown in the footer and diagnostics.
  @override
  final BuildInfo buildInfo;

  /// Wall-clock start used for the session uptime shown in diagnostics.
  final DateTime startedAt;

  /// Client-side proxy counters, retained across proxy stop/start.
  final CompanionMetrics companionMetrics;

  /// Physical device-link counters, retained across reconnects.
  final LinkMetrics linkMetrics;

  Duration get appUptime => DateTime.now().difference(startedAt);

  /// Build the presentation-safe diagnostics view. Cheap and synchronous:
  /// packet counters are already cached inside each live [MeshNode].
  @override
  DiagnosticsSnapshot diagnosticsSnapshot() {
    final nodes = <String, MeshNode?>{
      for (final runtime in _manager?.runtimes ?? const <IdentityRuntime>[])
        runtime.record.id: runtime.node,
    };
    return DiagnosticsSnapshot(
      buildInfo: buildInfo,
      generatedAt: DateTime.now().toUtc(),
      appUptime: appUptime,
      proxyRunning: proxyStatus == ProxyStatus.running,
      proxyPort: port,
      deviceConnected: deviceConnected,
      deviceLabel: deviceLabel,
      deviceInfo: deviceInfo,
      deviceSessionDuration: deviceSessionDuration,
      reconnectAttempts: reconnectAttempts,
      reconnectSuccesses: reconnectSuccesses,
      foregroundServiceRunning: foregroundServiceRunning,
      batteryOptimizationsIgnored: batteryOptimizationsIgnored,
      autoResume: autoResume,
      identityDatabaseError: identityDatabaseError,
      companion: companionMetrics,
      link: linkMetrics,
      identities: [
        for (final summary in identities)
          IdentityDiagnostics(
            id: summary.id,
            name: summary.name,
            prefixHex: summary.prefixHex,
            active: summary.active,
            live: summary.live,
            enabled: summary.enabled,
            contactCount: summary.contactCount,
            channelCount: summary.channelCount,
            queuedDirect: summary.queuedDirect,
            queuedChannel: summary.queuedChannel,
            unavailableReason: summary.unavailableReason,
            packets: nodes[summary.id] == null
                ? null
                : MeshPacketStats.fromMap(nodes[summary.id]!.sessionStats),
          ),
      ],
      recentLogs: logs.length <= 100
          ? List<String>.of(logs)
          : logs.sublist(logs.length - 100),
    );
  }

  static RadioLink _defaultTcpLinkFactory(
    String host,
    int port,
    void Function(String message) onLog,
  ) =>
      TcpDeviceLink(host: host, port: port, onLog: onLog);

  /// What this build can do; gates session restore.
  final DeviceCapabilities capabilities;

  /// Delay before an unexpected link drop is retried.
  final Duration reconnectDelay;

  /// Foreground service that keeps the process alive while backgrounded.
  final ForegroundService _foreground;

  IdentityRepository? _repository;
  IdentityManager? _manager;

  @override
  IdentityManager? get manager => _manager;

  Future<IdentityRepository> _ensureRepository() async {
    final existing = _repository;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    final created = IdentityRepository(
      supportDirectory: dir,
      secureStore: identityStore,
      onLog: log,
    );
    _repository = created;
    return created;
  }

  CompanionServer? server;

  @override
  int get port => _sessionSettings.port;
  set port(int value) => _sessionSettings.port = value;
  @override
  ProxyStatus proxyStatus = ProxyStatus.stopped;
  @override
  bool busy = false;

  /// True after a physical shutdown until the user explicitly connects again.
  bool get intentionallyOff => _sessionSettings.intentionallyOff;

  RadioLink? get link => _connection.link;
  @override
  String? get deviceLabel => _connection.deviceLabel;
  @override
  bool get deviceConnected => _connection.deviceConnected;
  DeviceInfo? get deviceInfo => _connection.deviceInfo;
  DateTime? get deviceConnectedAt => _connection.deviceConnectedAt;
  int get reconnectAttempts => _connection.reconnectAttempts;
  int get reconnectSuccesses => _connection.reconnectSuccesses;
  Duration? get deviceSessionDuration => _connection.deviceSessionDuration;

  late final SessionSettings _sessionSettings = SessionSettings(
    store: sessionStore,
    onLog: log,
  );

  late final BackupController _backup = BackupController(
    repository: _ensureRepository,
    identityStore: identityStore,
    sessionStore: sessionStore,
    networkConnectionStore: networkConnectionStore,
    appVersion: () => buildInfo.version,
    log: log,
  );

  late final IdentityController _identityController = IdentityController(
    ensureManager: _ensureManager,
    currentManager: () => _manager,
    isBusy: () => busy,
    setBusy: (value) => busy = value,
    notify: notifyListeners,
    log: log,
    updateNotification: _updateNotification,
    proxyServer: () => server,
  );

  /// Last device session (device link + proxy port), restored on launch when
  /// [autoResume] is on.
  @override
  SessionConfig? get lastSession => _sessionSettings.lastSession;
  @override
  bool get autoResume => _sessionSettings.autoResume;

  /// Successful network targets, newest first.
  late final NetworkConnectionHistory _networkHistory =
      NetworkConnectionHistory(
    store: networkConnectionStore,
    onLog: log,
    onChanged: notifyListeners,
  );

  @override
  List<SavedNetworkConnection> get savedNetworkConnections =>
      _networkHistory.connections;

  late final ConnectionController _connection = ConnectionController(
    host: this,
    tcpLinkFactory: _tcpLinkFactory,
    capabilities: capabilities,
    metrics: linkMetrics,
    sessionSettings: _sessionSettings,
    networkHistory: _networkHistory,
    reconnectDelay: reconnectDelay,
  );

  /// Whether the OS exempts the app from battery optimizations (null until
  /// queried; always null on non-Android platforms).
  @override
  bool? batteryOptimizationsIgnored;

  /// Diagnostic age/staleness for the radio's last good voltage sample.
  int? get batterySampleAgeSeconds => node?.batterySampleAgeSeconds;
  bool get batteryStale => node?.batteryStale ?? true;
  String? get batteryDiagnostic => node?.batteryDiagnostic;

  @override
  final List<String> logs = [];
  bool _disposed = false;

  // -------------------------------------------------------------------------
  // Identity-facing state
  // -------------------------------------------------------------------------

  @override
  List<IdentitySummary> get identities => _manager?.summaries ?? const [];
  @override
  IdentitySummary? get activeIdentity => _manager?.activeSummary;
  @override
  String? get identityDatabaseError => _manager?.databaseError;
  @override
  bool get identitiesLoaded => _manager?.loaded ?? false;

  /// The active virtual identity exposed to the companion client.
  LocalIdentity? get identity => _manager?.activeIdentity;

  /// The active identity's live node (null without a device or when unavailable).
  MeshNode? get node => _manager?.activeNode;

  String? get activeIdentityId => _manager?.activeId;

  bool _foregroundStarted = false;
  String? _lastNotification;
  bool _logNotificationScheduled = false;

  /// Whether the Android foreground service is currently holding the process
  /// alive (always false on desktop).
  bool get foregroundServiceRunning => _foregroundStarted;

  /// Append a timestamped line and coalesce synchronous bursts into one
  /// listener update.
  ///
  /// A chatty connection can emit several lines in one turn; notifying per
  /// line rebuilds every screen unnecessarily. The microtask still runs before
  /// the next frame, so the log page sees the entries on the same pump.
  @override
  void log(String message) {
    if (_disposed) return;
    logs.add('${DateTime.now().toIso8601String()}  $message');
    if (logs.length > 500) logs.removeAt(0);
    if (_logNotificationScheduled) return;
    // Notify once for the first line in a burst, then ignore the rest until
    // the next turn. This preserves log-as-a-state-trigger for callers while
    // avoiding a rebuild per line during chatty operations.
    _logNotificationScheduled = true;
    notifyListeners();
    scheduleMicrotask(() {
      _logNotificationScheduled = false;
    });
  }

  void _onManagerChanged() {
    if (_disposed) return;
    notifyListeners();
    final content = _notificationContent();
    if (_foregroundStarted && content.key != _lastNotification) {
      unawaited(_updateNotification());
    }
  }

  Future<IdentityManager> _ensureManager() async {
    final existing = _manager;
    if (existing != null) return existing;
    final created = IdentityManager(
      repository: await _ensureRepository(),
      onChanged: _onManagerChanged,
      onLog: log,
      onPoweredOff: _connection.handlePoweredOff,
    );
    _manager = created;
    return created;
  }

  /// Load the identity catalog and the last session.
  ///
  /// A fresh install auto-creates and activates one identity. A corrupt
  /// catalog is surfaced through [identityDatabaseError] rather than replaced.
  @override
  Future<void> loadIdentities({bool resume = true}) async {
    try {
      await _backup.recoverInterruptedRestore();
    } catch (e) {
      log('Could not recover an interrupted backup restore: $e');
    }
    final manager = await _ensureManager();
    await manager.load();
    await _sessionSettings.load();
    // Load the history before auto-resume so a resumed TCP session refreshes
    // its target instead of replacing the saved list.
    await _networkHistory.load();
    notifyListeners();
    if (resume) await _maybeResumeSession();
  }

  @override
  Future<String> suggestIdentityName() => _identityController.suggestName();

  /// Create an additional identity. It is inactive; the active selection does
  /// not change.
  @override
  Future<IdentityRecord?> createIdentity({String? name}) =>
      _identityController.create(name: name);

  /// Make [id] the identity served to the MeshCore app.
  @override
  Future<bool> activateIdentity(String id) => _identityController.activate(id);

  /// Enable or disable an identity. The active identity cannot be disabled.
  @override
  Future<bool> setIdentityEnabled(String id, bool enabled) =>
      _identityController.setEnabled(id, enabled);

  /// Delete an inactive identity. The manager and repository enforce the
  /// active/last-identity rules.
  @override
  Future<bool> deleteIdentity(String id) => _identityController.delete(id);

  /// Clear contacts, channels, messages, advert paths, and non-name prefs for
  /// one identity while keeping its key and current name.
  @override
  Future<bool> clearLocalData(String id) =>
      _identityController.clearLocalData(id);

  // -------------------------------------------------------------------------
  // Backup and restore
  // -------------------------------------------------------------------------

  /// Capture all local data into a passphrase-encrypted backup file.
  @override
  Future<Uint8List> createBackup(String passphrase) =>
      _backup.create(passphrase);

  /// Decrypt and validate a backup without changing local data.
  @override
  Future<BackupPreview> inspectBackup(
    Uint8List bytes,
    String passphrase,
  ) =>
      _backup.inspect(bytes, passphrase);

  /// Replace all local data with a validated backup.
  @override
  Future<bool> restoreBackup(BackupPreview preview) async {
    if (busy) return false;
    busy = true;
    notifyListeners();
    try {
      if (deviceConnected || proxyStatus == ProxyStatus.running) {
        await disconnectDevice();
      }
      await _manager?.dispose();
      _manager = null;
      await _backup.restore(preview);
      await loadIdentities(resume: false);
      log('Restored backup');
      return true;
    } catch (e) {
      log('Could not restore backup: $e');
      try {
        await loadIdentities(resume: false);
      } catch (_) {
        // Keep the error; the UI can still show the data problem.
      }
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  // -------------------------------------------------------------------------
  // Device link
  // -------------------------------------------------------------------------

  /// Connect to a network companion.
  ///
  /// Returns true only when the link attached and the session was recorded.
  /// Failed history writes are logged without failing the connection.
  @override
  Future<bool> connectTcp({required String host, int? tcpPort}) =>
      _connection.connectTcp(host: host, tcpPort: tcpPort);

  @override
  Future<bool> connectBle(BluetoothDevice device, {String? displayName}) =>
      _connection.connectBle(device, displayName: displayName);

  /// Attach the in-memory simulated companion.
  @override
  Future<bool> connectSimulated({RadioLink? simulatedLink}) =>
      _connection.connectSimulated(simulatedLink: simulatedLink);

  @override
  Future<void> cancelPendingConnection() =>
      _connection.cancelPendingConnection();

  @override
  Future<void> disconnectDevice() => _connection.disconnect();

  @override
  Future<void> recordNetworkConnection(String host, int port) =>
      _networkHistory.record(host, port);

  /// Remove a saved target. The in-memory list changes only after the file
  /// write succeeds, so a failed delete leaves the card visible.
  @override
  Future<bool> removeSavedNetworkConnection(
    SavedNetworkConnection connection,
  ) =>
      _networkHistory.remove(connection);

  /// Restore a removed target with its original timestamp.
  ///
  /// A newer entry for the same key wins if the user reconnected before Undo.
  @override
  Future<bool> restoreSavedNetworkConnection(
    SavedNetworkConnection connection,
  ) =>
      _networkHistory.restore(connection);

  @override
  Future<bool> setProxyPort(int value) async {
    if (!isValidTcpPort(value) || proxyStatus == ProxyStatus.running) {
      return false;
    }
    final changed = await _sessionSettings.setPort(value);
    notifyListeners();
    return changed;
  }

  /// Persist the last session so it can be restored on the next launch.
  ///
  /// A failed write must not turn an already-attached radio into a failed
  /// connection; auto-resume is simply unavailable until the next successful
  /// save.
  @override
  Future<void> recordSession(SessionConfig session) async {
    await _sessionSettings.record(session);
    notifyListeners();
  }

  /// Toggle automatic session restore (reconnect the last device and restart the
  /// proxy when the app opens).
  @override
  Future<void> setAutoResume(bool value) async {
    await _sessionSettings.setAutoResume(value);
    notifyListeners();
  }

  /// Reconnect the saved device and restart the proxy after a launch, if the
  /// user enabled [autoResume]. Best-effort: failures are logged, not fatal.
  Future<void> _maybeResumeSession() async {
    final session = lastSession;
    if (session == null ||
        !autoResume ||
        identities.isEmpty ||
        identityDatabaseError != null ||
        deviceConnected) {
      return;
    }
    if (session.intentionallyOff) {
      log('Last session ended with an intentional shutdown; not auto-resuming');
      return;
    }
    log('Resuming last device session ...');
    try {
      switch (session.kind) {
        case DeviceTargetKind.tcp:
          final host = session.host;
          if (host == null) return;
          await connectTcp(host: host, tcpPort: session.devicePort);
        case DeviceTargetKind.ble:
          if (!capabilities.supportsBle) {
            log('Saved session used BLE, which this build does not support');
            return;
          }
          final remoteId = session.bleRemoteId;
          if (remoteId == null) return;
          await connectBle(
            BluetoothDevice.fromId(remoteId),
            displayName: session.bleName,
          );
        case DeviceTargetKind.simulated:
          await connectSimulated();
      }
      if (deviceConnected) {
        await startProxy(serverPort: session.proxyPort);
      }
    } catch (e) {
      log('Session resume failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Background reliability
  // -------------------------------------------------------------------------

  /// Refresh whether the OS currently exempts the app from battery
  /// optimizations. No-op off Android.
  @override
  Future<void> refreshBatteryOptimizationStatus() async {
    if (!_foreground.isSupported) return;
    try {
      batteryOptimizationsIgnored =
          await _foreground.isIgnoringBatteryOptimizations();
      notifyListeners();
    } catch (e) {
      log('Battery optimization check failed: $e');
    }
  }

  /// Open the system battery-optimization settings so the user can set
  /// MeshChameleon to unrestricted. The status is re-checked when the app
  /// returns to the foreground.
  @override
  Future<void> openBatteryOptimizationSettings() async {
    if (!_foreground.isSupported) return;
    try {
      await _foreground.openBatteryOptimizationSettings();
    } catch (e) {
      log('Battery optimization settings failed to open: $e');
    }
  }

  /// Persistent-notification copy reflecting the live identity count and state.
  NotificationContent _notificationContent() => buildNotificationContent(
        identityCount: identities.length,
        activeName: activeIdentity?.name,
        deviceConnected: deviceConnected,
        proxyStatus: proxyStatus,
        port: port,
      );

  Future<void> _startForegroundService() async {
    if (!_foreground.isSupported) return;
    try {
      final content = _notificationContent();
      await _foreground.start(title: content.title, text: content.text);
      _foregroundStarted = true;
      _lastNotification = content.key;
    } catch (e) {
      log('Foreground service unavailable: $e');
    }
  }

  Future<void> _updateNotification() async {
    try {
      final content = _notificationContent();
      await _foreground.update(title: content.title, text: content.text);
      _lastNotification = content.key;
    } catch (e) {
      log('Foreground service update failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Proxy server
  // -------------------------------------------------------------------------

  /// Serializes queued start/stop operations so a rapid toggle cannot leave a
  /// listener running with the UI reporting stopped (or the reverse).
  Future<void>? _proxyTail;

  Future<void> _runProxyTransition(Future<void> Function() action) {
    final previous = _proxyTail;
    final run = previous == null
        ? action()
        : previous.then(
            (_) => action(),
            onError: (Object _) => action(),
          );
    _proxyTail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  @override
  Future<void> startProxy({int? serverPort}) =>
      _runProxyTransition(() => _startProxy(serverPort));

  Future<void> _startProxy(int? serverPort) async {
    final active = node;
    if (active == null) {
      log(identities.isEmpty
          ? 'No identity available'
          : deviceConnected
              ? 'The active identity is unavailable'
              : 'Connect a device first');
      return;
    }
    final current = server ??= CompanionServer(
      bridge: active,
      config: CompanionServerConfig(port: serverPort ?? port),
      metrics: companionMetrics,
      onLog: log,
    );
    try {
      await current.start();
      port = current.port ?? port;
      proxyStatus = ProxyStatus.running;
      log('Proxy server listening on port $port');
      await _updateNotification();
    } catch (e) {
      log('Failed to start proxy: $e');
      try {
        await current.stop();
      } catch (_) {}
      if (identical(server, current)) server = null;
    }
    notifyListeners();
  }

  @override
  Future<void> stopProxy() => _runProxyTransition(_stopProxy);

  Future<void> _stopProxy() async {
    final current = server;
    server = null;
    try {
      await current?.stop();
    } catch (e) {
      log('Could not stop the proxy cleanly: $e');
    }
    proxyStatus = ProxyStatus.stopped;
    await _updateNotification();
    notifyListeners();
  }

  @override
  Future<IdentityManager> ensureManager() => _ensureManager();

  @override
  void notify() => notifyListeners();

  @override
  bool get proxyRunning => proxyStatus == ProxyStatus.running;

  @override
  Future<void> startForegroundService() => _startForegroundService();

  @override
  Future<void> stopForegroundService() async {
    try {
      await _foreground.stop();
    } catch (_) {
      // The service may already be stopped.
    }
    _foregroundStarted = false;
  }

  @override
  Future<void> updateNotification() => _updateNotification();

  @override
  void resetNotificationState() {
    _foregroundStarted = false;
    _lastNotification = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _connection.dispose();
    unawaited(server?.stop());
    unawaited(_manager?.dispose());
    super.dispose();
  }
}
