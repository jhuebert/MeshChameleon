import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:path_provider/path_provider.dart';

import 'services/ble_device_link.dart';
import 'services/device_capabilities.dart';
import 'services/foreground_service.dart';
import 'services/identity_index.dart';
import 'services/identity_manager.dart';
import 'services/identity_repository.dart';
import 'services/identity_runtime.dart';
import 'services/identity_store.dart';
import 'services/network_connection_store.dart';
import 'services/session_store.dart';

enum ProxyStatus { stopped, running }

/// Creates the TCP link used to reach a network companion.
///
/// Tests supply a [FakeDeviceLink]; production uses [TcpDeviceLink].
typedef TcpDeviceLinkFactory = RadioLink Function(
  String host,
  int port,
  void Function(String message) onLog,
);

/// Owns the device session, identity manager, proxy server, and navigation
/// state, and exposes them to the UI.
class AppState extends ChangeNotifier {
  AppState({
    IdentityRepository? repository,
    IdentityStore? identityStore,
    SessionStore? sessionStore,
    NetworkConnectionStore? networkConnectionStore,
    TcpDeviceLinkFactory? tcpLinkFactory,
    DeviceCapabilities? capabilities,
    this.reconnectDelay = const Duration(seconds: 3),
  })  : _repository = repository,
        identityStore = identityStore ?? IdentityStore(),
        sessionStore = sessionStore ?? SessionStore(),
        networkConnectionStore =
            networkConnectionStore ?? NetworkConnectionStore(),
        _tcpLinkFactory = tcpLinkFactory ?? _defaultTcpLinkFactory,
        capabilities = capabilities ?? DeviceCapabilities.current();

  final IdentityStore identityStore;
  final SessionStore sessionStore;
  final NetworkConnectionStore networkConnectionStore;
  final TcpDeviceLinkFactory _tcpLinkFactory;

  static RadioLink _defaultTcpLinkFactory(
    String host,
    int port,
    void Function(String message) onLog,
  ) =>
      TcpDeviceLink(host: host, port: port, onLog: onLog);

  /// What this build can do; gates the BLE UI and session restore.
  final DeviceCapabilities capabilities;

  /// Delay before an unexpected link drop is retried.
  final Duration reconnectDelay;

  /// Foreground service that keeps the process alive while backgrounded.
  final ForegroundService _foreground = ForegroundService();

  IdentityRepository? _repository;
  IdentityManager? _manager;

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

  RadioLink? link;
  CompanionServer? server;

  int port = defaultCompanionPort;
  ProxyStatus proxyStatus = ProxyStatus.stopped;
  String? deviceLabel;
  bool deviceConnected = false;
  bool busy = false;
  bool _intentionalOff = false;

  /// True after a physical shutdown until the user explicitly connects again.
  bool get intentionallyOff => _intentionalOff;
  RadioLink? _connectingLink;
  bool _connectCancelled = false;

  /// Last device session (device link + proxy port), restored on launch when
  /// [autoResume] is on.
  SessionConfig? lastSession;
  bool autoResume = false;

  List<SavedNetworkConnection> _savedNetworkConnections = const [];
  Future<void> _networkConnectionMutations = Future<void>.value();

  /// Successful network targets, newest first.
  List<SavedNetworkConnection> get savedNetworkConnections =>
      UnmodifiableListView(_savedNetworkConnections);

  /// Whether the OS exempts the app from battery optimizations (null until
  /// queried; always null on non-Android platforms).
  bool? batteryOptimizationsIgnored;

  /// Diagnostic age/staleness for the radio's last good voltage sample.
  int? get batterySampleAgeSeconds => node?.batterySampleAgeSeconds;
  bool get batteryStale => node?.batteryStale ?? true;
  String? get batteryDiagnostic => node?.batteryDiagnostic;

  final List<String> logs = [];
  bool _disposed = false;

  // -------------------------------------------------------------------------
  // Identity-facing state
  // -------------------------------------------------------------------------

  List<IdentitySummary> get identities => _manager?.summaries ?? const [];
  IdentitySummary? get activeIdentity => _manager?.activeSummary;
  String? get identityDatabaseError => _manager?.databaseError;
  bool get identitiesLoaded => _manager?.loaded ?? false;

  /// The active virtual identity exposed to the companion client.
  LocalIdentity? get identity => _manager?.activeIdentity;

