import 'dart:async';
import 'dart:math' show min;

import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' show BluetoothDevice;

import 'device_capabilities.dart';
import 'device_link_phase.dart';
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

/// Creates the BLE link used to reach a Bluetooth companion.
typedef BleLinkFactory = RadioLink Function(
  BluetoothDevice device,
  void Function(String message) onLog,
);

/// Creates the timers used by reconnect and passive-recovery scheduling.
///
/// Tests inject a fake clock instead of sleeping on wall time.
typedef RecoveryTimerFactory = Timer Function(
  Duration duration,
  void Function() callback,
);

/// Capped retry delays for a parked TCP session.
const passiveTcpDelays = <Duration>[
  Duration(seconds: 30),
  Duration(minutes: 1),
  Duration(minutes: 2),
  Duration(minutes: 5),
  Duration(minutes: 10),
  Duration(minutes: 15),
];

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
    required this.bleLinkFactory,
    required this.capabilities,
    required this.metrics,
    required this.sessionSettings,
    required this.networkHistory,
    this.reconnectDelay = const Duration(seconds: 3),
    this.maxReconnectFailures = 3,
    this.timerFactory = Timer.new,
  });

  final ConnectionHost host;
  final TcpDeviceLinkFactory tcpLinkFactory;
  final BleLinkFactory bleLinkFactory;
  final DeviceCapabilities capabilities;
  final LinkMetrics metrics;
  final SessionSettings sessionSettings;
  final NetworkConnectionHistory networkHistory;
  final Duration reconnectDelay;

  /// Consecutive failed reconnect cycles tolerated before the session parks.
  ///
  /// A dropped radio is retried so a brief out-of-range period can recover. If
  /// the link cannot be restored, the proxy stops so the MeshCore client sees
  /// the disconnect, but the foreground service keeps waiting for the companion.
  final int maxReconnectFailures;

  final RecoveryTimerFactory timerFactory;

  RadioLink? link;
  String? deviceLabel;
  DeviceInfo? deviceInfo;
  DateTime? deviceConnectedAt;
  int reconnectAttempts = 0;
  int reconnectSuccesses = 0;

  DeviceLinkPhase _phase = DeviceLinkPhase.idle;

  DeviceLinkPhase get devicePhase => _phase;
  bool get deviceConnected => _phase == DeviceLinkPhase.connected;
  bool get deviceReconnecting => _phase == DeviceLinkPhase.reconnecting;
  bool get deviceWaiting => _phase == DeviceLinkPhase.waiting;
  bool get deviceConnecting => _phase == DeviceLinkPhase.connecting;

  int passiveAttempts = 0;
  int passiveSuccesses = 0;

  bool get recoveryPending => _recoveryPending;
  Duration? get nextPassiveDelay => _scheduledPassiveDelay;

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

  // Passive-recovery state.
  RadioLink? _passiveLink;
  Timer? _passiveTimer;
  Duration? _scheduledPassiveDelay;
  SessionConfig? _parkedTarget;
  String? _parkedLabel;
  bool _proxyWasRunning = false;
  bool _recoveryPending = false;
  bool _recovering = false;
  bool _restoring = false;
  bool _passiveArmed = false;
  int _recoveryGeneration = 0;
  int _nextPassiveDelayIndex = 0;

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

  Future<bool> connectTcp({required String host, int? tcpPort}) {
    _preemptActiveAttempt();
    return _runTransition(() => _connectTcp(host: host, tcpPort: tcpPort));
  }

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

  Future<bool> connectBle(BluetoothDevice device, {String? displayName}) {
    _preemptActiveAttempt();
    return _runTransition(() => _connectBle(device, displayName: displayName));
  }

  Future<bool> _connectBle(
    BluetoothDevice device, {
    String? displayName,
  }) async {
    if (!capabilities.supportsBle) {
      host.log('BLE is not available in this build');
      return false;
    }
    final raw = bleLinkFactory(device, host.log);
    final link = MeteredRadioLink(raw, metrics: metrics);
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
    if (!ok) {
      _passiveLink = null;
      return false;
    }
    _passiveLink = raw is PassiveConnectLink ? raw : null;
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
  Future<bool> connectSimulated({RadioLink? simulatedLink}) {
    _preemptActiveAttempt();
    return _runTransition(
        () => _connectSimulated(simulatedLink: simulatedLink));
  }

  Future<bool> _connectSimulated({RadioLink? simulatedLink}) async {
    _passiveLink = null;
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
      !_connectCancelled &&
      !_disconnectRequested &&
      link.currentState == LinkState.connected;

  Future<bool> _attachLink(RadioLink link, String label) async {
    host.busy = true;
    _connectCancelled = false;
    host.notify();
    try {
      await _disconnectDevice();
      if (_connectCancelled || _disconnectRequested) return false;
      final manager = await host.ensureManager();
      if (!manager.loaded) {
        host.log(manager.databaseError ?? 'Identity database unavailable');
        return false;
      }
      _connectingLink = link;
      _phase = DeviceLinkPhase.connecting;
      deviceLabel = label;
      // Start the service before the physical attempt so backgrounding the app
      // mid-connect cannot suspend it.
      await host.startForegroundService();
      await host.updateNotification();
      host.log('Connecting to $label ...');
      await connectWithBackoff(
        link,
        onLog: host.log,
        shouldCancel: () => _connectCancelled || _disconnectRequested,
      );
      if (!_linkReadyForAttach(link)) {
        await _disconnectDevice();
        return false;
      }
      this.link = link;
      final started = await _startLiveRuntimes(
        link,
        isCancelled: () => !_linkReadyForAttach(link),
      );
      if (!started || !_linkReadyForAttach(link)) {
        await _disconnectDevice();
        return false;
      }
      _phase = DeviceLinkPhase.connected;
      _reconnectFailures = 0;
      _recoveryPending = false;
      _proxyWasRunning = false;
      _parkedTarget = null;
      _parkedLabel = null;
      _nextPassiveDelayIndex = 0;
      await sessionSettings.clearRecoveryPending();
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
      await host.updateNotification();
      if (!_linkReadyForAttach(link)) {
        await _disconnectDevice();
        return false;
      }
      return true;
    } catch (e) {
      if (!_connectCancelled) host.log('Device connection failed: $e');
      // Also stops the foreground service and resets the phase when the
      // failure happened before this.link was assigned.
      await _disconnectDevice();
      return false;
    } finally {
      _connectingLink = null;
      _connectCancelled = false;
      host.busy = false;
      host.notify();
    }
  }

  /// Read the device snapshot and bring every identity runtime live.
  ///
  /// Shared by the initial attach and passive recovery so their ordering stays
  /// the same: physical snapshot first, then [IdentityManager.startLive].
  Future<bool> _startLiveRuntimes(
    RadioLink link, {
    bool Function()? isCancelled,
  }) async {
    final manager = await host.ensureManager();
    if (!manager.loaded) {
      host.log(manager.databaseError ?? 'Identity database unavailable');
      return false;
    }
    final deviceInfo = await link.deviceInfo();
    final selfInfo = await link.selfInfo();
    if (isCancelled?.call() ?? false) return false;
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
    if (isCancelled?.call() ?? false) return false;
    this.deviceInfo = deviceInfo;
    deviceConnectedAt = DateTime.now();
    return true;
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
      if (await _attachSavedSession(session)) {
        await host.startProxy(serverPort: session.proxyPort);
      }
    } catch (e) {
      host.log('Session resume failed: $e');
    }
  }

  /// Resume a session that was parked by an earlier process.
  ///
  /// This runs even when Resume on launch is off: it represents a recovery that
  /// had already started, not a cold-start preference. A failed cold-start
  /// [resumeSession] returns to idle; this path parks and waits instead.
  Future<void> recoverPendingSession() async {
    final session = sessionSettings.lastSession;
    if (session == null || !host.identityCatalogReady || deviceConnected) {
      return;
    }
    if (session.intentionallyOff) {
      await sessionSettings.clearRecoveryPending();
      return;
    }
    final serveProxy = sessionSettings.recoveryServeProxy;
    _proxyWasRunning = serveProxy;
    _recoveryPending = true;
    _recovering = true;
    host.log('Recovering a dropped device session ...');
    try {
      if (await _attachSavedSession(session)) {
        _recoveryPending = false;
        _proxyWasRunning = false;
        await sessionSettings.clearRecoveryPending();
        if (serveProxy) {
          await host.startProxy(serverPort: session.proxyPort);
        }
        return;
      }
    } catch (e) {
      host.log('Session recovery failed: $e');
    } finally {
      // Keep the persisted intent through the attach itself: a process death
      // before the attach settles must still re-arm on the next launch.
      _recovering = false;
    }
    if (deviceConnected || _phase == DeviceLinkPhase.waiting) return;
    // A failed attach tears the session down; restore the persisted intent
    // before parking so the proxy is still restarted when the link returns.
    _proxyWasRunning = serveProxy;
    _recoveryPending = true;
    await _runTransition(_parkSession);
  }

  Future<bool> _attachSavedSession(SessionConfig session) async {
    switch (session.kind) {
      case DeviceTargetKind.tcp:
        final hostName = session.host;
        if (hostName == null) return false;
        return connectTcp(host: hostName, tcpPort: session.devicePort);
      case DeviceTargetKind.ble:
        if (!capabilities.supportsBle) {
          host.log('Saved session used BLE, which this build does not support');
          return false;
        }
        final remoteId = session.bleRemoteId;
        if (remoteId == null) return false;
        return connectBle(
          BluetoothDevice.fromId(remoteId),
          displayName: session.bleName,
        );
      case DeviceTargetKind.simulated:
        return connectSimulated();
    }
  }

  /// Cancel an initial connect, an active reconnect, or a passive wait.
  ///
  /// Idempotent: an idle controller is untouched.
  Future<void> cancelDeviceAttempt() async {
    if (_phase == DeviceLinkPhase.idle) return;
    final wasConnecting = _phase == DeviceLinkPhase.connecting;
    _cancelActiveWork();
    _disconnectRequested = true;
    final cleanup = _runTransition(_disconnectDevice);
    // An initial attach can be inside an uncancelable handshake. Mark the
    // attempt canceled and let it unwind; waiting here would leave the UI
    // stuck on a Cancel that appears to do nothing.
    if (wasConnecting) {
      unawaited(cleanup);
      return;
    }
    await cleanup;
  }

  /// Kept for callers that only model an initial attach.
  Future<void> cancelPendingConnection() => cancelDeviceAttempt();

  /// Stop an in-flight attempt before a new connect is queued.
  ///
  /// Without this, the serialized transition queue would make the new request
  /// wait for the old attempt to finish on its own.
  void _preemptActiveAttempt() {
    if (_phase != DeviceLinkPhase.connecting &&
        _phase != DeviceLinkPhase.reconnecting &&
        _phase != DeviceLinkPhase.waiting) {
      return;
    }
    _cancelActiveWork();
  }

  void _cancelActiveWork() {
    _connectCancelled = true;
    _recovering = false;
    _recoveryGeneration++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _passiveTimer?.cancel();
    _passiveTimer = null;
    _scheduledPassiveDelay = null;
    _passiveArmed = false;
    final pending = _connectingLink;
    if (pending != null) unawaited(_cancelRawLink(pending));
    final passive = _passiveLink;
    if (passive != null) unawaited(_cancelRawLink(passive));
    // An active reconnect owns the link rather than _connectingLink; closing it
    // here lets BLE abort the in-flight connect instead of waiting for it.
    final active = link;
    if (active != null) unawaited(_cancelRawLink(active));
  }

  Future<void> _cancelRawLink(RadioLink link) async {
    try {
      final cancelable =
          link is CancelableConnect ? link as CancelableConnect : null;
      if (cancelable != null) {
        await cancelable.cancelInFlightConnect();
      } else {
        await link.disconnect();
      }
    } catch (e) {
      host.log('Connection cancellation failed: $e');
    }
  }

  /// Watch [link] for unexpected drops and passive restores.
  void _watchLink(RadioLink link) {
    _linkStateSub?.cancel();
    void handle(LinkState state) {
      if (state == LinkState.connected) {
        if (_phase == DeviceLinkPhase.waiting && !_restoring) {
          // Capture the generation at event time: a cancel that lands before
          // the queued transition runs must invalidate this restore.
          final generation = _recoveryGeneration;
          unawaited(_runTransition(() => _restoreFromPassive(generation)));
        }
        return;
      }
      if (state != LinkState.disconnected ||
          _disconnecting ||
          _disconnectRequested ||
          sessionSettings.intentionallyOff ||
          _connectCancelled) {
        return;
      }
      if (_phase == DeviceLinkPhase.waiting) {
        // A passive BLE handshake failed after the request was armed: re-arm on
        // the capped schedule instead of leaving a half-connected link.
        if (_passiveArmed) {
          _passiveArmed = false;
          _schedulePassiveAttempt(_recoveryGeneration);
        }
        return;
      }
      if (_phase != DeviceLinkPhase.connected ||
          _reconnecting ||
          _reconnectTimer != null) {
        return;
      }
      metrics.disconnected(unexpected: true);
      deviceConnectedAt = null;
      _phase = DeviceLinkPhase.reconnecting;
      host.log('Device link dropped; scheduling reconnect');
      unawaited(host.updateNotification());
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
    _reconnectTimer = timerFactory(reconnectDelay, () {
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
        _phase != DeviceLinkPhase.reconnecting ||
        _disconnecting ||
        _disconnectRequested ||
        sessionSettings.intentionallyOff) {
      return;
    }
    bool cancelled() =>
        _disconnectRequested ||
        _disconnecting ||
        sessionSettings.intentionallyOff ||
        !identical(curLink, link) ||
        _phase != DeviceLinkPhase.reconnecting;
    _reconnecting = true;
    reconnectAttempts++;
    try {
      host.log('Reconnecting device ...');
      await connectWithBackoff(
        curLink,
        onLog: host.log,
        shouldCancel: cancelled,
      );
      if (cancelled() || curLink.currentState != LinkState.connected) return;
      await _reapplyPhysical(curLink, manager);
      if (cancelled() || curLink.currentState != LinkState.connected) return;
      _reconnectFailures = 0;
      _phase = DeviceLinkPhase.connected;
      reconnectSuccesses++;
      host.log('Device link reconnected');
      await host.updateNotification();
      host.notify();
    } catch (e) {
      if (cancelled()) return;
      _reconnectFailures++;
      host.log('Reconnect failed: $e');
      if (_reconnectFailures >= maxReconnectFailures) {
        await _parkSession();
      } else {
        _scheduleReconnect();
      }
    } finally {
      _reconnecting = false;
    }
  }

  Future<void> _reapplyPhysical(
    RadioLink curLink,
    IdentityManager manager,
  ) async {
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
  }

  /// Stop serving the client but keep waiting for the physical companion.
  ///
  /// The proxy stops so the client sees the disconnect, the runtimes stop
  /// because there is no radio, but the foreground service and saved target stay
  /// alive so recovery can happen later.
  Future<void> _parkSession() async {
    final target = sessionSettings.lastSession;
    if (target == null || target.kind == DeviceTargetKind.simulated) {
      // There is no physical link to wait for. End the simulated session.
      host.log(
        'Device link lost after $_reconnectFailures failed reconnect cycles; '
        'stopping the session',
      );
      await _disconnectDevice();
      return;
    }
    if ((target.kind == DeviceTargetKind.ble &&
            (!capabilities.supportsBle || target.bleRemoteId == null)) ||
        (target.kind == DeviceTargetKind.tcp && target.host == null)) {
      // The saved target cannot be reached on this build; waiting would create
      // a link with no usable transport.
      host.log('Cannot wait for the saved companion on this build');
      await _disconnectDevice();
      return;
    }
    final generation = ++_recoveryGeneration;
    _phase = DeviceLinkPhase.waiting;
    _recoveryPending = true;
    _proxyWasRunning = _proxyWasRunning || host.proxyRunning;
    _parkedTarget = target;
    // A failed cold-start recovery has no live label; derive one from the
    // persisted target so the waiting UI still names what it is waiting for.
    _parkedLabel = deviceLabel ?? _labelForSession(target);
    deviceLabel = _parkedLabel;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _passiveArmed = false;
    host.log(
      'Device link lost after $_reconnectFailures failed reconnect cycles; '
      'waiting for the companion',
    );

    // Persist intent early so a process death during teardown still recovers.
    await sessionSettings.markRecoveryPending(serveProxy: _proxyWasRunning);

    if (host.proxyRunning) await host.stopProxy();
    await host.manager?.stopLive();
    metrics.disconnected();
    deviceConnectedAt = null;
    deviceInfo = null;
    _reconnectFailures = 0;

    try {
      await link?.disconnect();
    } catch (e) {
      host.log('Could not close the lost link cleanly: $e');
    }

    // A cold-start recovery can fail before any transport was attached; create
    // one now so the parked session has a link to restore later.
    if (link == null) {
      final raw = _createParkedLink(target);
      if (raw != null) {
        link = MeteredRadioLink(raw, metrics: metrics);
        _passiveLink = raw is PassiveConnectLink ? raw : null;
      }
    }

    // A cold-start park creates a new link after the old subscription was torn
    // down. Watch it so a passive BLE connection can trigger the restore.
    final current = link;
    if (current != null) _watchLink(current);

    await host.startForegroundService();
    await host.updateNotification();
    host.notify();
    await _armPassiveRecovery(generation);
  }

  String _labelForSession(SessionConfig target) => switch (target.kind) {
        DeviceTargetKind.tcp =>
          'TCP ${formatNetworkAddress(target.host ?? '', target.devicePort)}',
        DeviceTargetKind.ble =>
          'BLE ${target.bleName ?? target.bleRemoteId ?? 'companion'}',
        DeviceTargetKind.simulated => 'Simulated companion',
      };

  RadioLink? _createParkedLink(SessionConfig target) {
    switch (target.kind) {
      case DeviceTargetKind.tcp:
        final hostName = target.host;
        if (hostName == null) return null;
        return tcpLinkFactory(hostName, target.devicePort, host.log);
      case DeviceTargetKind.ble:
        final remoteId = target.bleRemoteId;
        if (remoteId == null) return null;
        return bleLinkFactory(BluetoothDevice.fromId(remoteId), host.log);
      case DeviceTargetKind.simulated:
        return null;
    }
  }

  Future<void> _armPassiveRecovery(int generation) async {
    if (generation != _recoveryGeneration ||
        _phase != DeviceLinkPhase.waiting) {
      return;
    }
    final target = _parkedTarget;
    if (link == null || target == null) {
      await _disconnectDevice();
      return;
    }
    if (target.kind == DeviceTargetKind.tcp) {
      _schedulePassiveAttempt(generation);
      return;
    }
    if (target.kind != DeviceTargetKind.ble) {
      await _disconnectDevice();
      return;
    }
    final passive = _passiveLink;
    if (passive == null || passive is! PassiveConnectLink) {
      host.log('This build cannot wait passively for the BLE companion');
      await _disconnectDevice();
      return;
    }
    final passiveConnect = passive as PassiveConnectLink;
    try {
      await passiveConnect.startPassiveConnect();
      if (generation != _recoveryGeneration ||
          _phase != DeviceLinkPhase.waiting) {
        return;
      }
      _passiveArmed = true;
      passiveAttempts++;
      metrics.connectionAttempt();
      host.log('Waiting for ${_parkedLabel ?? 'BLE companion'} to return');
    } catch (e) {
      host.log('Could not arm passive BLE reconnect: $e');
      if (generation == _recoveryGeneration) {
        _schedulePassiveAttempt(generation);
      }
    }
  }

  void _schedulePassiveAttempt(int generation) {
    if (generation != _recoveryGeneration ||
        _phase != DeviceLinkPhase.waiting) {
      return;
    }
    final index = _nextPassiveDelayIndex.clamp(0, passiveTcpDelays.length - 1);
    final delay = passiveTcpDelays[index];
    _nextPassiveDelayIndex =
        min(_nextPassiveDelayIndex + 1, passiveTcpDelays.length - 1);
    _passiveTimer?.cancel();
    _scheduledPassiveDelay = delay;
    _passiveTimer = timerFactory(delay, () {
      _passiveTimer = null;
      _scheduledPassiveDelay = null;
      unawaited(_runTransition(() => _runPassiveAttempt(generation)));
    });
    final target = _parkedTarget;
    if (target?.kind == DeviceTargetKind.tcp) {
      final hostName = target?.host ?? '';
      host.log(
        'Waiting for TCP ${formatNetworkAddress(hostName, target!.devicePort)}; '
        'next attempt in ${_formatDelay(delay)}',
      );
    }
  }

  Future<void> _runPassiveAttempt(int generation) async {
    if (generation != _recoveryGeneration ||
        _phase != DeviceLinkPhase.waiting) {
      return;
    }
    final target = _parkedTarget;
    final curLink = link;
    if (target == null || curLink == null) {
      await _disconnectDevice();
      return;
    }
    if (target.kind == DeviceTargetKind.ble) {
      await _armPassiveRecovery(generation);
      return;
    }
    if (target.kind != DeviceTargetKind.tcp) {
      await _disconnectDevice();
      return;
    }
    // A foreground nudge can queue behind an attempt that is already running.
    if (curLink.currentState == LinkState.connecting) return;
    bool cancelled() =>
        generation != _recoveryGeneration ||
        _phase != DeviceLinkPhase.waiting ||
        _disconnectRequested;
    passiveAttempts++;
    try {
      final hostName = target.host ?? '';
      host.log(
        'Waiting for TCP ${formatNetworkAddress(hostName, target.devicePort)}; '
        'connecting ...',
      );
      await connectWithBackoff(
        curLink,
        maxAttempts: 1,
        onLog: host.log,
        shouldCancel: cancelled,
      );
      if (cancelled()) return;
      if (curLink.currentState != LinkState.connected) {
        throw StateError('TCP companion did not connect');
      }
      await _restoreFromPassive(generation);
    } catch (e) {
      if (cancelled()) return;
      if (passiveAttempts == 1 || passiveAttempts % 10 == 0) {
        host.log('Passive reconnect failed: $e');
      }
      try {
        await curLink.disconnect();
      } catch (_) {}
      _schedulePassiveAttempt(generation);
    }
  }

  Future<void> _restoreFromPassive(int generation) async {
    if (generation != _recoveryGeneration ||
        _phase != DeviceLinkPhase.waiting ||
        _restoring) {
      return;
    }
    _restoring = true;
    _passiveTimer?.cancel();
    _passiveTimer = null;
    _scheduledPassiveDelay = null;
    _passiveArmed = false;
    try {
      final curLink = link;
      if (curLink == null) return;
      final started = await _startLiveRuntimes(
        curLink,
        isCancelled: () =>
            generation != _recoveryGeneration ||
            _phase != DeviceLinkPhase.waiting,
      );
      if (!started) throw StateError('could not start live identities');
      if (generation != _recoveryGeneration) return;
      // A BLE passive connect runs on the raw link, so the metered wrapper never
      // saw the successful connect. TCP attempts are already counted by it.
      if (_parkedTarget?.kind == DeviceTargetKind.ble) {
        metrics.connectionSucceeded();
      }

      // Already running while waiting; refreshes the notification copy.
      await host.startForegroundService();
      final serveProxy = _proxyWasRunning;
      if (serveProxy) {
        await host.startProxy(serverPort: sessionSettings.port);
      }
      if (generation != _recoveryGeneration) return;

      _phase = DeviceLinkPhase.connected;
      _reconnectFailures = 0;
      passiveSuccesses++;
      _nextPassiveDelayIndex = 0;
      _recoveryPending = false;
      _proxyWasRunning = false;
      _parkedTarget = null;
      _parkedLabel = null;
      await sessionSettings.clearRecoveryPending();
      await host.updateNotification();
      host.log(serveProxy
          ? 'Companion recovered; proxy listening on port '
              '${sessionSettings.port}'
          : 'Companion recovered; proxy remains stopped');
      host.notify();
    } catch (e) {
      host.log('Companion recovery failed: $e');
      if (generation != _recoveryGeneration) return;
      try {
        await link?.disconnect();
      } catch (_) {}
      _phase = DeviceLinkPhase.waiting;
      deviceConnectedAt = null;
      await host.updateNotification();
      await _armPassiveRecovery(generation);
    } finally {
      _restoring = false;
    }
  }

  /// Retry the parked companion when the app returns to the foreground.
  ///
  /// For TCP this runs an immediate attempt instead of waiting for the next cap;
  /// for BLE the OS request is re-armed idempotently.
  Future<void> rearmAfterLinkLoss() async {
    if (_phase != DeviceLinkPhase.waiting ||
        _rearming ||
        host.busy ||
        _disconnecting) {
      return;
    }
    _rearming = true;
    try {
      _passiveTimer?.cancel();
      _passiveTimer = null;
      _scheduledPassiveDelay = null;
      final generation = _recoveryGeneration;
      await _runTransition(() async {
        if (_parkedTarget?.kind == DeviceTargetKind.tcp) {
          await _runPassiveAttempt(generation);
        } else {
          await _armPassiveRecovery(generation);
        }
      });
    } finally {
      _rearming = false;
    }
  }

  Future<void> _onNodePoweredOff() async {
    await sessionSettings.markPoweredOff();
    _cancelActiveWork();
    metrics.disconnected();
    deviceInfo = null;
    deviceLabel = null;
    _reconnectFailures = 0;
    host.log('Device powered off; automatic reconnect suppressed');
    await _disconnectDevice();
  }

  Future<void> handlePoweredOff() => _runTransition(_onNodePoweredOff);

  Future<void> disconnect() {
    // Drop a queued or in-flight reconnect immediately: tapping Disconnect must
    // not wait for a link retry to fail first.
    _disconnectRequested = true;
    _connectCancelled = true;
    _recovering = false;
    _recoveryGeneration++;
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
    _phase = DeviceLinkPhase.disconnecting;
    _recoveryGeneration++;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _stopPassiveRecovery();
    await _linkStateSub?.cancel();
    _linkStateSub = null;
    final pending = _connectingLink;
    _connectingLink = null;
    if (pending != null) {
      await _cancelRawLink(pending);
    }
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
      deviceConnectedAt = null;
      deviceInfo = null;
      deviceLabel = null;
      _reconnectFailures = 0;
      _disconnectRequested = false;
      _phase = DeviceLinkPhase.idle;
      _parkedTarget = null;
      _parkedLabel = null;
      _proxyWasRunning = false;
      _recoveryPending = false;
      _nextPassiveDelayIndex = 0;
      // A cold-start recovery clears its own intent once the attach settles;
      // tearing down mid-attach must leave the flag so a process death during
      // the attempt still recovers on the next launch.
      if (!_recovering) await sessionSettings.clearRecoveryPending();
      await host.stopForegroundService();
      host.resetNotificationState();
      _disconnecting = false;
      if (!wasBusy) host.busy = false;
      host.notify();
    }
  }

  void _stopPassiveRecovery() {
    final wasArmed = _passiveArmed;
    _passiveTimer?.cancel();
    _passiveTimer = null;
    _scheduledPassiveDelay = null;
    _passiveArmed = false;
    final passive = _passiveLink;
    _passiveLink = null;
    if (wasArmed && passive is PassiveConnectLink) {
      final passiveConnect = passive as PassiveConnectLink;
      unawaited(passiveConnect.stopPassiveConnect().catchError((Object e) {
        host.log('Could not stop passive recovery: $e');
      }));
    }
  }

  static String _formatDelay(Duration delay) =>
      delay.inMinutes >= 1 ? '${delay.inMinutes}m' : '${delay.inSeconds}s';

  void dispose() {
    _reconnectTimer?.cancel();
    _passiveTimer?.cancel();
    final passive = _passiveLink;
    if (passive is PassiveConnectLink) {
      final passiveConnect = passive as PassiveConnectLink;
      unawaited(passiveConnect.stopPassiveConnect().catchError((Object _) {}));
    }
    unawaited(_linkStateSub?.cancel());
    unawaited(link?.disconnect());
  }
}
