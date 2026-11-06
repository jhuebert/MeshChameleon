import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'ack_tracker.dart';
import 'advert_path_cache.dart';
import 'battery_service.dart';
import 'cli_runtime.dart';
import 'connection_sessions.dart';
import 'contact_table.dart';
import 'flood_scope.dart';
import 'identity_persistence.dart';
import 'local_peer_router.dart';
import 'mesh_errors.dart';
import 'message_queue.dart';
import 'message_sender.dart';
import 'mesh_rx.dart';
import 'node_store.dart';
import 'packet_deduper.dart';
import 'packet_transport.dart';
import 'physical_radio.dart';
import 'request_tracker.dart';
import 'reset.dart';
import 'runtime_guard.dart';
import 'scheduler.dart';
import 'sensor_settings.dart';
import 'serial_queue.dart';
import 'state_persistence.dart';
import 'virtual_clock.dart';

/// Maximum number of inbound messages held for the client. When the queue is
/// full, the oldest channel message is dropped to make room; if there is none,
/// the new message is dropped. Matches stock firmware's `OFFLINE_QUEUE_SIZE`.
const int defaultOfflineQueueSize = 16;

/// The reimplemented MeshCore companion node.
///
/// Implements the app-facing [CompanionBridge] surface, owns the proxy identity
/// and runtime lifecycle, and uses a [RadioLink] purely as a raw radio:
/// outbound packets go through `sendRawPacket`, and every received frame
/// arrives via the raw RX listener. Domain state is owned by the collaborators
/// constructed below (radio, CLI, contacts, queue, requests, ACKs, sessions,
/// transport, RX router, messaging, and persistence).
class MeshNode extends CompanionBridge implements CliHost {
  MeshNode({
    required this.identity,
    required this.link,
    NodePrefs? prefs,
    PhysicalCapabilities physical = const PhysicalCapabilities(),
    this.store,
    this.ackTimeout = const Duration(seconds: 10),
    int maxQueueSize = defaultOfflineQueueSize,
    this.storageQuotaBytes = virtualStorageQuotaBytes,
    this.sensorSettings = const EmptyVirtualSensorSettingsProvider(),
    this.scheduler = const TimerMeshScheduler(),
    this.identityPersistence,
    this.onIdentityChanged,
    this.onPoweredOff,
    this.localRouter,
    this.attachedDevicePublicKey,
    this.onStateChanged,
    this.onPhysicalConfigChanged,
    VirtualClock? clock,
  })  : prefs = prefs ?? NodePrefs(),
        clock = clock ?? VirtualClock() {
    _channels[0] = defaultPublicChannel();
    _customVars.addAll(sensorSettings.initialSettings);
    _startedAtMonotonicMillis = this.clock.monotonicMilliseconds;
    battery = BatteryService(
      readVoltage: () async {
        final reading = await link.battery();
        // Only the approved voltage measurement escapes this boundary.
        return reading?.millivolts;
      },
      clock: this.clock,
      scheduler: scheduler,
    );
    _floodScope = FloodScope();
    _contactTable = ContactTable(clock: this.clock);
    _messageQueue = MessageQueue(maxQueueSize: maxQueueSize);
    _advertPathCache = AdvertPathCache();
    _requests = RequestTracker(clock: this.clock);
    _deduper = PacketDeduper(clock: this.clock);
    _acks = AckTracker(
      scheduler: scheduler,
      clock: this.clock,
      generation: () => _guard.generation,
      isCurrent: _identityCurrent,
      onConfirmed: (crc, tripTimeMs) =>
          pushSink?.pushSendConfirmed(crc, tripTimeMs: tripTimeMs),
    );
    _sessions = ConnectionSessions(
      clock: this.clock,
      onKeepAlive: _sendKeepAlive,
    );
    _radio = PhysicalRadio(
      link: link,
      prefs: this.prefs,
      capabilities: physical,
      onPersist: _persist,
      onConfigChanged: _notifyPhysicalConfigChanged,
    );
    _cli = CliRuntime(prefs: this.prefs, radio: _radio, host: this);
    _transport = PacketTransport(
      link: link,
      prefs: this.prefs,
      clock: this.clock,
      localRouter: localRouter,
      guard: _guard,
      effectiveFloodScope: _effectiveFloodScope,
      publicKey: () => identity.publicKey,
    );
    _rx = MeshRx(MeshRxDeps(
      identity: () => identity,
      prefs: this.prefs,
      clock: this.clock,
      channels: channels,
      contacts: _contactTable,
      advertPaths: _advertPathCache,
      queue: _messageQueue,
      requests: _requests,
      deduper: _deduper,
      acks: _acks,
      sessions: _sessions,
      transport: _transport,
      battery: battery,
      cli: _cli,
      pushSink: () => pushSink,
      guard: _guard,
      commit: _commit,
      transmit: (
        Packet packet, {
        required bool flood,
        bool scoped = false,
        bool preservePath = false,
        int priority = 0,
        int? identityGeneration,
      }) =>
          _transmit(
        packet,
        flood: flood,
        scoped: scoped,
        preservePath: preservePath,
        priority: priority,
        identityGeneration: identityGeneration,
      ),
      enqueueMessage: _enqueueMessage,
      addUpdateContact: addUpdateContact,
      forgetContactState: _forgetContactState,
      persist: _persist,
    ));
    _state = StatePersistence(
      store: store,
      storageQuotaBytes: storageQuotaBytes,
      snapshot: _snapshot,
      publish: _publish,
      guard: _guard,
      onStateChanged: _notifyStateChanged,
    );
    _messages = MessageSender(MessageSenderDeps(
      identity: () => identity,
      prefs: this.prefs,
      clock: this.clock,
      channels: channels,
      contacts: _contactTable,
      requests: _requests,
      acks: _acks,
      transport: _transport,
      deduper: _deduper,
      ackTimeout: ackTimeout,
      guard: _guard,
      ensureNotBlockedPeer: _ensureNotBlockedPeer,
      transmit: (
        Packet packet, {
        required bool flood,
        bool scoped = false,
        bool preservePath = false,
        int priority = 0,
        int? identityGeneration,
      }) =>
          _transmit(
        packet,
        flood: flood,
        scoped: scoped,
        preservePath: preservePath,
        priority: priority,
        identityGeneration: identityGeneration,
      ),
    ));
  }