  /// The active identity's live node (null without a device or when unavailable).
  MeshNode? get node => _manager?.activeNode;

  String? get activeIdentityId => _manager?.activeId;

  void log(String message) {
    if (_disposed) return;
    logs.add('${DateTime.now().toIso8601String()}  $message');
    if (logs.length > 500) logs.removeAt(0);
    notifyListeners();
  }

  bool _foregroundStarted = false;
  String? _lastNotificationText;

  void _onManagerChanged() {
    if (_disposed) return;
    notifyListeners();
    final text = _notificationText();
    if (_foregroundStarted && text != _lastNotificationText) {
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
      onPoweredOff: _onNodePoweredOff,
    );
    _manager = created;
    return created;
  }

  /// Load the identity catalog and the last session.
  ///
  /// A fresh install auto-creates and activates one identity. A corrupt
  /// catalog is surfaced through [identityDatabaseError] rather than replaced.
  Future<void> loadIdentities() async {
    final manager = await _ensureManager();
    await manager.load();
    final session = await sessionStore.load();
    final savedConnections = await networkConnectionStore.load();
    lastSession = session;
    if (session != null) {
      port = session.proxyPort;
      autoResume = session.autoResume;
      _intentionalOff = session.intentionallyOff;
    }
    // Load the history before auto-resume so a resumed TCP session refreshes
    // its target instead of replacing the saved list.
    _savedNetworkConnections = savedConnections;
    notifyListeners();
    await _maybeResumeSession();
  }

  Future<String> suggestIdentityName() async {
    final manager = await _ensureManager();
    return manager.suggestName();
  }

