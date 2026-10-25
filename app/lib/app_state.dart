import 'dart:async';
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
import 'services/identity_store.dart';
import 'services/session_store.dart';

enum ProxyStatus { stopped, running }

/// Owns the identity, the device link, the mesh node, and the companion server,
/// and exposes them to the UI.
class AppState extends ChangeNotifier {
  AppState({
    IdentityStore? store,
    SessionStore? sessionStore,
    NodeStore? nodeStore,
    DeviceCapabilities? capabilities,
    this.reconnectDelay = const Duration(seconds: 3),
  })  : store = store ?? IdentityStore(),
        sessionStore = sessionStore ?? SessionStore(),
        _nodeStoreInstance = nodeStore,
        capabilities = capabilities ?? DeviceCapabilities.current();

  final IdentityStore store;
  final SessionStore sessionStore;

  /// What this build can do; gates the BLE UI and session restore.
  final DeviceCapabilities capabilities;

  /// Delay before an unexpected link drop is retried.
  final Duration reconnectDelay;

  /// Foreground service that keeps the process alive while backgrounded.
  final ForegroundService _foreground = ForegroundService();

  LocalIdentity? identity;
  RadioLink? link;
  MeshNode? node;
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

  /// Whether the OS exempts the app from battery optimizations (null until
  /// queried; always null on non-Android platforms).
  bool? batteryOptimizationsIgnored;

  /// Diagnostic age/staleness for the radio's last good voltage sample.
  int? get batterySampleAgeSeconds => node?.batterySampleAgeSeconds;
  bool get batteryStale => node?.batteryStale ?? true;
  String? get batteryDiagnostic => node?.batteryDiagnostic;

  final List<String> logs = [];

  NodeStore? _nodeStoreInstance;

  /// Lazily create the on-disk node-state store (contacts, channels, queue,
  /// prefs) under the app's support directory.
  Future<NodeStore> _nodeStore() async {
    final existing = _nodeStoreInstance;
    if (existing != null) return existing;
    final dir = await getApplicationSupportDirectory();
    final store = JsonNodeStore(file: File('${dir.path}/node_state.json'));
    _nodeStoreInstance = store;
    return store;
  }

