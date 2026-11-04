import 'dart:async';

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;

import 'ble_device_link.dart';
import 'device_capabilities.dart';
import 'identity_manager.dart';
import 'network_address.dart';
import 'network_connection_history.dart';
import 'session_settings.dart';
import 'session_store.dart';

/// Creates the TCP link used to reach a network companion.
///
/// Tests supply a [FakeDeviceLink]; production uses [TcpDeviceLink].
typedef TcpDeviceLinkFactory = RadioLink Function(
  String host,
  int port,
  void Function(String message) onLog,
);

/// The session-level services the connection controller needs from its owner.
///
/// Keeping these on an interface lets connection behavior be tested without the
/// identity storage graph, while [AppState] remains the composition root.
abstract class ConnectionHost {
  Future<IdentityManager> ensureManager();
  IdentityManager? get manager;

  bool get busy;
  set busy(bool value);

  void notify();
  void log(String message);

  bool get proxyRunning;
  Future<void> stopProxy();
  Future<void> startProxy({int? serverPort});

  /// True when the identity catalog is loaded and usable.
  bool get identityCatalogReady;

  Future<void> startForegroundService();
  Future<void> stopForegroundService();
  Future<void> updateNotification();
  void resetNotificationState();

  Future<void> recordSession(SessionConfig session);
  Future<void> recordNetworkConnection(String host, int port);
}

/// TCP, BLE, and simulated device sessions, plus reconnect/power-off handling.
///
/// The controller owns the physical link and its session state; proxy and
/// foreground lifecycle stay with the owner behind [ConnectionHost].
class ConnectionController {
  ConnectionController({
    required this.host,
    required this.tcpLinkFactory,
    required this.capabilities,
    required this.metrics,
    required this.sessionSettings,
    required this.networkHistory,
    this.reconnectDelay = const Duration(seconds: 3),
    this.maxReconnectFailures = 3,
  });

  final ConnectionHost host;
  final TcpDeviceLinkFactory tcpLinkFactory;
  final DeviceCapabilities capabilities;
  final LinkMetrics metrics;
  final SessionSettings sessionSettings;
  final NetworkConnectionHistory networkHistory;
  final Duration reconnectDelay;

  /// Consecutive failed reconnects tolerated before the session is torn down.
  ///
  /// A dropped radio is retried so a brief out-of-range period can recover. If
  /// the link cannot be restored, stop serving the client instead of leaving it
  /// talking to a dead radio; the MeshCore app then sees the proxy disconnect.
  final int maxReconnectFailures;

  RadioLink? link;
  String? deviceLabel;
  bool deviceConnected = false;

  /// True while an unexpected drop is being retried. The proxy stays up during
  /// this window so a transient drop does not evict the MeshCore client, but
  /// the UI must not claim the radio is live.
  bool deviceReconnecting = false;
  DeviceInfo? deviceInfo;
  DateTime? deviceConnectedAt;
  int reconnectAttempts = 0;
  int reconnectSuccesses = 0;

  Duration? get deviceSessionDuration => deviceConnectedAt == null
      ? null
      : DateTime.now().difference(deviceConnectedAt!);

  RadioLink? _connectingLink;
  bool _connectCancelled = false;

  /// Serializes connect, disconnect, reconnect, and power-off transitions.
  /// Their asynchronous cleanup must never race a newer session.
  Future<void>? _tail;

  StreamSubscription<LinkState>? _linkStateSub;
  Timer? _reconnectTimer;
  bool _disconnecting = false;
  bool _disconnectRequested = false;
  bool _reconnecting = false;
  bool _rearming = false;
  int _reconnectFailures = 0;

  /// Set when the session ended because the physical link could not be
  /// restored. A foreground resume retries the saved device from here.
  bool _linkLost = false;