  /// Create an additional identity. It is inactive; the active selection does
  /// not change.
  Future<IdentityRecord?> createIdentity({String? name}) async {
    if (busy) return null;
    if (identityDatabaseError != null) return null;
    busy = true;
    notifyListeners();
    try {
      final manager = await _ensureManager();
      final record = await manager.create(name: name);
      log('Created identity ${record.name}');
      await _updateNotification();
      return record;
    } catch (e) {
      log('Could not create identity: $e');
      return null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Make [id] the identity served to the MeshCore app.
  Future<bool> activateIdentity(String id) async {
    if (busy) return false;
    final manager = _manager;
    if (manager == null) return false;
    if (manager.activeId == id) return true;
    busy = true;
    notifyListeners();
    try {
      final runningServer =
          server != null && proxyStatus == ProxyStatus.running ? server : null;
      final ok = await manager.activate(
        id,
        switchBridge: runningServer?.switchBridge,
      );
      if (ok) {
        final name = manager.activeSummary?.name ?? id;
        log('Activated identity $name');
        await _updateNotification();
      }
      return ok;
    } catch (e) {
      log('Identity activation failed: $e');
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Delete an inactive identity. The manager and repository enforce the
  /// active/last-identity rules.
  Future<bool> deleteIdentity(String id) async {
    if (busy) return false;
    final manager = _manager;
    if (manager == null) return false;
    busy = true;
    notifyListeners();
    try {
      await manager.delete(id);
      log('Deleted one identity');
      await _updateNotification();
      return true;
    } catch (e) {
      log('Could not delete identity: $e');
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }

  /// Clear contacts, channels, messages, advert paths, and non-name prefs for
  /// one identity while keeping its key and current name.
  Future<bool> clearLocalData(String id) async {
    if (busy) return false;
    final manager = _manager;
    if (manager == null) return false;
    busy = true;
    notifyListeners();
    try {
      final wasActive = manager.activeId == id;
      await manager.clearLocalData(id);
      if (wasActive && (server?.hasClient ?? false)) {
        await server!.disconnectClient(reason: 'local data cleared');
      }
      log('Cleared local data for one identity');
      return true;
    } catch (e) {
      log('Could not clear local identity data: $e');
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
  Future<bool> connectTcp({required String host, int? tcpPort}) async {
    final normalizedHost = host.trim();
    final devicePort = tcpPort ?? defaultCompanionPort;
    if (normalizedHost.isEmpty || devicePort < 1 || devicePort > 65535) {
      log('Enter a host and a port between 1 and 65535');
      return false;
    }
    final link = _tcpLinkFactory(normalizedHost, devicePort, log);
    final ok = await _attachLink(
      link,
      'TCP ${formatNetworkAddress(normalizedHost, devicePort)}',
    );
    if (!ok) return false;
    await _recordSession(SessionConfig(
      kind: DeviceTargetKind.tcp,
      host: normalizedHost,
      devicePort: devicePort,
      proxyPort: port,
      autoResume: autoResume,
    ));
    await _recordNetworkConnection(normalizedHost, devicePort);
    return true;
  }

  Future<bool> connectBle(BluetoothDevice device) async {
    if (!capabilities.supportsBle) {
      log('BLE is not available in this build');
      return false;
    }
    final link = BleDeviceLink(device: device, onLog: log);
    final name = device.platformName.isEmpty
        ? device.remoteId.toString()
        : device.platformName;
    final ok = await _attachLink(link, 'BLE $name');
    if (!ok) return false;
    await _recordSession(SessionConfig(
      kind: DeviceTargetKind.ble,
      bleRemoteId: device.remoteId.str,
      bleName: name,
      proxyPort: port,
      autoResume: autoResume,
    ));
    return true;
  }

  /// Attach the in-memory simulated companion (development builds only).
  ///
  /// Exercises every live identity, the companion server, and the UI without
  /// any radio: [FakeDeviceLink] answers device queries and radio-parameter
  /// requests, and its transmissions never leave the process.
  Future<bool> connectSimulated({RadioLink? simulatedLink}) async {
    if (!capabilities.supportsSimulatedCompanion) {
      log('The simulated companion is only available in development builds');
      return false;
    }
    final link =
        simulatedLink ?? FakeDeviceLink(deviceNodeName: 'Simulated companion');
    final ok = await _attachLink(link, 'Simulated companion');
    if (!ok) return false;
    await _recordSession(SessionConfig(
      kind: DeviceTargetKind.simulated,
      proxyPort: port,
      autoResume: autoResume,
    ));
    return true;
  }

  Future<void> _recordNetworkConnection(String host, int port) =>
      _mutateNetworkConnections(() async {
        _publishNetworkConnections(
          withRecordedNetworkConnection(
            _savedNetworkConnections,
            host: host,
            port: port,
            connectedAt: DateTime.now().toUtc().millisecondsSinceEpoch,
          ),
        );
        try {
          await networkConnectionStore.save(_savedNetworkConnections);
        } catch (e) {
          log('Could not save network connection history: $e');
        }
      });

  /// Serializes history read-modify-write operations.
  ///
  /// The store already serializes file writes; this also prevents a delete,
  /// Undo, or successful connect from publishing a stale in-memory snapshot.
  Future<T> _mutateNetworkConnections<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _networkConnectionMutations = _networkConnectionMutations.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, stack) {
        completer.completeError(e, stack);
      }
    });
    return completer.future;
  }

  void _publishNetworkConnections(List<SavedNetworkConnection> connections) {
    _savedNetworkConnections = connections;
    notifyListeners();
  }

  /// Remove a saved target. The in-memory list changes only after the file
  /// write succeeds, so a failed delete leaves the card visible.
  Future<bool> removeSavedNetworkConnection(
    SavedNetworkConnection connection,
  ) =>
      _mutateNetworkConnections(
        () => _saveNetworkConnections(
          withoutNetworkConnection(_savedNetworkConnections, connection.key),
          failureLog: 'Could not remove the saved network connection',
        ),
      );

  /// Restore a removed target with its original timestamp.
  ///
  /// A newer entry for the same key wins if the user reconnected before Undo.
  Future<bool> restoreSavedNetworkConnection(
    SavedNetworkConnection connection,
  ) =>
      _mutateNetworkConnections(
        () => _saveNetworkConnections(
          withRestoredNetworkConnection(_savedNetworkConnections, connection),
          failureLog: 'Could not restore the saved network connection',
        ),
      );

  Future<bool> _saveNetworkConnections(
    List<SavedNetworkConnection> next, {
    required String failureLog,
  }) async {
    try {
      await networkConnectionStore.save(next);
    } catch (e) {
      log('$failureLog: $e');
      return false;
    }
    _publishNetworkConnections(next);
    return true;
  }

  Future<bool> _attachLink(RadioLink link, String label) async {
    busy = true;
    _connectingLink = link;
    _connectCancelled = false;
    notifyListeners();
    try {
      await disconnectDevice();
      if (_connectCancelled) return false;
      final manager = await _ensureManager();
      if (!manager.loaded) {
        log(identityDatabaseError ?? 'Identity database unavailable');
        return false;
      }
      log('Connecting to $label ...');
      await connectWithBackoff(
        link,
        onLog: log,
        shouldCancel: () => _connectCancelled,
      );
      if (_connectCancelled) return false;
      this.link = link;
      deviceLabel = label;
      deviceConnected = true;

      final deviceInfo = await link.deviceInfo();
      final selfInfo = await link.selfInfo();
      final physical = PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: selfInfo.maxTxPower,
      );
      log('Device: fw ${deviceInfo.firmwareVerCode}, '
          '${deviceInfo.manufacturer} ${deviceInfo.version}');
      await manager.startLive(
        base: link,
        physical: physical,
        radioParams: selfInfo.radioParams,
        devicePublicKey: selfInfo.publicKey,
      );
      final liveCount =
          manager.runtimes.where((runtime) => runtime.live).length;
      if (manager.activeNode == null) {
        log('Active identity is unavailable; $liveCount other identities live');
      } else {
        log('Device link ready; $liveCount identities live');
      }
      _watchLink(link);
      await _startForegroundService();
      await _updateNotification();
      return true;
    } catch (e) {
      if (!_connectCancelled) log('Device connection failed: $e');
      if (identical(this.link, link)) {
        await disconnectDevice();
      } else {
        await link.disconnect();
      }
      return false;
    } finally {
      _connectingLink = null;
      _connectCancelled = false;
      busy = false;
      notifyListeners();
    }
  }

  Future<void> cancelPendingConnection() async {
    final pending = _connectingLink;
    if (pending == null) return;
    _connectCancelled = true;
    try {
      await pending.disconnect();
    } catch (e) {
      log('Connection cancellation failed: $e');
    }
  }

  Future<bool> setProxyPort(int value) async {
    if (value < 1 || value > 65535 || proxyStatus == ProxyStatus.running) {
      return false;
    }
    port = value;
    final current = lastSession;
    if (current != null) {
      final updated = current.copyWith(proxyPort: value);
      lastSession = updated;
      await sessionStore.save(updated);
    }
    notifyListeners();
    return true;
  }

  /// Persist the last session so it can be restored on the next launch.
  Future<void> _recordSession(SessionConfig session) async {
    lastSession = session;
    _intentionalOff = false;
    await sessionStore.save(session);
    notifyListeners();
  }

  /// Toggle automatic session restore (reconnect the last device and restart the
  /// proxy when the app opens).
  Future<void> setAutoResume(bool value) async {
    autoResume = value;
    final current = lastSession;
    if (current != null) {
      final updated = current.copyWith(autoResume: value);
      lastSession = updated;
      await sessionStore.save(updated);
    }
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
          await connectBle(BluetoothDevice.fromId(remoteId));
        case DeviceTargetKind.simulated:
          if (!capabilities.supportsSimulatedCompanion) {
            log('Saved session used the simulated companion, unavailable here');
            return;
          }
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
  Future<void> refreshBatteryOptimizationStatus() async {
    if (!Platform.isAndroid) return;
    try {
      batteryOptimizationsIgnored =
          await _foreground.isIgnoringBatteryOptimizations();
      notifyListeners();
    } catch (e) {
      log('Battery optimization check failed: $e');
    }
  }

  /// Ask the OS for a battery-optimization exemption so the background device
  /// link and proxy are not throttled. Re-checks the status after the prompt.
  Future<void> requestBatteryOptimizationExemption() async {
    if (!Platform.isAndroid) return;
    try {
      await _foreground.requestBatteryOptimizationExemption();
      await refreshBatteryOptimizationStatus();
    } catch (e) {
      log('Battery optimization request failed: $e');
    }
  }

  StreamSubscription<LinkState>? _linkStateSub;
  Timer? _reconnectTimer;
  bool _disconnecting = false;

  /// Watch [link] for unexpected drops so the session can be restored.
  void _watchLink(RadioLink link) {
    _linkStateSub?.cancel();
    _linkStateSub = link.state.listen((state) {
      if (state == LinkState.disconnected &&
          !_disconnecting &&
          !_intentionalOff &&
          deviceConnected) {
        log('Device link dropped; scheduling reconnect');
        _scheduleReconnect();
      }
    });
  }

  void _scheduleReconnect() {
    if (_intentionalOff) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      unawaited(_reconnect());
    });
  }

  /// Reconnect the device link and re-apply the shared physical snapshot
  /// without disturbing the live runtimes, the proxy server, or its client.
  Future<void> _reconnect() async {
    final curLink = link;
    final manager = _manager;
    if (curLink == null ||
        manager == null ||
        _disconnecting ||
        _intentionalOff) {
      return;
    }
    try {
      log('Reconnecting device ...');
      await connectWithBackoff(curLink, onLog: log);
      final deviceInfo = await curLink.deviceInfo();
      final selfInfo = await curLink.selfInfo();
      final physical = PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: selfInfo.maxTxPower,
      );
      await manager.reapplyPhysical(
        physical: physical,
        radioParams: selfInfo.radioParams,
      );
      log('Device link reconnected');
      notifyListeners();
    } catch (e) {
      log('Reconnect failed: $e');
      _scheduleReconnect();
    }
  }