  /// Active virtual identity. Replace only through [replaceIdentity] so the
  /// persistence/generation lifecycle stays consistent.
  LocalIdentity identity;
  final RadioLink link;
  final NodePrefs prefs;

  /// Host persistence for identity replacement (secure app store or headless
  /// atomic file). Null means the caller owns persistence entirely.
  final VirtualIdentityPersistence? identityPersistence;

  /// Invoked after a successful identity switch. Must not log key material.
  final void Function(LocalIdentity identity)? onIdentityChanged;

  /// Invoked after a successful physical poweroff dispatch.
  final Future<void> Function()? onPoweredOff;

  /// In-process mirror to the other live virtual identities.
  final LocalPeerRouter? localRouter;

  /// The attached radio's own companion public key, when known. Unicasts to it
  /// are rejected even in single-identity/headless hosts that have no
  /// [localRouter].
  final Uint8List? attachedDevicePublicKey;

  /// Invoked after durable state publication/reset and queue drain. May be
  /// called often; hosts are expected to debounce UI notifications.
  final void Function()? onStateChanged;

  /// Invoked after a confirmed physical RF/tuning change or readback so the
  /// host can propagate the shared snapshot to the other identities.
  final void Function()? onPhysicalConfigChanged;

  /// Virtual wall/monotonic clock. Wall changes never touch the host clock or
  /// the radio RTC (the radio is used purely as a packet transport).
  final VirtualClock clock;

  late final FloodScope _floodScope;

  /// Attached physical radio configuration and cache.
  late final PhysicalRadio _radio;

  /// Companion CLI routing and reply formatting.
  late final CliRuntime _cli;

  /// Raw transmission, airtime accounting, and packet counters.
  late final PacketTransport _transport;

  /// Inbound packet router and protocol handlers.
  late final MeshRx _rx;

  /// Durable state commit/publish coordinator.
  late final StatePersistence _state;

  /// Outbound text, channel, raw, and request transmissions.
  late final MessageSender _messages;

  /// Sensor settings provider backing `GET/SET_CUSTOM_VAR`.
  final VirtualSensorSettingsProvider sensorSettings;

  /// Injectable scheduler for cancellable endpoint ACK delays.
  final MeshScheduler scheduler;

  /// Coalesced physical-battery samples with virtual-only storage reporting.
  late final BatteryService battery;

  /// Capabilities of the attached physical radio modem. Kept separate from the
  /// virtual [DeviceInfo] advertised to clients.
  PhysicalCapabilities get physical => _radio.capabilities;

  final Duration ackTimeout;

  /// Optional persistence backend. When set, [load] restores the last saved
  /// state and every mutation is written back with [NodeStore.save].
  final NodeStore? store;

  /// Maximum number of queued inbound messages; oldest are dropped on overflow.
  /// Maximum queued messages before the oldest is dropped.
  int get maxQueueSize => _messageQueue.maxQueueSize;

  /// Deterministic virtual storage quota for this node (4 MiB by default).
  final int storageQuotaBytes;

  late final ContactTable _contactTable;
  List<Contact> get contacts => _contactTable.contacts;

  final Map<int, Channel> _channels = {};
  Map<int, Channel> get channels => UnmodifiableMapView(_channels);

  late final MessageQueue _messageQueue;
  late final AdvertPathCache _advertPathCache;
  Map<String, AdvertPath> get _advertPaths => _advertPathCache.paths;

  /// Outbound request tags, timestamps, and pending request targets.
  late final RequestTracker _requests;

  /// Duplicate/echo suppression for the RX path.
  late final PacketDeduper _deduper;

  /// Endpoint ACK scheduling and pending-send confirmation.
  late final AckTracker _acks;

  /// Active login keep-alive sessions, keyed by server public key hex.
  late final ConnectionSessions _sessions;

  void _cancelAckSchedules() => _acks.cancelScheduled();

  /// Restore persisted state from [store], if one is configured. Call before
  /// [start] so the node comes up with the previously known contacts,
  /// channels, queue, and preferences.
  Future<void> load() async {
    final state = await store?.load();
    if (state == null) return;
    _applyState(state);
    // A persisted file may predate the current public-channel defaults or
    // contain provider settings that are no longer supported.
    _channels.putIfAbsent(0, defaultPublicChannel);
    final publicSecret = LocalIdentity.defaultPublicChannelSecret;
    final publicChannel = _channels[0];
    if (publicChannel != null &&
        bytesEqual(publicChannel.secret, publicSecret) &&
        publicChannel.name.toLowerCase() == 'public') {
      _channels[0] = defaultPublicChannel();
    }
    _customVars
      ..clear()
      ..addAll(sensorSettings.initialSettings);
    for (final entry in state.customSettings.entries) {
      if (!sensorSettings.supports(entry.key)) continue;
      final normalized = sensorSettings.normalize(entry.key, entry.value);
      if (normalized != null) _customVars[entry.key] = normalized;
    }
  }

  /// Serialises identity replacement requests.
  final _identityQueue = SerialQueue();

  final RuntimeGuard _guard = RuntimeGuard();
  String? _identityDiagnostic;
  int _lifecycleGeneration = 0;

  /// True after a successful local shutdown until an explicit node start.
  bool get poweredOff => _guard.poweredOff;

  /// True once this runtime has been retired by its owner. A retired node never
  /// transmits, receives, or persists again.
  bool get retired => _guard.retired;

  @override
  int get lifecycleGeneration => _lifecycleGeneration;

  /// Bumped only after a verified successful identity switch.
  int get identityGeneration => _guard.generation;

  /// True when identity storage is unreadable/uncertain and semantic work must
  /// pause until a successful reload/replacement.
  bool get identityPaused => _guard.paused;

  /// Last identity lifecycle diagnostic (never contains key material).
  String? get identityDiagnostic => _identityDiagnostic;

  Future<void> _waitForPhysicalTxIdle() => _transport.waitForIdle();

  /// A write/timeout left the physical radio cache uncertain; do not retry the
  /// write automatically. Reconcile with a settings read or reconnect.
  bool get radioCacheUncertain => _radio.cacheUncertain;

  /// The last confirmed radio cache came from a successful readback.
  bool get radioCacheVerified => _radio.cacheVerified;

  /// A physical CLI `set radio` saved firmware prefs; a reboot is required for
  /// the active radio to match the saved values.
  bool get physicalRadioRequiresReboot => _radio.requiresReboot;

  bool get tuningCacheVerified => _radio.tuningCacheVerified;