  Future<T> _runTransition<T>(Future<T> Function() action) {
    final previous = _tail;
    final run = previous == null
        ? action()
        : previous.then(
            (_) => action(),
            onError: (Object _) => action(),
          );
    _tail = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<bool> connectTcp({required String host, int? tcpPort}) =>
      _runTransition(() => _connectTcp(host: host, tcpPort: tcpPort));

  Future<bool> _connectTcp({required String host, int? tcpPort}) async {
    final normalizedHost = host.trim();
    final devicePort = tcpPort ?? defaultCompanionPort;
    if (!isValidTcpHost(normalizedHost) || !isValidTcpPort(devicePort)) {
      this.host.log('Enter a host and a port between 1 and 65535');
      return false;
    }
    final link = MeteredRadioLink(
      tcpLinkFactory(normalizedHost, devicePort, this.host.log),
      metrics: metrics,
    );
    final ok = await _attachLink(
      link,
      'TCP ${formatNetworkAddress(normalizedHost, devicePort)}',
    );
    if (!ok) return false;
    await this.host.recordSession(SessionConfig(
          kind: DeviceTargetKind.tcp,
          host: normalizedHost,
          devicePort: devicePort,
          proxyPort: sessionSettings.port,
          autoResume: sessionSettings.autoResume,
        ));
    await this.host.recordNetworkConnection(normalizedHost, devicePort);
    return true;
  }

  Future<bool> connectBle(BluetoothDevice device, {String? displayName}) =>
      _runTransition(() => _connectBle(device, displayName: displayName));

  Future<bool> _connectBle(
    BluetoothDevice device, {
    String? displayName,
  }) async {
    if (!capabilities.supportsBle) {
      host.log('BLE is not available in this build');
      return false;
    }
    final link = MeteredRadioLink(
      BleDeviceLink(device: device, onLog: host.log),
      metrics: metrics,
    );
    final preferred = displayName?.trim();
    final advertisedName = device.advName.trim();
    final platformName = device.platformName.trim();
    final name = preferred != null && preferred.isNotEmpty
        ? preferred
        : advertisedName.isNotEmpty
            ? advertisedName
            : platformName.isNotEmpty
                ? platformName
                : device.remoteId.toString();
    final ok = await _attachLink(link, 'BLE $name');
    if (!ok) return false;
    await host.recordSession(SessionConfig(
      kind: DeviceTargetKind.ble,
      bleRemoteId: device.remoteId.str,
      bleName: name,
      proxyPort: sessionSettings.port,
      autoResume: sessionSettings.autoResume,
    ));
    return true;
  }

  /// Attach the in-memory simulated companion.
  ///
  /// Exercises every live identity, the companion server, and the UI without
  /// any radio: [FakeDeviceLink] answers device queries and radio-parameter
  /// requests, and its transmissions never leave the process.
  Future<bool> connectSimulated({RadioLink? simulatedLink}) =>
      _runTransition(() => _connectSimulated(simulatedLink: simulatedLink));

  Future<bool> _connectSimulated({RadioLink? simulatedLink}) async {
    final link = MeteredRadioLink(
      simulatedLink ?? FakeDeviceLink(deviceNodeName: 'Simulated companion'),
      metrics: metrics,
    );
    final ok = await _attachLink(link, 'Simulated companion');
    if (!ok) return false;
    await host.recordSession(SessionConfig(
      kind: DeviceTargetKind.simulated,
      proxyPort: sessionSettings.port,
      autoResume: sessionSettings.autoResume,
    ));
    return true;
  }

  bool _linkReadyForAttach(RadioLink link) =>
      !_connectCancelled && link.currentState == LinkState.connected;

  Future<bool> _attachLink(RadioLink link, String label) async {
    host.busy = true;
    _connectingLink = link;
    _connectCancelled = false;
    host.notify();
    try {
      await _disconnectDevice();
      if (_connectCancelled) return false;
      final manager = await host.ensureManager();
      if (!manager.loaded) {
        host.log(manager.databaseError ?? 'Identity database unavailable');
        return false;
      }
      host.log('Connecting to $label ...');
      await connectWithBackoff(
        link,
        onLog: host.log,
        shouldCancel: () => _connectCancelled,
      );
      if (!_linkReadyForAttach(link)) {
        await link.disconnect();
        return false;
      }
      this.link = link;
      deviceLabel = label;
      deviceConnected = true;

      final deviceInfo = await link.deviceInfo();
      final selfInfo = await link.selfInfo();
      if (!_linkReadyForAttach(link)) {
        await _disconnectDevice();
        return false;
      }
      final physical = PhysicalCapabilities.fromDeviceInfo(
        deviceInfo,
        maxTxPower: selfInfo.maxTxPower,
      );
      host.log('Device: fw ${deviceInfo.firmwareVerCode}, '
          '${deviceInfo.manufacturer} ${deviceInfo.version}');
      await manager.startLive(
        base: link,
        physical: physical,
        radioParams: selfInfo.radioParams,
        devicePublicKey: selfInfo.publicKey,
      );
      if (!_linkReadyForAttach(link)) {
        await _disconnectDevice();
        return false;
      }
      this.deviceInfo = deviceInfo;
      deviceConnectedAt = DateTime.now();
      final liveCount =
          manager.runtimes.where((runtime) => runtime.live).length;
      if (manager.activeNode == null) {
        host.log(
          'Active identity is unavailable; $liveCount other identities live',
        );
      } else {
        host.log('Device link ready; $liveCount identities live');
      }
      _watchLink(link);
      await host.startForegroundService();
      if (_connectCancelled) {
        await _disconnectDevice();
        return false;
      }
      await host.updateNotification();
      if (_connectCancelled) {
        await _disconnectDevice();
        return false;
      }
      _linkLost = false;
      return true;
    } catch (e) {
      if (!_connectCancelled) host.log('Device connection failed: $e');
      if (identical(this.link, link)) {
        await _disconnectDevice();
      } else {
        await link.disconnect();
      }
      return false;
    } finally {
      _connectingLink = null;
      _connectCancelled = false;
      host.busy = false;
      host.notify();
    }
  }

  /// Reconnect the saved device and restart the proxy after a launch, if the
  /// user enabled auto-resume. Best-effort: failures are logged, not fatal.
  Future<void> resumeSession() async {
    final session = sessionSettings.lastSession;
    if (session == null ||
        !sessionSettings.autoResume ||
        !host.identityCatalogReady ||
        deviceConnected) {
      return;
    }
    if (session.intentionallyOff) {
      host.log(
          'Last session ended with an intentional shutdown; not auto-resuming');
      return;
    }
    host.log('Resuming last device session ...');
    try {
      switch (session.kind) {
        case DeviceTargetKind.tcp:
          final hostName = session.host;
          if (hostName == null) return;
          await connectTcp(host: hostName, tcpPort: session.devicePort);
        case DeviceTargetKind.ble:
          if (!capabilities.supportsBle) {
            host.log(
                'Saved session used BLE, which this build does not support');
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
        await host.startProxy(serverPort: session.proxyPort);
      }
    } catch (e) {
      host.log('Session resume failed: $e');
    }
  }

  Future<void> cancelPendingConnection() async {
    final pending = _connectingLink;
    if (pending == null) return;
    _connectCancelled = true;
    try {
      await pending.disconnect();
    } catch (e) {
      host.log('Connection cancellation failed: $e');
    }
  }

  /// Watch [link] for unexpected drops so the session can be restored.
  void _watchLink(RadioLink link) {
    _linkStateSub?.cancel();
    void handle(LinkState state) {
      if (state != LinkState.disconnected ||
          _disconnecting ||
          _disconnectRequested ||
          sessionSettings.intentionallyOff ||
          _connectCancelled ||
          !deviceConnected ||
          _reconnecting ||
          _reconnectTimer != null) {
        return;
      }
      metrics.disconnected(unexpected: true);
      deviceConnectedAt = null;
      deviceReconnecting = true;
      host.log('Device link dropped; scheduling reconnect');
      host.notify();
      _scheduleReconnect();
    }

    _linkStateSub = link.state.listen(handle);
    // A drop can happen before the stream subscription is attached (for
    // example while startup awaits the foreground service).
    if (link.currentState == LinkState.disconnected) {
      handle(LinkState.disconnected);
    }
  }

  void _scheduleReconnect() {
    if (sessionSettings.intentionallyOff || _disconnectRequested) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      // Clear the handle when it fires: a stale non-null timer would make the
      // link watcher ignore every later drop after a successful reconnect.
      _reconnectTimer = null;
      unawaited(_runTransition(_reconnect));
    });
  }