  Future<void> _onNodePoweredOff() async {
    _intentionalOff = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final manager = _manager;
    await manager?.stopLive();
    deviceConnected = false;
    log('Device powered off; automatic reconnect suppressed');
    final current = lastSession;
    if (current != null) {
      final updated = current.copyWith(intentionallyOff: true);
      lastSession = updated;
      try {
        await sessionStore.save(updated);
      } catch (e) {
        log('Could not persist intentional shutdown: $e');
      }
    }
    try {
      await server?.stop();
      server = null;
      proxyStatus = ProxyStatus.stopped;
    } catch (_) {}
    try {
      await _foreground.stop();
    } catch (_) {
      // The service may already be gone after the device powered off.
    }
    _foregroundStarted = false;
    _lastNotificationText = null;
    notifyListeners();
  }

  Future<void> disconnectDevice() async {
    if (server != null || proxyStatus == ProxyStatus.running) {
      await stopProxy();
    }
    _disconnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _linkStateSub?.cancel();
    _linkStateSub = null;
    await _manager?.stopLive();
    try {
      await link?.disconnect();
    } finally {
      link = null;
      deviceConnected = false;
      deviceLabel = null;
      try {
        await _foreground.stop();
      } catch (_) {
        // The service may already be stopped.
      }
      _foregroundStarted = false;
      _lastNotificationText = null;
      _disconnecting = false;
      notifyListeners();
    }
  }