  /// Last physical-operation diagnostic (never contains secrets).
  String? get physicalDiagnostic => _radio.diagnostic;

  CompanionOperationError _operationError(DeviceCommandError e) =>
      operationError(e);

  /// Monotonic time of the last [start], used for the uptime stat.
  int _startedAtMonotonicMillis = 0;

  /// Attach the raw RX listener. Call once the device link is connected.
  void start() {
    if (_guard.retired) throw StateError('cannot start a retired mesh node');
    _guard.powerOn();
    _startedAtMonotonicMillis = clock.monotonicMilliseconds;
    link.setRawRxListener(_onRawFrame);
    battery.start();
  }

  void stop() {
    link.setRawRxListener(null);
    battery.stop();
    _cancelTransientSessions();
  }

  void _cancelTransientSessions() {
    _cancelAckSchedules();
    _acks.clearPending();
    _sessions.clear();
  }

  /// Permanently stop semantic work for a runtime that is being replaced or
  /// deleted. Files are left intact for the owner to remove, but a late packet
  /// can no longer save or recreate state after this completes.
  Future<void> retire() async {
    if (_guard.retired) return;
    _guard.retire();
    stop();
    await _waitForPhysicalTxIdle();
    try {
      await _radio.idle;
      await _identityQueue.idle;
      await _state.idle;
      await store?.flush();
    } catch (_) {
      // Failures were already reported through their save futures.
    }
  }

  // -------------------------------------------------------------------------
  // Lifecycle and connections
  // -------------------------------------------------------------------------

  @override
  Future<void> reboot() async {
    // Dispatch first: a failure before the write must be reported, not hidden
    // behind a successful virtual cleanup.
    try {
      await link.reboot();
    } on DeviceCommandError catch (e) {
      _radio.setDiagnostic(e.message ?? e.toString());
      throw _operationError(e);
    } catch (_) {
      throw const CompanionOperationError(
        errCodeBadState,
        message: 'reboot dispatch failed',
      );
    }

    _radio.markRebooted();
    // A soft restart of the node engine: drop ephemeral runtime state while
    // keeping persisted prefs, contacts, channels and the queued messages.
    _clearIdentityRuntimeState();
    _lifecycleGeneration++;
  }

  /// Dispatch the physical `poweroff` CLI without waiting for a reply, then
  /// stop semantic TX/RX until an explicit start/new connection.
  @override
  Future<void> shutdown() async {
    if (_guard.poweredOff) return;
    if (physical.firmwareVerCode < 14) {
      throw const CompanionOperationError(
        errCodeUnsupportedCmd,
        message: 'physical firmware does not support shutdown',
      );
    }
    _guard.powerOff();
    try {
      await link.shutdown();
    } on DeviceCommandError catch (e) {
      _guard.powerOn();
      _radio.setDiagnostic(e.message ?? e.toString());
      throw _operationError(e);
    } catch (_) {
      _guard.powerOn();
      throw const CompanionOperationError(
        errCodeBadState,
        message: 'shutdown dispatch failed',
      );
    }

    _radio.markRebooted();
    _clearIdentityRuntimeState();
    _lifecycleGeneration++;
    battery.stop();
    link.setRawRxListener(null);
    try {
      await onPoweredOff?.call();
    } catch (_) {
      _radio.setDiagnostic('poweroff state notification failed');
    }
  }

  void _stopKeepAlive(Uint8List pubkey) {
    _sessions.stop(pubkey);
  }

  /// Diagnostic/test hook: send a keep-alive request now for every active
  /// connection without waiting for the interval timer.
  Future<void> sendKeepAlivesNow() => _sessions.sendAllNow();