  void log(String message) {
    logs.add('${DateTime.now().toIso8601String()}  $message');
    if (logs.length > 500) logs.removeAt(0);
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // Identity
  // -------------------------------------------------------------------------

  Future<void> loadIdentity() async {
    identity = await store.load();
    final session = await sessionStore.load();
    lastSession = session;
    if (session != null) {
      port = session.proxyPort;
      autoResume = session.autoResume;
      _intentionalOff = session.intentionallyOff;
    }
    notifyListeners();
    await _maybeResumeSession();
  }

  Future<void> generateIdentity() async {
    final runningNode = node;
    if (runningNode != null) {
      await runningNode.replaceIdentity(await LocalIdentity.generate());
      log('Generated identity ${_pubkeyPrefix()}');
      notifyListeners();
      return;
    }
    identity = await store.generate();
    log('Generated identity ${_pubkeyPrefix()}');
    final connectedLink = link;
    if (connectedLink != null) {
      await _initializeNode(connectedLink);
    }
    notifyListeners();
  }

  Future<void> importIdentity(Uint8List key) async {
    final runningNode = node;
    if (runningNode != null) {
      await runningNode.replaceIdentity(await LocalIdentity.import(key));
      log('Imported identity ${_pubkeyPrefix()}');
      notifyListeners();
      return;
    }
    identity = await store.import(key);
    log('Imported identity ${_pubkeyPrefix()}');
    final connectedLink = link;
    if (connectedLink != null) {
      await _initializeNode(connectedLink);
    }
    notifyListeners();
  }

  /// Import the connected device's identity (one-time bootstrap).
  ///
  /// Sends `CMD_EXPORT_PRIVATE_KEY` over the live device link. Returns false
  /// (logging a reason) when no device is connected or the firmware disables
  /// export. The key is never logged. On success it follows the same shared
  /// virtual replacement path as manual import, keeping the device link up.
  Future<bool> importIdentityFromDevice() async {
    final link = this.link;
    if (link == null || !deviceConnected) {
      log('Connect a device first');
      return false;
    }
    try {
      final key = await link.exportPrivateKey();
      if (key == null) {
        log('Device firmware disables private-key export');
        return false;
      }
      await importIdentity(key);
      return true;
    } catch (e) {
      log('Import from device failed: $e');
      return false;
    }
  }

  Future<Uint8List?> exportIdentity() async {
    final runningNode = node;
    if (runningNode != null) return runningNode.exportPrivateKey();
    return store.exportKey();
  }

  /// Staged app-only virtual data reset. This never disconnects the radio,
  /// reboots it, or changes device-target/proxy settings.
  ///
  /// The durable state reset happens first. When [rotateIdentity] is requested,
  /// a validated new key is persisted only after that succeeds; a key failure
  /// returns a partial result with the old identity still active.
  Future<VirtualResetResult> resetVirtualData({
    bool rotateIdentity = false,
  }) async {
    final runningNode = node;
    if (runningNode != null) {
      final result = await runningNode.resetVirtualData(
        rotateIdentity: rotateIdentity,
      );
      if (result.dataReset) server?.clearSigningBuffer();
      notifyListeners();
      return result;
    }

    LocalIdentity? candidate;
    if (rotateIdentity) {
      candidate = await LocalIdentity.generate();
      if (!await LocalIdentity.validateMeshcore64(candidate.meshcore64)) {
        throw const CompanionOperationError(
          errCodeIllegalArg,
          message: 'generated identity failed validation',
        );
      }
    }

    final nodeStore = await _nodeStore();
    await nodeStore.flush();
    try {
      await nodeStore.save(freshVirtualState());
    } catch (e) {
      throw CompanionOperationError(
        errCodeFileIoError,
        message: 'virtual reset persistence failed: $e',
      );
    }

    if (candidate != null) {
      try {
        await store.save(candidate);
        identity = candidate;
      } catch (e) {
        LocalIdentity? readBack;
        try {
          readBack = await store.load();
        } catch (_) {
          readBack = null;
        }
        if (readBack != null &&
            readBack.meshcore64.length == 64 &&
            bytesToHex(readBack.meshcore64) ==
                bytesToHex(candidate.meshcore64)) {
          identity = readBack;
        } else {
          notifyListeners();
          return VirtualResetResult(
            dataReset: true,
            identityRotated: false,
            keyError: CompanionOperationError(
              errCodeFileIoError,
              message: 'new identity persistence failed: $e',
            ),
          );
        }
      }
    }
    notifyListeners();
    return VirtualResetResult(
      dataReset: true,
      identityRotated: candidate != null,
    );
  }

  void _onNodeIdentityChanged(LocalIdentity changed) {
    identity = changed;
    log('Active identity changed to ${_pubkeyPrefix()}');
    notifyListeners();
  }

  Future<void> _onNodePoweredOff() async {
    _intentionalOff = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
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
      await _foreground.stop();
    } catch (_) {
      // The service may already be gone after the device powered off.
    }
    notifyListeners();
  }

  String _pubkeyPrefix() {
    final key = identity?.publicKey;
    if (key == null) return '(none)';
    return bytesToHex(key.sublist(0, 4));
  }

  // -------------------------------------------------------------------------
  // Device link
  // -------------------------------------------------------------------------

  Future<void> connectTcp({required String host, int? tcpPort}) async {
    final devicePort = tcpPort ?? defaultCompanionPort;
    final link = TcpDeviceLink(
      host: host,
      port: devicePort,
      onLog: log,
    );
    final ok = await _attachLink(link, 'TCP $host:$devicePort');
    if (ok) {
      await _recordSession(SessionConfig(
        kind: DeviceTargetKind.tcp,
        host: host,
        devicePort: devicePort,
        proxyPort: port,
        autoResume: autoResume,
      ));
    }
  }

  Future<void> connectBle(BluetoothDevice device) async {
    if (!capabilities.supportsBle) {
      log('BLE is not available in this build');
      return;
    }
    final link = BleDeviceLink(device: device, onLog: log);
    final name = device.platformName.isEmpty
        ? device.remoteId.toString()
        : device.platformName;
    final ok = await _attachLink(link, 'BLE $name');
    if (ok) {
      await _recordSession(SessionConfig(
        kind: DeviceTargetKind.ble,
        bleRemoteId: device.remoteId.str,
        bleName: name,
        proxyPort: port,
        autoResume: autoResume,
      ));
    }
  }