  /// Persistent-notification text reflecting the live identity count and state.
  String _notificationText() {
    final count = identities.length;
    final active = activeIdentity?.name;
    final identityPart = count == 0
        ? 'no identity'
        : '$count ${count == 1 ? 'identity' : 'identities'}'
            '${active == null ? '' : ' · $active'}';
    final linkPart = deviceConnected ? 'device linked' : 'no device';
    final serverPart = proxyStatus == ProxyStatus.running
        ? 'serving :$port'
        : 'server stopped';
    return '$identityPart · $linkPart · $serverPart';
  }

  Future<void> _startForegroundService() async {
    try {
      await _foreground.start(
        title: 'MeshChameleon',
        text: _notificationText(),
      );
      _foregroundStarted = true;
      _lastNotificationText = _notificationText();
    } catch (e) {
      log('Foreground service unavailable: $e');
    }
  }

  Future<void> _updateNotification() async {
    try {
      final text = _notificationText();
      await _foreground.update(title: 'MeshChameleon', text: text);
      _lastNotificationText = text;
    } catch (e) {
      log('Foreground service update failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Proxy server
  // -------------------------------------------------------------------------

  Future<void> startProxy({int? serverPort}) async {
    final active = node;
    if (active == null) {
      log(identities.isEmpty
          ? 'No identity available'
          : deviceConnected
              ? 'The active identity is unavailable'
              : 'Connect a device first');
      return;
    }
    server ??= CompanionServer(
      bridge: active,
      config: CompanionServerConfig(port: serverPort ?? port),
      onLog: log,
    );
    try {
      await server!.start();
      port = server!.port ?? port;
      proxyStatus = ProxyStatus.running;
      log('Proxy server listening on port $port');
      await _updateNotification();
    } catch (e) {
      log('Failed to start proxy: $e');
      await server?.stop();
      server = null;
    }
    notifyListeners();
  }

  Future<void> stopProxy() async {
    await server?.stop();
    server = null;
    proxyStatus = ProxyStatus.stopped;
    await _updateNotification();
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _reconnectTimer?.cancel();
    unawaited(_linkStateSub?.cancel());
    unawaited(server?.stop());
    unawaited(_manager?.dispose());
    unawaited(link?.disconnect());
    super.dispose();
  }
}