  /// Reconnect the device link and re-apply the shared physical snapshot
  /// without disturbing the live runtimes, the proxy server, or its client.
  Future<void> _reconnect() async {
    final curLink = link;
    final manager = host.manager;
    if (curLink == null ||
        manager == null ||
        _disconnecting ||
        _disconnectRequested ||
        sessionSettings.intentionallyOff) {
      if (!_disconnecting) deviceReconnecting = false;
      return;
    }
    bool cancelled() =>
        _disconnectRequested ||
        _disconnecting ||
        sessionSettings.intentionallyOff ||
        !identical(curLink, link);
    _reconnecting = true;
    reconnectAttempts++;
    try {
      host.log('Reconnecting device ...');
      await connectWithBackoff(
        curLink,
        onLog: host.log,
        shouldCancel: cancelled,
      );
      if (cancelled() || curLink.currentState != LinkState.connected) {
        return;
      }
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
      if (cancelled() || curLink.currentState != LinkState.connected) {
        return;
      }
      this.deviceInfo = deviceInfo;
      deviceConnectedAt = DateTime.now();
      _reconnectFailures = 0;
      deviceReconnecting = false;
      reconnectSuccesses++;
      host.log('Device link reconnected');
      host.notify();
    } catch (e) {
      if (cancelled()) return;
      _reconnectFailures++;
      host.log('Reconnect failed: $e');
      if (_reconnectFailures >= maxReconnectFailures) {
        await _abandonSession();
      } else {
        _scheduleReconnect();
      }
    } finally {
      _reconnecting = false;
    }
  }