  /// Attach the in-memory simulated companion (development builds only).
  ///
  /// Exercises the mesh node, the companion server, and the UI without any
  /// radio: [FakeDeviceLink] answers device queries and radio-parameter
  /// requests, and its transmissions never leave the process. Tests may pass
  /// their own [simulatedLink] to observe the attach sequence.
  Future<void> connectSimulated({RadioLink? simulatedLink}) async {
    if (!capabilities.supportsSimulatedCompanion) {
      log('The simulated companion is only available in development builds');
      return;
    }
    final link =
        simulatedLink ?? FakeDeviceLink(deviceNodeName: 'Simulated companion');
    final ok = await _attachLink(link, 'Simulated companion');
    if (ok) {
      await _recordSession(SessionConfig(
        kind: DeviceTargetKind.simulated,
        proxyPort: port,
        autoResume: autoResume,
      ));
    }
  }

  Future<bool> _attachLink(RadioLink link, String label) async {
    busy = true;
    _connectingLink = link;
    _connectCancelled = false;
    notifyListeners();
    try {
      await disconnectDevice();
      if (_connectCancelled) return false;
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
      if (identity != null) {
        await _initializeNode(
          link,
          physical: physical,
          params: selfInfo.radioParams,
        );
      } else {
        log('Device link ready; import its identity or create one');
        _watchLink(link);
        await _startForegroundService();
      }
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

  Future<void> _initializeNode(
    RadioLink link, {
    PhysicalCapabilities? physical,
    RadioParams? params,
  }) async {
    final currentIdentity = identity;
    if (currentIdentity == null) return;
    if (physical == null || params == null) {
      final selfInfo = await link.selfInfo();
      physical ??= PhysicalCapabilities.fromDeviceInfo(
        await link.deviceInfo(),
        maxTxPower: selfInfo.maxTxPower,
      );
      params ??= selfInfo.radioParams;
    }
    final node = MeshNode(
      identity: currentIdentity,
      link: link,
      physical: physical,
      store: await _nodeStore(),
      identityPersistence: store,
      onIdentityChanged: _onNodeIdentityChanged,
      onPoweredOff: _onNodePoweredOff,
    );
    await node.load();
    // The device is the source of truth for RF parameters at connect time.
    // Name, location, path-hash mode and other preferences stay virtual.
    node.adoptPhysicalCapabilities(physical);
    node.syncRadioParams(params);
    node.start();
    this.node = node;
    log('Device link ready; mesh node started');
    _watchLink(link);
    await _startForegroundService();
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
    if (session == null || !autoResume || identity == null || deviceConnected) {
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

  /// Reconnect the device link and re-arm the mesh node without disturbing the
  /// app-facing proxy server or its client. Retries again on failure.
  Future<void> _reconnect() async {
    final curLink = link;
    final curNode = node;
    if (curLink == null ||
        curNode == null ||
        _disconnecting ||
        _intentionalOff) {
      return;
    }
    try {
      log('Reconnecting device ...');
      await connectWithBackoff(curLink, onLog: log);
      final deviceInfo = await curLink.deviceInfo();
      final selfInfo = await curLink.selfInfo();
      curNode.adoptPhysicalCapabilities(PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: selfInfo.maxTxPower,
      ));
      curNode.syncRadioParams(selfInfo.radioParams);
      curNode.start();
      log('Device link reconnected');
      notifyListeners();
    } catch (e) {
      log('Reconnect failed: $e');
      _scheduleReconnect();
    }
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
    node?.stop();
    node = null;
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
      _disconnecting = false;
      notifyListeners();
    }
  }

  /// Persistent-notification text reflecting the current link/server state.
  String _notificationText() {
    final linkPart = deviceConnected ? 'device linked' : 'no device';
    final serverPart = proxyStatus == ProxyStatus.running
        ? 'serving :$port'
        : 'server stopped';
    return '$linkPart · $serverPart';
  }

  Future<void> _startForegroundService() async {
    try {
      await _foreground.start(
        title: 'MeshChameleon',
        text: _notificationText(),
      );
    } catch (e) {
      log('Foreground service unavailable: $e');
    }
  }

  Future<void> _updateNotification() async {
    try {
      await _foreground.update(
        title: 'MeshChameleon',
        text: _notificationText(),
      );
    } catch (e) {
      log('Foreground service update failed: $e');
    }
  }

  // -------------------------------------------------------------------------
  // Proxy server
  // -------------------------------------------------------------------------

  Future<void> startProxy({int? serverPort}) async {
    if (node == null) {
      log(identity == null
          ? 'Generate or import an identity first'
          : 'Connect a device first');
      return;
    }
    server ??= CompanionServer(
      bridge: node!,
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
    _reconnectTimer?.cancel();
    unawaited(_linkStateSub?.cancel());
    unawaited(server?.stop());
    node?.stop();
    unawaited(link?.disconnect());
    super.dispose();
  }
}