  Future<void> _sendKeepAlive(ConnectionSession conn) async {
    // A queued timer callback from the previous identity must not transmit or
    // recreate a session after an identity switch.
    if (_semanticBlocked || !_sessions.containsValue(conn)) return;
    final generation = _guard.generation;
    final now = clock.monotonicSeconds;
    final expire = conn.lastActivity + (conn.interval.inSeconds * 5 ~/ 2);
    if (now >= expire) {
      _sessions.remove(conn);
      conn.stop();
      return;
    }
    final contact = getContactByKey(conn.pubkey);
    if (contact == null) {
      _sessions.remove(conn);
      conn.stop();
      return;
    }
    // Keep-alive is only usable once we know the direct path to the server.
    if (!contact.hasDirectRoute) return;

    final syncSince = contact.syncSince;
    final timestamp = _requests.nextTag();
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeKeepAlive,
      data: (BufferWriter()..writeUInt32Le(syncSince)).toBytes(),
      timestamp: timestamp,
      flood: false,
    );
    if (!_identityCurrent(generation) || !_sessions.containsValue(conn)) {
      return;
    }
    final digest = CryptoUtils.sha256([
      ...(BufferWriter()
            ..writeUInt32Le(timestamp)
            ..writeByte(reqTypeKeepAlive)
            ..writeUInt32Le(syncSince))
          .toBytes(),
      ...identity.publicKey,
    ]);
    conn.expectedAck =
        digest[0] | (digest[1] << 8) | (digest[2] << 16) | (digest[3] << 24);
    await _transmit(packet, flood: false);
  }

  // -------------------------------------------------------------------------
  // CompanionBridge: identity / info
  // -------------------------------------------------------------------------

  @override
  Uint8List getPublicKey() => identity.publicKey;

  bool _sameIdentity(LocalIdentity a, LocalIdentity b) =>
      bytesEqual(a.meshcore64, b.meshcore64);

  bool get _identityBlocked => _guard.identityBlocked;

  bool get _semanticBlocked => _guard.blocked;

  bool _identityCurrent(int generation) => _guard.isCurrent(generation);

  void _requireIdentityReady() {
    if (_identityBlocked) {
      throw const CompanionOperationError(
        errCodeBadState,
        message: 'identity storage recovery required',
      );
    }
  }

  /// Validate, persist, then atomically switch the active virtual identity.
  ///
  /// Server command handling and app identity actions share this path. State
  /// contacts/channels/prefs/queue/advert paths are retained; identity-derived
  /// runtime state and in-flight work are cleared.
  Future<void> replaceIdentity(LocalIdentity candidate) =>
      _identityQueue.run(() => _replaceIdentityLocked(candidate));

  Future<void> _replaceIdentityLocked(LocalIdentity candidate) async {
    final candidateKey = candidate.meshcore64;
    if (!await LocalIdentity.validateMeshcore64(candidateKey)) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid identity key',
      );
    }

    _guard.beginSwap();
    try {
      await _waitForPhysicalTxIdle();

      String? saveDiagnostic;
      final backend = identityPersistence;
      if (backend != null) {
        try {
          await backend.save(candidate);
        } on CompanionOperationError {
          // Host validation (duplicate/attached-device key) is an operation
          // error, not an uncertain storage failure.
          rethrow;
        } catch (_) {
          LocalIdentity? readBack;
          try {
            readBack = await backend.load();
          } catch (_) {
            readBack = null;
          }
          if (readBack != null && _sameIdentity(readBack, candidate)) {
            saveDiagnostic =
                'identity backend reported an error after committing';
          } else if (readBack != null && _sameIdentity(readBack, identity)) {
            _guard.resume();
            _identityDiagnostic =
                'identity save failed; previous key remains active';
            throw const CompanionOperationError(
              errCodeFileIoError,
              message: 'identity persistence failed',
            );
          } else {
            _guard.pause();
            _identityDiagnostic =
                'identity persistence unreadable or unexpected; '
                'identity-sensitive work paused';
            throw const CompanionOperationError(
              errCodeFileIoError,
              message: 'identity persistence is uncertain',
            );
          }
        }
      }

      await _state.run(() async {
        identity = candidate;
        _guard.bumpGeneration();
        _clearIdentityRuntimeState();
        _guard.resume();
        _identityDiagnostic = saveDiagnostic;
      });
      onIdentityChanged?.call(identity);
    } finally {
      _guard.endSwap();
    }
  }

  /// Staged app-only reset: persist S2 defaults first, then optionally rotate
  /// the identity. A key-save failure after the state reset is returned as a
  /// partial result; it is never rolled back or reported as full success.
  Future<VirtualResetResult> resetVirtualData({
    bool rotateIdentity = false,
    bool preserveName = false,
  }) {
    return _identityQueue.run(() async {
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

      _guard.beginReset();
      _guard.bumpGeneration();
      try {
        final fresh = freshVirtualState(sensorSettings);
        if (preserveName) fresh.prefs.nodeName = prefs.nodeName;
        await _state.replace(fresh, allowResetting: true);

        _clearIdentityRuntimeState();
        _transport.resetCounters();

        if (candidate != null) {
          try {
            await _replaceIdentityLocked(candidate);
          } on CompanionOperationError catch (e) {
            return VirtualResetResult(
              dataReset: true,
              identityRotated: false,
              keyError: e,
            );
          }
        }
        return VirtualResetResult(
          dataReset: true,
          identityRotated: candidate != null,
        );
      } finally {
        _guard.endReset();
      }
    });
  }

  /// The active virtual 64-byte expanded key. Never reads the physical device.
  @override
  Future<Uint8List> exportPrivateKey() async {
    _requireIdentityReady();
    return identity.meshcore64;
  }

  /// Import a complete 64-byte expanded key after firmware-equivalent
  /// validation. Physical keys are never read or changed.
  @override
  Future<void> importPrivateKey(Uint8List expandedKey) async {
    if (expandedKey.length != 64 ||
        !await LocalIdentity.validateMeshcore64(expandedKey)) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid identity key',
      );
    }
    final candidate = await LocalIdentity.fromMeshcore64(expandedKey);
    await replaceIdentity(candidate);
  }

  /// Clear caches/sessions that belong to the previous identity. Persisted
  /// contacts, channels, preferences, queue, advert paths and custom sensor
  /// settings are deliberately retained.
  void _clearIdentityRuntimeState() {
    _cancelTransientSessions();
    _requests.clear();
    _contactTable.clearTransient();
    _deduper.clear();
    _floodScope.clear();
  }

  @override
  NodePrefs getSelfInfo() => prefs;

  @override
  int getTime() => clock.wallSeconds;

  @override
  bool setTime(int seconds) => clock.setWallSeconds(seconds);

  @override
  int getAutoAddConfig() => prefs.autoaddConfig;

  @override
  int getAutoAddMaxHops() => prefs.autoaddMaxHops;

  @override
  Future<void> setAutoAddConfig(int flags, int? maxHops) async {
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy.autoaddConfig = flags & 0xFF;
      if (maxHops != null) {
        prefsCopy.autoaddMaxHops = maxHops.clamp(0, 64);
      }
      return current.copyWith(prefs: prefsCopy);
    });
  }

  @override
  Future<void> setOtherParams({
    required int manualAddContacts,
    int? telemetryModes,
    int? advertLocPolicy,
    int? multiAcks,
  }) async {
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy.manualAddContacts = manualAddContacts & 0xFF;
      if (telemetryModes != null) {
        final raw = telemetryModes & 0xFF;
        prefsCopy
          ..telemetryModeBase = raw & 0x03
          ..telemetryModeLocation = (raw >> 2) & 0x03
          ..telemetryModeEnvironment = (raw >> 4) & 0x03;
      }
      if (advertLocPolicy != null) {
        prefsCopy.advertLocPolicy = advertLocPolicy & 0xFF;
      }
      if (multiAcks != null) prefsCopy.multiAcks = multiAcks & 0xFF;
      return current.copyWith(prefs: prefsCopy);
    });
  }

  /// Persist the virtual multi-ACK preference without changing the other
  /// `SET_OTHER_PARAMS` fields.
  @override
  Future<void> setMultiAcks(int value) async {
    if (value < 0 || value > 255) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'multi.acks must be 0-255',
      );
    }
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy.multiAcks = value;
      return current.copyWith(prefs: prefsCopy);
    });
  }

  /// Persist the virtual timezone offset without changing epoch seconds.
  @override
  Future<void> setTimezoneOffsetHours(int hours) async {
    if (hours < -12 || hours > 14) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid timezone offset',
      );
    }
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy.timezoneOffsetHours = hours;
      return current.copyWith(prefs: prefsCopy);
    });
  }

  int get timezoneOffsetHours => prefs.timezoneOffsetHours;

  /// The virtual companion's advertised capabilities. Physical board strings,
  /// capacities, firmware code and path mode are never copied in; only the
  /// physical client-repeat byte is reported because it controls the modem.
  @override
  DeviceInfo getDeviceInfo() => buildVirtualDeviceInfo(
        clientRepeat: physical.clientRepeat,
        pathHashMode: prefs.pathHashMode,
      );

  /// Adopt capabilities from a fresh physical DEVICE_INFO/SELF_INFO read.
  ///
  /// This never changes virtual identity, board strings, capacities or path
  /// mode. The physical max TX is mirrored into [prefs] for `SELF_INFO`
  /// reporting (the radio remains the authority for actual TX limits).
  void adoptPhysicalCapabilities(PhysicalCapabilities capabilities) {
    _radio.adoptCapabilities(capabilities);
  }

  @override
  Future<BatteryReading> getBatteryAndStorage() async {
    final millivolts = await battery.refresh();
    return BatteryReading(
      millivolts: millivolts,
      // Storage is the deterministic virtual partition, never physical flash.
      storageUsedKb: storageUsedKb,
      storageTotalKb: virtualStorageTotalKb,
    );
  }

  /// Monotonic age of the last successful physical battery sample.
  int? get batterySampleAgeSeconds => battery.sampleAgeSeconds;

  /// Whether the current battery voltage is older than the freshness window.
  bool get batteryStale => battery.stale;

  /// Last battery failure/staleness detail (no fabricated fresh timestamp).
  String? get batteryDiagnostic => battery.diagnostic;

  final Map<String, String> _customVars = {};

  @override
  Map<String, String> getCustomVars() =>
      Map<String, String>.unmodifiable(_customVars);

  @override
  Future<void> setCustomVar(String name, String value) async {
    if (!sensorSettings.supports(name)) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'unsupported sensor setting',
      );
    }
    final normalized = sensorSettings.normalize(name, value);
    if (normalized == null) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid sensor setting value',
      );
    }
    await _commit((current) {
      final candidate = Map<String, String>.of(current.customSettings)
        ..[name] = normalized;
      return current.copyWith(customSettings: candidate);
    });
  }

  @override
  Future<Uint8List> sign(Uint8List message) {
    _requireIdentityReady();
    return identity.sign(message);
  }

  // -------------------------------------------------------------------------
  // Contacts
  // -------------------------------------------------------------------------

  @override
  List<Contact> getContacts({int since = 0}) => _contactTable.since(since);

  @override
  Contact? getContactByKey(Uint8List pubkey) => _contactTable.findByKey(pubkey);

  @override
  Contact? getPersistentContactByKey(Uint8List pubkey) =>
      _contactTable.findPersistentByKey(pubkey);

  @override
  Contact? getContactByKeyPrefix(Uint8List prefix) =>
      _contactTable.findByKeyPrefix(prefix);

  @override
  Future<void> addUpdateContact(
    Contact contact, {
    bool hasGps = true,
    int? identityGeneration,
  }) async {
    if (identityGeneration != null && !_identityCurrent(identityGeneration)) {
      return;
    }
    ContactUpsert? upsert;
    await _commit((current) {
      upsert = _contactTable.upsert(
        contact,
        hasGps: hasGps,
        prefs: current.prefs,
        maxContacts: virtualMaxContacts,
        base: current.contacts,
      );
      final result = upsert!;
      if (result.full) {
        throw const CompanionOperationError(
          errCodeTableFull,
          message: 'contact table full',
        );
      }
      return current.copyWith(contacts: result.candidate);
    }, identityGeneration: identityGeneration);
    if (identityGeneration != null && !_identityCurrent(identityGeneration)) {
      return;
    }
    final result = upsert;
    if (result == null) return;

    // Promote over a transient slot only after the persistent add succeeded.
    _contactTable.removeTransient(contact.publicKey);
    final evicted = result.evicted;
    if (evicted != null) {
      _forgetContactState(evicted.publicKey);
      pushSink?.pushContactDeleted(evicted.publicKey);
    }
  }

  @override
  Future<void> removeContact(Uint8List pubkey) async {
    List<Contact>? candidate;
    await _commit((current) {
      candidate =
          _contactTable.removePersistent(pubkey, base: current.contacts);
      return candidate == null ? null : current.copyWith(contacts: candidate!);
    });
    if (candidate == null) {
      final transient = _contactTable.transientIndex(pubkey);
      if (transient == null) {
        throw const CompanionOperationError(
          errCodeNotFound,
          message: 'contact not found',
        );
      }
      _contactTable.removeTransient(pubkey);
      _forgetContactState(pubkey);
      return;
    }
    _forgetContactState(pubkey);
  }

  @override
  Future<void> resetPath(Uint8List pubkey) async {
    List<Contact>? candidate;
    await _commit((current) {
      candidate = _contactTable.resetPath(pubkey, base: current.contacts);
      return candidate == null ? null : current.copyWith(contacts: candidate!);
    });
    if (candidate == null) {
      if (_contactTable.transientIndex(pubkey) == null) {
        throw const CompanionOperationError(
          errCodeNotFound,
          message: 'contact not found',
        );
      }
      return;
    }
  }

  // -------------------------------------------------------------------------
  // Channels
  // -------------------------------------------------------------------------

  @override
  Channel? getChannel(int index) => _channels[index];

  @override
  int get maxChannels => virtualMaxChannels;

  @override
  Future<void> setChannel(int index, String name, Uint8List secret) async {
    if (index < 0 || index >= virtualMaxChannels) {
      throw const CompanionOperationError(
        errCodeNotFound,
        message: 'channel index out of range',
      );
    }
    await _commit((current) {
      final candidate = Map<int, Channel>.of(current.channels);
      candidate[index] =
          Channel(name: name, secret: Uint8List.fromList(secret));
      return current.copyWith(channels: candidate);
    });
  }

  // -------------------------------------------------------------------------
  // Adverts
  // -------------------------------------------------------------------------

  @override
  Future<bool> advertise({bool flood = false}) async {
    if (_semanticBlocked) return false;
    final generation = _guard.generation;
    final packet = await PacketBuilder.createAdvert(
      identity: identity,
      name: prefs.nodeName,
      lat: prefs.advertLocPolicy == advertLocNone ? 0.0 : prefs.latitude,
      lon: prefs.advertLocPolicy == advertLocNone ? 0.0 : prefs.longitude,
      flags: prefs.advType,
      flood: flood,
      timestamp: _requests.nextTimestamp(),
    );
    if (!_identityCurrent(generation)) return false;
    await _transmit(
      packet,
      flood: flood,
      scoped: true,
      identityGeneration: generation,
    );
    return _identityCurrent(generation);
  }

  @override
  Future<void> setAdvertName(String name) async {
    final valid = validateAdvertName(name);
    if (valid == null) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid advert name',
      );
    }
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy.nodeName = valid;
      return current.copyWith(prefs: prefsCopy);
    });
  }

  @override
  Future<void> setAdvertLatLon(double lat, double lon) async {
    if (!lat.isFinite || !lon.isFinite) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid advert coordinates',
      );
    }
    final latMicros = (lat * 1e6).round();
    final lonMicros = (lon * 1e6).round();
    if (!isValidAdvertCoordinateMicros(latMicros, lonMicros)) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid advert coordinates',
      );
    }
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy
        ..latitude = latMicros / 1e6
        ..longitude = lonMicros / 1e6;
      return current.copyWith(prefs: prefsCopy);
    });
  }

  @override
  AdvertPath? getAdvertPath(Uint8List prefix) =>
      _advertPaths[bytesToHex(prefix)];

  @override
  Future<Uint8List?> exportContact(Uint8List? pubkey) async {
    if (pubkey == null) {
      // Export SELF: a freshly built advert packet blob (the `meshcore://` URI).
      final packet = await PacketBuilder.createAdvert(
        identity: identity,
        name: prefs.nodeName,
        lat: prefs.advertLocPolicy == advertLocNone ? 0.0 : prefs.latitude,
        lon: prefs.advertLocPolicy == advertLocNone ? 0.0 : prefs.longitude,
        flags: prefs.advType,
        flood: true,
        timestamp: _requests.nextTimestamp(),
      );
      return packet.writeTo();
    }
    return getContactByKey(pubkey)?.rawAdvert;
  }

  @override
  Future<bool> importContact(Uint8List data) async {
    final packet = Packet.readFrom(data);
    if (packet == null || packet.payloadType != payloadTypeAdvert) return false;
    // Simulate receiving it flood-mode (the firmware loops it back as received).
    // The loopback runs after the caller's binary OK so response/push ordering
    // stays unambiguous; import success never guarantees insertion.
    packet.header = (packet.header & ~phRouteMask) | routeTypeFlood;
    // Stock clears the seen-table entry before looping the imported advert back.
    _deduper.clearHash(packet.calculatePacketHash());
    final generation = _guard.generation;
    Timer.run(() => unawaited(_rx.handleAdvert(packet, generation)));
    return true;
  }

  @override
  Future<bool> shareContact(Uint8List pubkey) async {
    final blob = getContactByKey(pubkey)?.rawAdvert;
    if (blob == null) return false;
    final packet = Packet.readFrom(blob);
    if (packet == null) return false;
    // Zero-hop: direct route with an empty path (firmware sendZeroHop).
    packet.header = (packet.header & ~phRouteMask) | routeTypeDirect;
    packet.setPath(const []);
    await _transmit(packet, flood: false);
    return true;
  }

  // -------------------------------------------------------------------------
  // Messaging
  // -------------------------------------------------------------------------

  /// Reject unicasts to the attached radio's own companion identity.
  ///
  /// The device transmits but does not receive its own raw TX, so such a
  /// message could never be acknowledged.
  void _ensureNotBlockedPeer(Uint8List pubkey) {
    final device = attachedDevicePublicKey;
    final isDevice = device != null &&
        device.length == pubkey.length &&
        bytesEqual(device, pubkey);
    if (isDevice || (localRouter?.isBlockedPeer(pubkey) ?? false)) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'the attached companion identity cannot be messaged',
      );
    }
  }

  @override
  Future<SentResult> sendTextMessage(
    Uint8List pubkey,
    String text, {
    int txtType = txtTypePlain,
    int attempt = 0,
    int? timestamp,
  }) =>
      _messages.sendTextMessage(
        pubkey,
        text,
        txtType: txtType,
        attempt: attempt,
        timestamp: timestamp,
      );

  @override
  Future<bool> sendChannelMessage(
    int channelIndex,
    String text, {
    int? timestamp,
  }) =>
      _messages.sendChannelMessage(channelIndex, text, timestamp: timestamp);

  @override
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) =>
      _messages.sendChannelData(
        channelIndex,
        dataType,
        payload,
        path: path,
        pathLenEncoded: pathLenEncoded,
      );

  @override
  Future<bool> sendControlData(Uint8List data) =>
      _messages.sendControlData(data);

  @override
  Future<QueuedMessage?> syncNextMessage() async {
    QueuedMessage? msg;
    await _commit((current) {
      if (current.queue.isEmpty) return null;
      final queue = [for (final m in current.queue.skip(1)) m.clone()];
      msg = current.queue.first.clone();
      return current.copyWith(queue: queue);
    });
    return msg;
  }

  @override
  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) =>
      _messages.sendBinaryReq(pubkey, data);

  @override
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) =>
      _messages.sendAnonReq(pubkey, data);

  @override
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) =>
      _messages.sendPathDiscoveryReq(pubkey);

  @override
  Future<SentResult> sendTelemetryRequest(
    Uint8List pubkey, {
    bool wantBase = true,
    bool wantLocation = true,
    bool wantEnvironment = true,
  }) =>
      _messages.sendTelemetryRequest(
        pubkey,
        wantBase: wantBase,
        wantLocation: wantLocation,
        wantEnvironment: wantEnvironment,
      );

  @override
  Future<SentResult> sendTracePathRaw(
    int tag,
    int authCode,
    int flags,
    Uint8List pathBytes,
  ) =>
      _messages.sendTracePathRaw(tag, authCode, flags, pathBytes);

  @override
  Future<bool> sendRawData(
    Uint8List payload,
    Uint8List path,
    int pathLenByte,
  ) =>
      _messages.sendRawData(payload, path, pathLenByte);

  @override
  Future<bool> sendRawPacket(Packet packet, int priority) =>
      _messages.sendRawPacket(packet, priority);

  @override
  Future<SentResult> sendLogin(Uint8List pubkey, String password) =>
      _messages.sendLogin(pubkey, password);

  @override
  Future<SentResult> sendStatusReq(Uint8List pubkey) =>
      _messages.sendStatusReq(pubkey);

  @override
  bool logout(Uint8List pubkey) {
    final prefix = Uint8List.fromList(pubkey.sublist(0, keyPrefix4));
    _requests.takeLogin(prefix);
    _requests.takeStatus(prefix);
    _stopKeepAlive(pubkey);
    return true;
  }

  @override
  bool hasConnection(Uint8List pubkey) => _sessions.contains(pubkey);

  // -------------------------------------------------------------------------
  // Flood scope
  // -------------------------------------------------------------------------

  /// The scope key used for scoped floods: the override (unless unscoped) or
  /// the stored default scope. Zero/absent keys mean unset.
  Uint8List? _effectiveFloodScope() => _floodScope.effective(prefs);

  @override
  void setFloodScopeKey(Uint8List? key) => _floodScope.setKey(key);

  @override
  void setFloodUnscoped() => _floodScope.setUnscoped();

  @override
  Future<void> setDefaultFloodScope(String name, Uint8List? key) async {
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy
        ..defaultScopeName = name
        ..defaultScopeKey = key == null ? null : Uint8List.fromList(key);
      return current.copyWith(prefs: prefsCopy);
    });
  }

  @override
  (String, Uint8List?) getDefaultFloodScope() =>
      (prefs.defaultScopeName, prefs.defaultScopeKey);

  // -------------------------------------------------------------------------
  // Radio, CLI, and stats
  // -------------------------------------------------------------------------

  @override
  Future<void> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  }) =>
      _radio.setRadioParams(
        freqHz,
        bwHz,
        sf,
        cr,
        clientRepeat: clientRepeat,
      );

  @override
  Future<void> setTxPower(int dbm) => _radio.setTxPower(dbm);

  /// Adopt the connected device's actual radio parameters as the node's own
  /// without re-configuring the device (used at attach/reconnect time).
  ///
  /// Only RF/TX values belong to the physical radio. Path-hash mode, name,
  /// location and other preferences are virtual state and are deliberately not
  /// adopted here.
  void syncRadioParams(RadioParams params) => _radio.syncRadioParams(params);

  @override
  int getPathHashMode() => prefs.pathHashMode;

  /// Set the virtual path-hash mode. Modes 0/1/2 select a 1/2/3-byte hash on
  /// new virtual floods. This is virtual state only: the physical device's
  /// mode is never changed.
  @override
  Future<void> setPathHashMode(int mode) async {
    await _commit((current) {
      final prefsCopy = NodePrefs()..copyFrom(current.prefs);
      prefsCopy.pathHashMode = clampPathHashMode(mode);
      return current.copyWith(prefs: prefsCopy);
    });
  }

  @override
  Future<TuningParams> getTuningParams() => _radio.getTuningParams();

  @override
  Future<void> setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) =>
      _radio.setTuningParams(rxDelayBaseMs, airtimeFactorMs);

  @override
  Future<String?> runCliCommand(String command) => _cli.runText(command);

  @override
  Future<String> runCliCommandBytes(Uint8List payload) =>
      _cli.runBytes(payload);

  @override
  Future<Uint8List> getAllowedRepeatFreq() => _radio.getAllowedRepeatFreq();

  @override
  Future<MeshStats> getStats(int statsType) async {
    switch (statsType) {
      case statsTypeCore:
        final batteryMv = await battery.refresh();
        final uptime = (clock.monotonicMilliseconds - _startedAtMonotonicMillis)
                .clamp(0, 0xFFFFFFFF) ~/
            1000;
        return MeshStats(
          batteryMv: batteryMv,
          uptimeSecs: uptime,
          errors: (_transport.stats['recv_errors'] as int?) ?? 0,
          queueLen: _messageQueue.length,
        );
      case statsTypeRadio:
        final noiseFloor = await _radio.refreshNoiseFloor();
        return MeshStats(
          noiseFloor: noiseFloor,
          lastRssi: _transport.lastRxRssi,
          lastSnrScaled: _transport.lastRxSnrScaled,
          txAirSecs: _transport.txAirSeconds,
          rxAirSecs: _transport.rxAirSeconds,
        );
      default:
        final stats = _transport.stats;
        return MeshStats(
          recv: (stats['recv'] as int?) ?? 0,
          sent: (stats['sent'] as int?) ?? 0,
          floodTx: (stats['flood_tx'] as int?) ?? 0,
          directTx: (stats['direct_tx'] as int?) ?? 0,
          floodRx: (stats['flood_rx'] as int?) ?? 0,
          directRx: (stats['direct_rx'] as int?) ?? 0,
          recvErrors: (stats['recv_errors'] as int?) ?? 0,
        );
    }
  }

  /// Cheap, I/O-free counters for app diagnostics.
  ///
  /// Unlike [getStats] with [statsTypeRadio], this never asks the physical
  /// device for a fresh noise floor. Per-identity RX counters describe the same
  /// received frame once per live identity; callers must label them accordingly.
  Map<String, Object?> get sessionStats => Map.unmodifiable({
        ..._transport.sessionStats,
        'queue_len': _messageQueue.length,
        'noise_floor': _radio.lastNoiseFloorDbm,
      });

  // -------------------------------------------------------------------------
  // RX path
  // -------------------------------------------------------------------------

  Future<void> _transmit(
    Packet packet, {
    required bool flood,
    bool scoped = false,
    bool preservePath = false,
    int priority = 0,
    int? identityGeneration,
  }) {
    _deduper.markSent(packet.calculatePacketHash());
    return _transport.transmit(
      packet,
      flood: flood,
      scoped: scoped,
      preservePath: preservePath,
      priority: priority,
      identityGeneration: identityGeneration,
    );
  }

  /// Deliver an in-process peer copy.
  ///
  /// The exact outbound bytes are parsed and handled like a final-hop received
  /// frame: synthetic metrics, no raw-RX push, no RF airtime, and no route
  /// consumption requirement.
  Future<void> receiveLocal(
    Uint8List raw, {
    double snr = 0,
    int rssi = 0,
  }) =>
      _onRawFrame(snr, rssi, raw, peerOrigin: true);

  Future<void> _onRawFrame(
    double snr,
    int rssi,
    Uint8List raw, {
    bool peerOrigin = false,
  }) =>
      _rx.handleRawFrame(snr, rssi, raw, peerOrigin: peerOrigin);

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  /// Number of persistent contacts (transient anonymous slots excluded).
  int get persistentContactCount => contacts.length;

  @override
  int get contactCount => persistentContactCount;

  /// Configured channel count, including the default Public channel.
  int get channelCount => channels.length;

  /// Messages waiting for `CMD_SYNC_NEXT_MESSAGE`.
  int get queuedMessageCount => _messageQueue.length;

  int get queuedDirectCount => _messageQueue.directCount;

  int get queuedChannelCount => _messageQueue.channelCount;

  /// Shared physical RF values currently reported by this virtual node.
  RadioParams get radioParams => RadioParams(
        frequencyHz: prefs.frequencyHz,
        bandwidthHz: prefs.bandwidthHz,
        spreadingFactor: prefs.spreadingFactor,
        codingRate: prefs.codingRate,
        txPowerDbm: prefs.txPowerDbm,
      );

  /// Last known physical tuning values.
  TuningParams get tuningParams => TuningParams(
        rxDelayBaseMs: prefs.rxDelayBaseMs,
        airtimeFactorMs: prefs.airtimeFactorMs,
      );

  /// Current virtual storage usage in compact canonical bytes.
  int get storageUsedBytes => _state.storageUsedBytes;

  /// Current virtual storage usage in the wire's KiB unit.
  int get storageUsedKb => storageKibForBytes(storageUsedBytes);

  /// Current advert-path cache size (capped at 64).
  int get advertPathCacheLength => _advertPaths.length;

  NodeState _snapshot({
    NodePrefs? prefs,
    List<Contact>? contacts,
    Map<int, Channel>? channels,
    List<QueuedMessage>? queue,
    Map<String, AdvertPath>? advertPaths,
    Map<String, String>? customSettings,
  }) =>
      NodeState(
        prefs: prefs ?? this.prefs,
        contacts: contacts ?? this.contacts,
        channels: channels ?? _channels,
        queue: queue ?? _messageQueue.messages,
        advertPaths: advertPaths ?? _advertPaths,
        customSettings: customSettings ?? _customVars,
      );

  void _applyState(NodeState state) {
    prefs.copyFrom(state.prefs);
    _contactTable.replacePersistent(state.contacts);
    _channels
      ..clear()
      ..addAll(state.channels);
    _messageQueue.replace(state.queue);
    _advertPathCache.replace(state.advertPaths);
    _customVars
      ..clear()
      ..addAll(state.customSettings);
  }

  void _publish(NodeState current, NodeState next, {bool replace = false}) {
    if (replace) {
      prefs.copyFrom(next.prefs);
    } else {
      // Persist only the preference fields this commit intended to change so a
      // radio readback that landed after the candidate snapshot survives.
      prefs.applyChangesFrom(current.prefs, next.prefs);
    }
    _contactTable.replacePersistent(next.contacts);
    _channels
      ..clear()
      ..addAll(next.channels);
    _messageQueue.replace(next.queue);
    _advertPathCache.replace(next.advertPaths);
    _customVars
      ..clear()
      ..addAll(next.customSettings);
  }

  /// Save a candidate produced from the state inside the persistence queue,
  /// then publish it. A save failure leaves node state untouched so the client
  /// sees an honest error.
  ///
  /// [identityGeneration] scopes background RX mutations so a completion from
  /// the previous identity cannot save/publish over a successful switch.
  Future<void> _commit(
    NodeState? Function(NodeState current) mutate, {
    int? identityGeneration,
  }) =>
      _state.commit(mutate, identityGeneration: identityGeneration);

  void _notifyStateChanged() {
    if (_guard.retired) return;
    try {
      onStateChanged?.call();
    } catch (_) {
      // A host notification failure must never roll back durable state.
    }
  }

  void _notifyPhysicalConfigChanged() {
    if (_guard.retired) return;
    try {
      onPhysicalConfigChanged?.call();
    } catch (_) {
      // Propagation is best-effort; the active node remains authoritative.
    }
  }

  /// Adopt a shared physical snapshot without touching the device.
  ///
  /// Used to keep inactive identities' `SELF_INFO`/tuning values consistent
  /// with the active identity after attach, reconnect, or a confirmed write.
  void syncPhysicalState({
    RadioParams? params,
    TuningParams? tuning,
    PhysicalCapabilities? capabilities,
  }) {
    _radio.syncPhysicalState(
      params: params,
      tuning: tuning,
      capabilities: capabilities,
    );
  }

  /// Wait for queued persistence writes to settle.
  Future<void> flush() => _state.flush();

  /// Reset persisted virtual data to S2 defaults while retaining the identity.
  /// Does not touch the physical radio or device-target/session configuration.
  Future<void> resetVirtualState() async {
    await resetVirtualData();
  }

  Future<void> _enqueueMessage(
    QueuedMessage message, {
    int? identityGeneration,
  }) async {
    if (_guard.retired) return;
    if (identityGeneration != null && !_identityCurrent(identityGeneration)) {
      return;
    }
    var quotaExceeded = false;
    var enqueued = false;
    try {
      await _commit((current) {
        final newOnly = current.copyWith(queue: [message]);
        if (newOnly.storageBytes > storageQuotaBytes) {
          quotaExceeded = true;
          return null; // the new message alone does not fit
        }
        final incoming = message.clone();
        final candidateQueue = [
          for (final m in current.queue) m.clone(),
          incoming,
        ];
        // Stock: when the queue is full, evict the oldest *channel* message and
        // append the new one; if there is no channel message, drop the new
        // message. Apply the same policy to virtual storage-quota pressure.
        while (true) {
          final candidate = current.copyWith(queue: candidateQueue);
          final overCount = candidateQueue.length > maxQueueSize;
          final overQuota = candidate.storageBytes > storageQuotaBytes;
          if (!overCount && !overQuota) break;
          final channelIndex = candidateQueue.indexWhere((m) => m.isChannel);
          if (channelIndex < 0) return null;
          final removed = candidateQueue.removeAt(channelIndex);
          if (identical(removed, incoming)) return null;
        }
        enqueued = true;
        return current.copyWith(queue: candidateQueue);
      }, identityGeneration: identityGeneration);
    } on CompanionOperationError {
      _transport.recordRxError();
      return;
    }
    if (quotaExceeded) {
      _transport.recordRxError();
      return;
    }
    if (!enqueued) return;
    if (identityGeneration != null && !_identityCurrent(identityGeneration)) {
      return;
    }
    pushSink?.pushMsgWaiting();
  }

  /// Fire-and-forget persistence for internal state updates. Client-facing
  /// durable mutations use the awaitable [_commit] path instead.
  void _persist() => _state.persist();

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Drop identity-dependent runtime state when a persistent contact is
  /// removed or overwritten. The saved advert lives in the [Contact] itself.
  void _forgetContactState(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    _acks.removeForContact(pubkey);
    _sessions.removeByHex(hex);
    _requests.removeForContact(pubkey);
  }
}