  /// Stop serving the client when the physical link cannot be restored.
  ///
  /// Tearing the session down (instead of leaving the proxy up) makes the
  /// MeshCore app notice that the companion is gone rather than sending into a
  /// dead link that reports success locally.
  Future<void> _abandonSession() async {
    host.log(
      'Device link lost after $_reconnectFailures failed reconnect cycles; '
      'stopping the session',
    );
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _linkLost = true;
    await _disconnectDevice();
  }

  /// Retry the saved device after a link-loss give-up.
  ///
  /// Called when the app returns to the foreground: a radio that was left
  /// behind may be back in range, and actively retrying all day would waste
  /// battery. Does nothing unless the last session ended from link loss.
  Future<void> rearmAfterLinkLoss() async {
    if (!_linkLost ||
        _rearming ||
        deviceConnected ||
        host.busy ||
        _reconnecting ||
        _disconnecting) {
      return;
    }
    if (!sessionSettings.autoResume) return;
    _rearming = true;
    host.log('Device link was lost; retrying the saved device on resume ...');
    try {
      await resumeSession();
    } finally {
      _rearming = false;
    }
  }

  Future<void> _onNodePoweredOff() async {
    final offPersisted = sessionSettings.markPoweredOff();
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final manager = host.manager;
    await manager?.stopLive();
    metrics.disconnected();
    deviceConnected = false;
    deviceConnectedAt = null;
    deviceInfo = null;
    deviceLabel = null;
    _reconnectFailures = 0;
    _linkLost = false;
    deviceReconnecting = false;
    host.log('Device powered off; automatic reconnect suppressed');
    await offPersisted;
    await host.stopProxy();
    await host.stopForegroundService();
    host.resetNotificationState();
    host.notify();
  }

  Future<void> handlePoweredOff() => _runTransition(_onNodePoweredOff);

  Future<void> disconnect() {
    // Drop a queued or in-flight reconnect immediately: tapping Disconnect must
    // not wait for a link retry to fail first.
    _linkLost = false;
    _disconnectRequested = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    return _runTransition(_disconnectDevice);
  }

  Future<void> _disconnectDevice() async {
    final wasBusy = host.busy;
    if (!wasBusy) {
      host.busy = true;
      host.notify();
    }
    // Mark the disconnect before awaiting anything so a link drop during
    // proxy shutdown cannot schedule an unexpected reconnect.
    _disconnecting = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    await _linkStateSub?.cancel();
    _linkStateSub = null;
    try {
      if (host.proxyRunning) {
        await host.stopProxy();
      }
      await host.manager?.stopLive();
      try {
        await link?.disconnect();
      } catch (e) {
        host.log('Could not disconnect the device link cleanly: $e');
      }
    } finally {
      link = null;
      deviceConnected = false;
      deviceConnectedAt = null;
      deviceInfo = null;
      deviceLabel = null;
      _reconnectFailures = 0;
      _disconnectRequested = false;
      deviceReconnecting = false;
      await host.stopForegroundService();
      host.resetNotificationState();
      _disconnecting = false;
      if (!wasBusy) host.busy = false;
      host.notify();
    }
  }

  void dispose() {
    _reconnectTimer?.cancel();
    unawaited(_linkStateSub?.cancel());
    unawaited(link?.disconnect());
  }
}
