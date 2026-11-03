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
  });

  final ConnectionHost host;
  final TcpDeviceLinkFactory tcpLinkFactory;
  final DeviceCapabilities capabilities;
  final LinkMetrics metrics;
  final SessionSettings sessionSettings;
  final NetworkConnectionHistory networkHistory;
  final Duration reconnectDelay;

  RadioLink? link;
  String? deviceLabel;
  bool deviceConnected = false;
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
          sessionSettings.intentionallyOff ||
          _connectCancelled ||
          !deviceConnected ||
          _reconnectTimer != null) {
        return;
      }
      metrics.disconnected(unexpected: true);
      deviceConnectedAt = null;
      host.log('Device link dropped; scheduling reconnect');
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
    if (sessionSettings.intentionallyOff) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
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
        sessionSettings.intentionallyOff) {
      return;
    }
    reconnectAttempts++;
    try {
      host.log('Reconnecting device ...');
      await connectWithBackoff(curLink, onLog: host.log);
      if (!identical(curLink, link) ||
          _disconnecting ||
          sessionSettings.intentionallyOff ||
          curLink.currentState != LinkState.connected) {
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
      this.deviceInfo = deviceInfo;
      deviceConnectedAt = DateTime.now();
      reconnectSuccesses++;
      host.log('Device link reconnected');
      host.notify();
    } catch (e) {
      host.log('Reconnect failed: $e');
      _scheduleReconnect();
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
    host.log('Device powered off; automatic reconnect suppressed');
    await offPersisted;
    await host.stopProxy();
    await host.stopForegroundService();
    host.resetNotificationState();
    host.notify();
  }

  Future<void> handlePoweredOff() => _runTransition(_onNodePoweredOff);

  Future<void> disconnect() => _runTransition(_disconnectDevice);

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
