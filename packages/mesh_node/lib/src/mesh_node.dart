import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'battery_service.dart';
import 'cli.dart';
import 'identity_persistence.dart';
import 'local_peer_router.dart';
import 'node_store.dart';
import 'reset.dart';
import 'scheduler.dart';
import 'sensor_settings.dart';
import 'virtual_clock.dart';

class _PendingAck {
  _PendingAck(this.crc, this.contactPubkey, this.timer);
  final int crc;
  final Uint8List contactPubkey;
  final Timer timer;
}

/// A login keep-alive session with a repeater/room server.
class _Connection {
  _Connection(this.pubkey, this.interval);

  final Uint8List pubkey;
  Duration interval;
  Timer? timer;

  /// Monotonic seconds of the last activity; the session is dropped once this
  /// is older than 2.5x [interval].
  int lastActivity = 0;

  /// The ACK hash we expect from the next keep-alive request.
  int? expectedAck;

  void stop() {
    timer?.cancel();
    timer = null;
    expectedAck = null;
  }
}

/// Maximum number of inbound messages held for the client before the oldest
/// is dropped. Matches openHop's `DEFAULT_OFFLINE_QUEUE_SIZE`.
const int defaultOfflineQueueSize = 512;

/// The reimplemented MeshCore companion node.
///
/// Holds the proxy identity and all node state, drives the app-facing
/// [CompanionBridge] surface, and uses a [RadioLink] purely as a raw radio:
/// outbound packets go through `sendRawPacket`, and every received frame
/// arrives via the raw RX listener.
class MeshNode extends CompanionBridge {
  MeshNode({
    required this.identity,
    required this.link,
    NodePrefs? prefs,
    this.physical = const PhysicalCapabilities(),
    this.store,
    this.ackTimeout = const Duration(seconds: 10),
    this.maxQueueSize = defaultOfflineQueueSize,
    this.storageQuotaBytes = virtualStorageQuotaBytes,
    this.sensorSettings = const EmptyVirtualSensorSettingsProvider(),
    this.scheduler = const TimerMeshScheduler(),
    this.identityPersistence,
    this.onIdentityChanged,
    this.onPoweredOff,
    this.localRouter,
    this.onStateChanged,
    this.onPhysicalConfigChanged,
    VirtualClock? clock,
  })  : prefs = prefs ?? NodePrefs(),
        clock = clock ?? VirtualClock() {
    channels[0] = _defaultChannel();
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

  /// Invoked after durable state publication/reset and queue drain. May be
  /// called often; hosts are expected to debounce UI notifications.
  final void Function()? onStateChanged;

  /// Invoked after a confirmed physical RF/tuning change or readback so the
  /// host can propagate the shared snapshot to the other identities.
  final void Function()? onPhysicalConfigChanged;

  /// Virtual wall/monotonic clock. Wall changes never touch the host clock or
  /// the radio RTC (the radio is used purely as a packet transport).
  final VirtualClock clock;

  /// Sensor settings provider backing `GET/SET_CUSTOM_VAR`.
  final VirtualSensorSettingsProvider sensorSettings;

  /// Injectable scheduler for cancellable endpoint ACK delays.
  final MeshScheduler scheduler;

  /// Coalesced physical-battery samples with virtual-only storage reporting.
  late final BatteryService battery;

  /// Capabilities of the attached physical radio modem. Kept separate from the
  /// virtual [DeviceInfo] advertised to clients.
  PhysicalCapabilities physical;

  final Duration ackTimeout;

  /// Optional persistence backend. When set, [load] restores the last saved
  /// state and every mutation is written back with [NodeStore.save].
  final NodeStore? store;

  /// Maximum number of queued inbound messages; oldest are dropped on overflow.
  final int maxQueueSize;

  /// Deterministic virtual storage quota for this node (4 MiB by default).
  final int storageQuotaBytes;

  final List<Contact> contacts = [];
  final Map<int, Channel> channels = {};

  /// Anonymous-request targets. These are deliberately not persisted, counted
  /// in DEVICE_INFO, or returned by contact listing.
  final List<Contact> _transientContacts = [];

  final List<QueuedMessage> _messageQueue = [];
  final List<_PendingAck> _pendingAcks = [];
  final List<CancelScheduled> _ackScheduleCancels = [];
  final Map<String, AdvertPath> _advertPaths = {};

  /// Pending path-discovery requests: tag -> target public key. A matching
  /// `PAYLOAD_TYPE_RESPONSE` extra in a returned-path packet is pushed to the
  /// client via `PUSH_CODE_PATH_DISCOVERY_RESPONSE`.
  final Map<int, Uint8List> _pendingDiscovery = {};

  /// Pending login/status requests, matched by the sender's 4-byte pubkey
  /// prefix (the firmware's legacy matching scheme).
  Uint8List? _pendingLogin;
  Uint8List? _pendingStatus;

  /// Pending telemetry requests, matched by the reflected request tag. The
  /// response (when it arrives) is pushed via
  /// `PUSH_CODE_TELEMETRY_RESPONSE`.
  final Map<int, Uint8List> _pendingTelemetry = {};

  /// Pending binary/anon requests, matched by the reflected request tag. The
  /// response (when it arrives) is pushed via `PUSH_CODE_BINARY_RESPONSE`.
  final Map<int, Uint8List> _pendingBinary = {};

  /// Active login keep-alive sessions, keyed by server public key hex.
  final Map<String, _Connection> _connections = {};

  /// `CMD_SET_FLOOD_SCOPE_KEY` override (null = use the default scope) and the
  /// "force unscoped" flag. Both are cleared by [reboot].
  Uint8List? _floodScopeOverride;
  bool _floodUnscoped = false;

  /// Recently seen packet hashes (hex -> epoch seconds). Used to suppress
  /// duplicate queued messages (retransmits, repeated reception) while still
  /// ACKing direct duplicates. Mirrors `Mesh.cpp`'s `hasSeen` table and
  /// openHop's `_check_dedup` (300s TTL, 1000 entries). Dart's Map preserves
  /// insertion order, so the oldest entry is `keys.first`.
  final Map<String, int> _seenPackets = {};
  final Map<String, int> _sentGroupPacketHashes = {};
  static const int _seenPacketTtlSecs = 300;
  static const int _seenPacketMax = 1000;
  String? _localRoutingDiagnostic;

  /// Last in-process mirror failure (never contains key material).
  String? get localRoutingDiagnostic => _localRoutingDiagnostic;
  int _lastRequestTag = 0;
  int _lastPacketTimestamp = 0;

  /// Returns `true` if [packetHash] was already seen within the TTL window.
  bool _isDuplicate(Uint8List packetHash) {
    final key = bytesToHex(packetHash);
    final now = clock.monotonicSeconds;
    final seenAt = _seenPackets[key];
    if (seenAt != null && now - seenAt <= _seenPacketTtlSecs) {
      _seenPackets.remove(key);
      _seenPackets[key] = now; // refresh recency
      return true;
    }
    _seenPackets.remove(key);
    _seenPackets[key] = now;
    _seenPackets.removeWhere((_, ts) => now - ts > _seenPacketTtlSecs);
    while (_seenPackets.length > _seenPacketMax) {
      _seenPackets.remove(_seenPackets.keys.first);
    }
    return false;
  }

  static Channel _defaultChannel() => Channel(
        name: 'Public',
        secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
      );

  CancelScheduled _scheduleAck(Duration delay, void Function() action) {
    final generation = _identityGeneration;
    CancelScheduled? cancel;
    var ran = false;
    cancel = scheduler.schedule(delay, () {
      ran = true;
      if (cancel != null) _ackScheduleCancels.remove(cancel);
      if (!_identityCurrent(generation)) return;
      action();
    });
    if (ran) {
      // A synchronous scheduler already executed the action; there is nothing
      // to track or cancel.
      return () {};
    }
    _ackScheduleCancels.add(cancel);
    return cancel;
  }

  void _cancelAckSchedules() {
    for (final cancel in _ackScheduleCancels) {
      cancel();
    }
    _ackScheduleCancels.clear();
  }

  /// Restore persisted state from [store], if one is configured. Call before
  /// [start] so the node comes up with the previously known contacts,
  /// channels, queue, and preferences.
  Future<void> load() async {
    final state = await store?.load();
    if (state == null) return;
    prefs.copyFrom(state.prefs);
    contacts
      ..clear()
      ..addAll(state.contacts);
    channels
      ..clear()
      ..addAll(state.channels);
    channels.putIfAbsent(0, _defaultChannel);
    final publicSecret = LocalIdentity.defaultPublicChannelSecret;
    final publicChannel = channels[0];
    if (publicChannel != null &&
        _bytesEqual(publicChannel.secret, publicSecret) &&
        publicChannel.name.toLowerCase() == 'public') {
      channels[0] = _defaultChannel();
    }
    _messageQueue
      ..clear()
      ..addAll(state.queue);
    _advertPaths
      ..clear()
      ..addAll(state.advertPaths);
    _customVars
      ..clear()
      ..addAll(sensorSettings.initialSettings);
    for (final entry in state.customSettings.entries) {
      if (!sensorSettings.supports(entry.key)) continue;
      final normalized = sensorSettings.normalize(entry.key, entry.value);
      if (normalized != null) _customVars[entry.key] = normalized;
    }
  }

  /// Serialises physical configuration transactions (fresh repeat query, write
  /// ACK, readback) without nesting the device link's request lock.
  Future<void> _configTail = Future<void>.value();

  /// Serialises identity replacement requests.
  Future<void> _identityTail = Future<void>.value();

  /// Serialises state saves/publication so an old snapshot cannot publish
  /// across an identity switch.
  Future<void> _stateTail = Future<void>.value();

  int _identityGeneration = 0;
  bool _identitySwapping = false;
  bool _identityPaused = false;
  String? _identityDiagnostic;

  int _activePhysicalTx = 0;
  Completer<void>? _physicalTxIdle;
  bool _poweredOff = false;
  bool _resetInProgress = false;
  bool _retired = false;
  int _lifecycleGeneration = 0;

  /// True after a successful local shutdown until an explicit node start.
  bool get poweredOff => _poweredOff;

  /// True once this runtime has been retired by its owner. A retired node never
  /// transmits, receives, or persists again.
  bool get retired => _retired;

  @override
  int get lifecycleGeneration => _lifecycleGeneration;

  /// Bumped only after a verified successful identity switch.
  int get identityGeneration => _identityGeneration;

  /// True when identity storage is unreadable/uncertain and semantic work must
  /// pause until a successful reload/replacement.
  bool get identityPaused => _identityPaused;

  /// Last identity lifecycle diagnostic (never contains key material).
  String? get identityDiagnostic => _identityDiagnostic;

  Future<T> _runIdentity<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _identityTail = _identityTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<T> _runState<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _stateTail = _stateTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<void> _waitForPhysicalTxIdle() {
    if (_activePhysicalTx == 0) return Future<void>.value();
    return (_physicalTxIdle ??= Completer<void>()).future;
  }

  bool _radioCacheUncertain = false;
  bool _radioCacheVerified = true;
  bool _radioRequiresReboot = false;
  bool _hasTuningCache = false;
  bool _tuningCacheVerified = false;
  bool _needsReconcile = false;
  String? _physicalDiagnostic;
  String? _storageDiagnostic;

  /// A write/timeout left the physical radio cache uncertain; do not retry the
  /// write automatically. Reconcile with a settings read or reconnect.
  bool get radioCacheUncertain => _radioCacheUncertain;

  /// The last confirmed radio cache came from a successful readback.
  bool get radioCacheVerified => _radioCacheVerified;

  /// A physical CLI `set radio` saved firmware prefs; a reboot is required for
  /// the active radio to match the saved values.
  bool get physicalRadioRequiresReboot => _radioRequiresReboot;

  /// Alias used by diagnostics.
  bool get radioRequiresReboot => _radioRequiresReboot;

  bool get tuningCacheVerified => _tuningCacheVerified;

  /// One settings read is due to reconcile an uncertain/unverified cache.
  bool get physicalReconcilePending => _needsReconcile;

  /// Last physical-operation diagnostic (never contains secrets).
  String? get physicalDiagnostic => _physicalDiagnostic;

  Future<T> _runConfig<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _configTail = _configTail.then((_) async {
      try {
        completer.complete(await action());
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  CompanionOperationError _operationError(DeviceCommandError e) =>
      CompanionOperationError(
        e.clientErrorCode,
        message: e.message,
        disabled: e.isDisabled,
        uncertain: e.mayHaveApplied,
      );

  CompanionOperationError _queryError(DeviceCommandError e) =>
      CompanionOperationError(e.clientErrorCode, message: e.message);

  CompanionOperationError _illegalArgument(String message) =>
      CompanionOperationError(errCodeIllegalArg, message: message);

  final Map<String, int> _packetStats = {
    'recv': 0,
    'sent': 0,
    'flood_tx': 0,
    'direct_tx': 0,
    'flood_rx': 0,
    'direct_rx': 0,
    'recv_errors': 0,
  };

  /// Wall-clock time of the last [start], used for the uptime stat.
  int _startedAtMonotonicMillis = 0;

  /// Most recent received-frame radio metrics, reported in the radio stats.
  int _lastRxRssi = 0;
  int _lastRxSnrScaled = 0;

  /// Accumulated on-air time (microseconds) for the radio stats counters.
  int _txAirMicros = 0;
  int _rxAirMicros = 0;

  /// Estimated airtime of an [bytes]-byte frame under the current radio
  /// settings, or 0 when the parameters are not usable.
  int _airtimeMicrosFor(int bytes) {
    final cr = prefs.codingRate <= 4 ? prefs.codingRate + 4 : prefs.codingRate;
    if (prefs.spreadingFactor < 5 ||
        prefs.spreadingFactor > 12 ||
        prefs.bandwidthHz <= 0 ||
        cr < 5 ||
        cr > 8) {
      return 0;
    }
    return loraTimeOnAirMicros(
      payloadBytes: bytes,
      spreadingFactor: prefs.spreadingFactor,
      bandwidthHz: prefs.bandwidthHz,
      codingRate: cr,
    );
  }

  int get _selfHash => identity.publicKey[0];

  /// Attach the raw RX listener. Call once the device link is connected.
  void start() {
    if (_retired) throw StateError('cannot start a retired mesh node');
    _poweredOff = false;
    _startedAtMonotonicMillis = clock.monotonicMilliseconds;
    link.setRawRxListener(_onRawFrame);
    battery.start();
  }

  void stop() {
    link.setRawRxListener(null);
    battery.stop();
    _cancelAckSchedules();
    for (final ack in _pendingAcks) {
      ack.timer.cancel();
    }
    _pendingAcks.clear();
    for (final conn in _connections.values) {
      conn.stop();
    }
    _connections.clear();
  }

  /// Permanently stop semantic work for a runtime that is being replaced or
  /// deleted. Files are left intact for the owner to remove, but a late packet
  /// can no longer save or recreate state after this completes.
  Future<void> retire() async {
    if (_retired) return;
    _retired = true;
    stop();
    await _waitForPhysicalTxIdle();
    try {
      await _identityTail;
      await _stateTail;
      await store?.flush();
    } catch (_) {
      // Failures were already reported through their save futures.
    }
  }

  // -------------------------------------------------------------------------
  // CompanionBridge: identity / info
  // -------------------------------------------------------------------------

  @override
  Uint8List getPublicKey() => identity.publicKey;

  bool _sameIdentity(LocalIdentity a, LocalIdentity b) =>
      _bytesEqual(a.meshcore64, b.meshcore64);

  bool get _identityBlocked => _identityPaused || _identitySwapping;

  bool get _semanticBlocked =>
      _retired || _poweredOff || _resetInProgress || _identityBlocked;

  bool _identityCurrent(int generation) =>
      !_semanticBlocked && generation == _identityGeneration;

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
      _runIdentity(() => _replaceIdentityLocked(candidate));

  Future<void> _replaceIdentityLocked(LocalIdentity candidate) async {
    final candidateKey = candidate.meshcore64;
    if (!await LocalIdentity.validateMeshcore64(candidateKey)) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid identity key',
      );
    }

    _identitySwapping = true;
    try {
      await _waitForPhysicalTxIdle();

      String? saveDiagnostic;
      final backend = identityPersistence;
      if (backend != null) {
        try {
          await backend.save(candidate);
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
            _identityPaused = false;
            _identityDiagnostic =
                'identity save failed; previous key remains active';
            throw const CompanionOperationError(
              errCodeFileIoError,
              message: 'identity persistence failed',
            );
          } else {
            _identityPaused = true;
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

      await _runState(() async {
        identity = candidate;
        _identityGeneration++;
        _clearIdentityRuntimeState();
        _identityPaused = false;
        _identityDiagnostic = saveDiagnostic;
      });
      onIdentityChanged?.call(identity);
    } finally {
      _identitySwapping = false;
    }
  }

  /// Staged app-only reset: persist S2 defaults first, then optionally rotate
  /// the identity. A key-save failure after the state reset is returned as a
  /// partial result; it is never rolled back or reported as full success.
  Future<VirtualResetResult> resetVirtualData({
    bool rotateIdentity = false,
    bool preserveName = false,
  }) {
    return _runIdentity(() async {
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

      _resetInProgress = true;
      _identityGeneration++;
      try {
        final fresh = freshVirtualState(sensorSettings);
        if (preserveName) fresh.prefs.nodeName = prefs.nodeName;
        await _runState(() async {
          final s = store;
          if (s != null) await s.flush();
          await _saveState(fresh);
          _publish(fresh);
        });
        _notifyStateChanged();

        _clearIdentityRuntimeState();
        _storageDiagnostic = null;
        _lastRxRssi = 0;
        _lastRxSnrScaled = 0;
        _txAirMicros = 0;
        _rxAirMicros = 0;
        for (final key in _packetStats.keys.toList()) {
          _packetStats[key] = 0;
        }

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
        _resetInProgress = false;
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
    _cancelAckSchedules();
    for (final ack in _pendingAcks) {
      ack.timer.cancel();
    }
    _pendingAcks.clear();
    _pendingDiscovery.clear();
    _pendingTelemetry.clear();
    _pendingBinary.clear();
    _pendingLogin = null;
    _pendingStatus = null;
    for (final conn in _connections.values) {
      conn.stop();
    }
    _connections.clear();
    _transientContacts.clear();
    _seenPackets.clear();
    _sentGroupPacketHashes.clear();
    _floodScopeOverride = null;
    _floodUnscoped = false;
    _lastRequestTag = 0;
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
    final prefsCopy = NodePrefs()..copyFrom(prefs);
    prefsCopy.autoaddConfig = flags & 0xFF;
    if (maxHops != null) {
      prefsCopy.autoaddMaxHops = maxHops.clamp(0, 64);
    }
    await _commit(_snapshot(prefs: prefsCopy));
  }

  @override
  Future<void> setOtherParams({
    required int manualAddContacts,
    int? telemetryModes,
    int? advertLocPolicy,
    int? multiAcks,
  }) async {
    final prefsCopy = NodePrefs()..copyFrom(prefs);
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
    await _commit(_snapshot(prefs: prefsCopy));
  }

  /// Persist the virtual multi-ACK preference without changing the other
  /// `SET_OTHER_PARAMS` fields.
  Future<void> setMultiAcks(int value) async {
    if (value < 0 || value > 255) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'multi.acks must be 0-255',
      );
    }
    final prefsCopy = NodePrefs()..copyFrom(prefs);
    prefsCopy.multiAcks = value;
    await _commit(_snapshot(prefs: prefsCopy));
  }

  /// Persist the virtual timezone offset without changing epoch seconds.
  Future<void> setTimezoneOffsetHours(int hours) async {
    if (hours < -12 || hours > 14) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'invalid timezone offset',
      );
    }
    final prefsCopy = NodePrefs()..copyFrom(prefs);
    prefsCopy.timezoneOffsetHours = hours;
    await _commit(_snapshot(prefs: prefsCopy));
  }

  int get timezoneOffsetHours => prefs.timezoneOffsetHours;

  /// The virtual companion's advertised capabilities. Physical board strings,
  /// capacities, firmware code and path mode are never copied in; only the
  /// physical client-repeat byte is reported because it controls the modem.
  DeviceInfo get virtualDeviceInfo => buildVirtualDeviceInfo(
        clientRepeat: physical.clientRepeat,
        pathHashMode: prefs.pathHashMode,
      );

  @override
  DeviceInfo getDeviceInfo() => virtualDeviceInfo;

  /// Adopt capabilities from a fresh physical DEVICE_INFO/SELF_INFO read.
  ///
  /// This never changes virtual identity, board strings, capacities or path
  /// mode. The physical max TX is mirrored into [prefs] for `SELF_INFO`
  /// reporting (the radio remains the authority for actual TX limits).
  void adoptPhysicalCapabilities(PhysicalCapabilities capabilities) {
    physical = capabilities;
    prefs.maxTxPower = capabilities.maxTxPower;
    _persist();
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
    final candidate = Map<String, String>.of(_customVars)
      ..[name] = normalized;
    await _commit(_snapshot(customSettings: candidate));
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
  List<Contact> getContacts({int since = 0}) =>
      contacts.where((c) => c.lastmod > since).toList();

  Iterable<Contact> get _allContacts sync* {
    yield* contacts;
    yield* _transientContacts;
  }

  @override
  Contact? getContactByKey(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    for (final c in _allContacts) {
      if (c.publicKeyHex == hex) return c;
    }
    return null;
  }

  @override
  Contact? getPersistentContactByKey(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    for (final c in contacts) {
      if (c.publicKeyHex == hex) return c;
    }
    return null;
  }

  @override
  Contact? getContactByKeyPrefix(Uint8List prefix) {
    for (final c in _allContacts) {
      if (c.publicKey.length >= prefix.length &&
          _bytesEqual(c.publicKey.sublist(0, prefix.length), prefix)) {
        return c;
      }
    }
    return null;
  }

  @override
  Future<void> addUpdateContact(
    Contact contact, {
    bool hasGps = true,
    int? identityGeneration,
  }) async {
    if (identityGeneration != null &&
        !_identityCurrent(identityGeneration)) {
      return;
    }
    final candidate = [for (final c in contacts) c.clone()];
    final idx =
        candidate.indexWhere((c) => c.publicKeyHex == contact.publicKeyHex);
    Contact? evicted;
    if (idx >= 0) {
      final old = candidate[idx];
      final updated = contact.clone()
        ..syncSince =
            contact.syncSince != 0 ? contact.syncSince : old.syncSince
        ..rawAdvert = contact.rawAdvert ?? old.rawAdvert;
      if (!hasGps) {
        updated
          ..gpsLat = old.gpsLat
          ..gpsLon = old.gpsLon;
      }
      candidate[idx] = updated;
    } else {
      final added = contact.clone();
      if (candidate.length >= virtualMaxContacts) {
        final overwrite = _oldestOverwritableIndex(candidate);
        if (overwrite < 0) {
          throw const CompanionOperationError(
            errCodeTableFull,
            message: 'contact table full',
          );
        }
        evicted = candidate[overwrite];
        candidate[overwrite] = added;
      } else {
        candidate.add(added);
      }
    }
    await _commit(
      _snapshot(contacts: candidate),
      identityGeneration: identityGeneration,
    );
    if (identityGeneration != null &&
        !_identityCurrent(identityGeneration)) {
      return;
    }

    // Promote over a transient slot only after the persistent add succeeded.
    _transientContacts.removeWhere(
        (c) => c.publicKeyHex == contact.publicKeyHex);
    if (evicted != null) {
      _forgetContactState(evicted.publicKey);
      pushSink?.pushContactDeleted(evicted.publicKey);
    }
  }

  /// Index of the oldest non-favourite contact, or -1 when overwrite-on-full is
  /// disabled (`AUTO_ADD_OVERWRITE_OLDEST`) or every contact is a favourite.
  int _oldestOverwritableIndex(List<Contact> table) {
    if ((prefs.autoaddConfig & autoAddOverwriteOldest) == 0) return -1;
    var oldestIdx = -1;
    var oldestLastmod = 0xFFFFFFFF;
    for (var i = 0; i < table.length; i++) {
      final isFavourite = (table[i].flags & 0x01) != 0;
      if (!isFavourite && table[i].lastmod < oldestLastmod) {
        oldestLastmod = table[i].lastmod;
        oldestIdx = i;
      }
    }
    return oldestIdx;
  }

  @override
  Future<void> removeContact(Uint8List pubkey) async {
    final hex = bytesToHex(pubkey);
    final candidate = [for (final c in contacts) c.clone()];
    final before = candidate.length;
    candidate.removeWhere((c) => c.publicKeyHex == hex);
    if (candidate.length == before) {
      final transientBefore = _transientContacts.length;
      _transientContacts.removeWhere((c) => c.publicKeyHex == hex);
      if (_transientContacts.length == transientBefore) {
        throw const CompanionOperationError(
          errCodeNotFound,
          message: 'contact not found',
        );
      }
      _forgetContactState(pubkey);
      return;
    }
    await _commit(_snapshot(contacts: candidate));
    _forgetContactState(pubkey);
  }

  @override
  Future<void> resetPath(Uint8List pubkey) async {
    final hex = bytesToHex(pubkey);
    final candidate = [for (final c in contacts) c.clone()];
    final idx = candidate.indexWhere((c) => c.publicKeyHex == hex);
    if (idx < 0) {
      Contact? transient;
      for (final c in _transientContacts) {
        if (c.publicKeyHex == hex) {
          transient = c;
          break;
        }
      }
      if (transient == null) {
        throw const CompanionOperationError(
          errCodeNotFound,
          message: 'contact not found',
        );
      }
      transient
        ..outPath = Uint8List(0)
        ..outPathLen = -1;
      return;
    }
    candidate[idx]
      ..outPath = Uint8List(0)
      ..outPathLen = -1;
    await _commit(_snapshot(contacts: candidate));
  }

  // -------------------------------------------------------------------------
  // Channels
  // -------------------------------------------------------------------------

  @override
  Channel? getChannel(int index) => channels[index];

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
    final candidate = {
      for (final e in channels.entries)
        e.key: Channel(
          name: e.value.name,
          secret: Uint8List.fromList(e.value.secret),
        ),
    };
    candidate[index] =
        Channel(name: name, secret: Uint8List.fromList(secret));
    await _commit(_snapshot(channels: candidate));
  }

  int _channelHash(Uint8List secret) {
    final key16 = Uint8List(16);
    key16.setRange(0, secret.length.clamp(0, 16), secret);
    return CryptoUtils.sha256(key16)[0];
  }

  // -------------------------------------------------------------------------
  // Adverts
  // -------------------------------------------------------------------------

  @override
  Future<bool> advertise({bool flood = false}) async {
    if (_semanticBlocked) return false;
    final generation = _identityGeneration;
    final packet = await PacketBuilder.createAdvert(
      identity: identity,
      name: prefs.nodeName,
      lat: prefs.advertLocPolicy == advertLocNone ? 0.0 : prefs.latitude,
      lon: prefs.advertLocPolicy == advertLocNone ? 0.0 : prefs.longitude,
      flags: prefs.advType,
      flood: flood,
      timestamp: _nextVirtualTimestamp(),
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
    final prefsCopy = NodePrefs()..copyFrom(prefs);
    prefsCopy.nodeName = valid;
    await _commit(_snapshot(prefs: prefsCopy));
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
    final prefsCopy = NodePrefs()..copyFrom(prefs);
    prefsCopy
      ..latitude = latMicros / 1e6
      ..longitude = lonMicros / 1e6;
    await _commit(_snapshot(prefs: prefsCopy));
  }

  // -------------------------------------------------------------------------
  // Messaging
  // -------------------------------------------------------------------------

  /// Reject unicasts to the attached radio's own companion identity.
  ///
  /// The device transmits but does not receive its own raw TX, so such a
  /// message could never be acknowledged.
  void _ensureNotBlockedPeer(Uint8List pubkey) {
    if (localRouter?.isBlockedPeer(pubkey) ?? false) {
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
    bool waitForAck = false,
  }) async {
    if (_semanticBlocked) return const SentResult.failure();
    _ensureNotBlockedPeer(pubkey);
    final generation = _identityGeneration;
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final (packet, ackCrc) = await PacketBuilder.createTextMessage(
      contact: contact,
      identity: identity,
      message: text,
      attempt: attempt,
      txtType: txtType,
      timestamp: _nextVirtualTimestamp(),
    );
    if (!_identityCurrent(generation)) return const SentResult.failure();
    final flood = !contact.hasDirectRoute;
    // CLI data/commands are not acknowledged; don't track a pending ACK.
    final isCommand =
        txtType == txtTypeCliData || txtType == txtTypeCliCommand;
    _PendingAck? pending;
    if (!isCommand) {
      // Register before transmit: a synchronous local mirror can deliver the
      // ACK before the RF round-trip completes.
      final timer = Timer(ackTimeout, () {
        _pendingAcks.removeWhere((a) => a.crc == ackCrc);
      });
      pending = _PendingAck(ackCrc, contact.publicKey, timer);
      _pendingAcks.add(pending);
    }
    try {
      await _transmit(
        packet,
        flood: flood,
        scoped: true,
        identityGeneration: generation,
      );
    } catch (_) {
      if (pending != null) {
        pending.timer.cancel();
        _pendingAcks.remove(pending);
      }
      rethrow;
    }
    if (!_identityCurrent(generation)) {
      if (pending != null) {
        pending.timer.cancel();
        _pendingAcks.remove(pending);
      }
      return const SentResult.failure();
    }
    if (isCommand) {
      return SentResult(
        success: true,
        isFlood: flood,
        expectedAck: 0,
        timeoutMs: waitForAck ? ackTimeout.inMilliseconds : 5000,
      );
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: ackCrc,
      timeoutMs: waitForAck ? ackTimeout.inMilliseconds : 5000,
    );
  }

  @override
  Future<bool> sendChannelMessage(int channelIndex, String text) async {
    if (_semanticBlocked) return false;
    final generation = _identityGeneration;
    final channel = channels[channelIndex];
    if (channel == null) return false;
    final packet = PacketBuilder.createGroupText(
      channel: channel,
      message: text,
      senderName: prefs.nodeName,
      timestamp: _nextVirtualTimestamp(),
    );
    final hash = bytesToHex(packet.calculatePacketHash());
    _sentGroupPacketHashes.update(hash, (count) => count + 1,
        ifAbsent: () => 1);
    while (_sentGroupPacketHashes.length > _seenPacketMax) {
      _sentGroupPacketHashes.remove(_sentGroupPacketHashes.keys.first);
    }
    await _transmit(
      packet,
      flood: true,
      scoped: true,
      identityGeneration: generation,
    );
    return _identityCurrent(generation);
  }

  @override
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) async {
    if (_semanticBlocked) return false;
    final generation = _identityGeneration;
    final channel = channels[channelIndex];
    if (channel == null) return false;
    final pathLen = pathLenEncoded ?? 0xFF;
    final pathBytes = path ?? const <int>[];
    final flood = pathLen == 0xFF;
    if (flood) {
      if (pathBytes.isNotEmpty) return false;
    } else {
      if (!PathUtils.isValidPathLen(pathLen)) return false;
      if (pathBytes.length != PathUtils.getByteLength(pathLen)) return false;
    }
    if (dataType == dataTypeReserved) return false;
    if (payload.length > maxGroupDataLength) return false;
    // The whole SEND_CHANNEL_DATA payload must fit the companion frame, in
    // addition to the 165-byte radio-side group-data limit.
    final commandLength =
        5 + (flood ? 0 : pathBytes.length) + payload.length;
    if (commandLength > maxCompanionPayloadSize) return false;
    final packet = PacketBuilder.createGroupData(
      channel: channel,
      dataType: dataType,
      data: payload,
      path: pathBytes,
      pathLenEncoded: pathLen,
    );
    await _transmit(
      packet,
      flood: flood,
      scoped: true,
      identityGeneration: generation,
    );
    return _identityCurrent(generation);
  }

  @override
  Future<bool> sendControlData(Uint8List data) async {
    if (_semanticBlocked) return false;
    await _transmit(
      PacketBuilder.createControlData(data),
      flood: false,
      identityGeneration: _identityGeneration,
    );
    return !_semanticBlocked;
  }

  @override
  Future<QueuedMessage?> syncNextMessage() async {
    if (_messageQueue.isEmpty) return null;
    final candidate = [for (final m in _messageQueue) m.clone()];
    final msg = candidate.removeAt(0);
    await _commit(_snapshot(queue: candidate));
    return msg;
  }

  @override
  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) async {
    if (_semanticBlocked) return const SentResult.failure();
    _ensureNotBlockedPeer(pubkey);
    final generation = _identityGeneration;
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = _nextRequestTag();
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: data.isEmpty ? 0 : data[0],
      data: data.length > 1 ? data.sublist(1) : const [],
      timestamp: tag,
    );
    if (!_identityCurrent(generation)) return const SentResult.failure();
    final flood = !contact.hasDirectRoute;
    _pendingBinary[tag] = Uint8List.fromList(pubkey);
    try {
      await _transmit(packet, flood: flood, identityGeneration: generation);
    } catch (_) {
      _pendingBinary.remove(tag);
      rethrow;
    }
    if (!_identityCurrent(generation)) {
      _pendingBinary.remove(tag);
      return const SentResult.failure();
    }
    return SentResult(
        success: true, isFlood: flood, expectedAck: tag, timeoutMs: 10000);
  }

  @override
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) async {
    if (_semanticBlocked) return const SentResult.failure();
    _ensureNotBlockedPeer(pubkey);
    final generation = _identityGeneration;
    // Like the firmware, ensure a contact exists (a zero-hop one if unknown) so
    // the response can be decrypted and matched.
    var contact = getContactByKey(pubkey);
    if (contact == null) {
      try {
        contact = await _ensureAnonContact(pubkey);
      } on CompanionOperationError catch (e) {
        _storageDiagnostic = e.message;
        return const SentResult.failure();
      }
    }
    if (!_identityCurrent(generation)) return const SentResult.failure();
    final tag = _nextRequestTag();
    final flood = !contact.hasDirectRoute;
    final packet = await PacketBuilder.createAnonRequest(
      contact: contact,
      identity: identity,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    if (!_identityCurrent(generation)) return const SentResult.failure();
    _pendingBinary[tag] = Uint8List.fromList(pubkey);
    try {
      await _transmit(packet, flood: flood, identityGeneration: generation);
    } catch (_) {
      _pendingBinary.remove(tag);
      rethrow;
    }
    if (!_identityCurrent(generation)) {
      _pendingBinary.remove(tag);
      return const SentResult.failure();
    }
    return SentResult(
        success: true, isFlood: flood, expectedAck: tag, timeoutMs: 10000);
  }

  /// Virtual wall-clock seconds that advance when two packets share a second.
  int _nextVirtualTimestamp() {
    var ts = clock.wallSeconds;
    if (ts <= _lastPacketTimestamp) ts = _lastPacketTimestamp + 1;
    _lastPacketTimestamp = ts;
    return ts;
  }

  /// Virtual request tag that doesn't collide with an in-flight request.
  int _nextRequestTag() {
    var tag = clock.wallSeconds;
    if (tag <= _lastRequestTag) tag = _lastRequestTag + 1;
    while (_pendingBinary.containsKey(tag) ||
        _pendingTelemetry.containsKey(tag) ||
        _pendingDiscovery.containsKey(tag)) {
      tag++;
    }
    _lastRequestTag = tag;
    return tag;
  }

  /// Register a transient zero-hop contact for [pubkey] if one doesn't exist.
  ///
  /// The eight anonymous slots are separate from the persistent contact table:
  /// they never consume its capacity, appear in listings/info, or get persisted.
  Future<Contact> _ensureAnonContact(Uint8List pubkey) async {
    final hex = bytesToHex(pubkey);
    for (final c in _transientContacts) {
      if (c.publicKeyHex == hex) return c;
    }
    final contact = Contact(
      publicKey: Uint8List.fromList(pubkey),
      advType: advTypeNone,
      lastmod: clock.wallSeconds,
    );
    if (_transientContacts.length < maxTransientContacts) {
      _transientContacts.add(contact);
    } else {
      var oldestIdx = 0;
      for (var i = 1; i < _transientContacts.length; i++) {
        if (_transientContacts[i].lastmod <
            _transientContacts[oldestIdx].lastmod) {
          oldestIdx = i;
        }
      }
      _transientContacts[oldestIdx] = contact;
    }
    return contact;
  }

  @override
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async {
    if (_semanticBlocked) return const SentResult.failure();
    _ensureNotBlockedPeer(pubkey);
    final generation = _identityGeneration;
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = _nextRequestTag();
    final rng = Random.secure();
    // req_data = [type][inverse base-telemetry permission mask][3 reserved][4 random]
    final reqData = Uint8List.fromList([
      (~telemPermBase) & 0xFF,
      0,
      0,
      0,
      ...List<int>.generate(4, (_) => rng.nextInt(256)),
    ]);
    // Path discovery is a flooded telemetry request (firmware forces flood).
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetTelemetryData,
      data: reqData,
      timestamp: tag,
      flood: true,
    );
    if (!_identityCurrent(generation)) return const SentResult.failure();
    _pendingDiscovery[tag] = Uint8List.fromList(pubkey);
    try {
      await _transmit(packet, flood: true, identityGeneration: generation);
    } catch (_) {
      _pendingDiscovery.remove(tag);
      rethrow;
    }
    if (!_identityCurrent(generation)) {
      _pendingDiscovery.remove(tag);
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: true,
      expectedAck: tag,
      timeoutMs: 15000,
    );
  }

  @override
  Future<SentResult> sendTelemetryRequest(
    Uint8List pubkey, {
    bool wantBase = true,
    bool wantLocation = true,
    bool wantEnvironment = true,
  }) async {
    if (_semanticBlocked) return const SentResult.failure();
    _ensureNotBlockedPeer(pubkey);
    final generation = _identityGeneration;
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = _nextRequestTag();
    // The first payload byte is an inverse permissions mask: set the bits for
    // the telemetry classes we do *not* want.
    var inverse = 0;
    if (!wantBase) inverse |= telemPermBase;
    if (!wantLocation) inverse |= telemPermLocation;
    if (!wantEnvironment) inverse |= telemPermEnvironment;
    final flood = !contact.hasDirectRoute;
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetTelemetryData,
      data: [inverse & 0xFF],
      timestamp: tag,
      flood: flood,
    );
    if (!_identityCurrent(generation)) return const SentResult.failure();
    _pendingTelemetry[tag] = Uint8List.fromList(pubkey);
    try {
      await _transmit(packet, flood: flood, identityGeneration: generation);
    } catch (_) {
      _pendingTelemetry.remove(tag);
      rethrow;
    }
    if (!_identityCurrent(generation)) {
      _pendingTelemetry.remove(tag);
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: 10000,
    );
  }

  @override
  Future<bool> sendTracePathRaw(
    int tag,
    int authCode,
    int flags,
    Uint8List pathBytes,
  ) async {
    if (_semanticBlocked) return false;
    final generation = _identityGeneration;
    final packet = PacketBuilder.createTrace(
      tag: tag,
      authCode: authCode,
      flags: flags,
      path: pathBytes,
    );
    await _transmit(packet, flood: false, identityGeneration: generation);
    return _identityCurrent(generation);
  }

  @override
  Future<bool> sendRawData(
    Uint8List payload,
    Uint8List path,
    int pathLenByte,
  ) async {
    if (_semanticBlocked) return false;
    final generation = _identityGeneration;
    final packet = PacketBuilder.createRawCustom(
      payload,
      path: path,
      encodedPathLen: pathLenByte,
    );
    await _transmit(packet, flood: false, identityGeneration: generation);
    return _identityCurrent(generation);
  }

  @override
  Future<bool> sendRawPacket(Packet packet, int priority) async {
    if (_semanticBlocked) return false;
    final generation = _identityGeneration;
    // Transmitted verbatim; route type and path come from the packet itself.
    await _transmit(
      packet,
      flood: packet.isRouteFlood,
      preservePath: true,
      priority: priority,
      identityGeneration: generation,
    );
    return _identityCurrent(generation);
  }

  @override
  Future<SentResult> sendLogin(Uint8List pubkey, String password) async {
    if (_semanticBlocked) return const SentResult.failure();
    _ensureNotBlockedPeer(pubkey);
    final generation = _identityGeneration;
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = _nextRequestTag();
    final pw = utf8.encode(password);
    final pwTrimmed = pw.length > 15 ? pw.sublist(0, 15) : pw;
    // Room servers take a sync cursor before the password.
    final List<int> data = contact.advType == advTypeRoom
        ? [
            ...(BufferWriter()..writeUInt32Le(contact.syncSince)).toBytes(),
            ...pwTrimmed,
          ]
        : pwTrimmed;
    final flood = !contact.hasDirectRoute;
    final packet = await PacketBuilder.createAnonRequest(
      contact: contact,
      identity: identity,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    if (!_identityCurrent(generation)) return const SentResult.failure();
    _pendingLogin = Uint8List.fromList(pubkey.sublist(0, 4));
    try {
      await _transmit(packet, flood: flood, identityGeneration: generation);
    } catch (_) {
      _pendingLogin = null;
      rethrow;
    }
    if (!_identityCurrent(generation)) {
      _pendingLogin = null;
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: 15000,
    );
  }

  @override
  Future<SentResult> sendStatusReq(Uint8List pubkey) async {
    if (_semanticBlocked) return const SentResult.failure();
    _ensureNotBlockedPeer(pubkey);
    final generation = _identityGeneration;
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = _nextRequestTag();
    final rng = Random.secure();
    final data = Uint8List.fromList([
      0, 0, 0, 0,
      ...List<int>.generate(4, (_) => rng.nextInt(256)),
    ]);
    final flood = !contact.hasDirectRoute;
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetStatus,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    if (!_identityCurrent(generation)) return const SentResult.failure();
    _pendingStatus = Uint8List.fromList(pubkey.sublist(0, 4));
    try {
      await _transmit(packet, flood: flood, identityGeneration: generation);
    } catch (_) {
      _pendingStatus = null;
      rethrow;
    }
    if (!_identityCurrent(generation)) {
      _pendingStatus = null;
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: 15000,
    );
  }

  @override
  bool logout(Uint8List pubkey) {
    final prefix = Uint8List.fromList(pubkey.sublist(0, 4));
    if (_pendingLogin != null && _bytesEqual(_pendingLogin!, prefix)) {
      _pendingLogin = null;
    }
    if (_pendingStatus != null && _bytesEqual(_pendingStatus!, prefix)) {
      _pendingStatus = null;
    }
    _stopKeepAlive(pubkey);
    return true;
  }

  @override
  bool hasConnection(Uint8List pubkey) =>
      _connections.containsKey(bytesToHex(pubkey));

  // -------------------------------------------------------------------------
  // Flood scope
  // -------------------------------------------------------------------------

  /// The scope key used for scoped floods: the override (unless unscoped) or
  /// the stored default scope. Zero/absent keys mean unset.
  Uint8List? _effectiveFloodScope() {
    if (_floodUnscoped) return null;
    final override = _floodScopeOverride;
    if (override != null && !_isZeroKey(override)) return override;
    final def = prefs.defaultScopeKey;
    if (def != null && def.length == 16 && !_isZeroKey(def)) return def;
    return null;
  }

  static bool _isZeroKey(Uint8List key) {
    for (final b in key) {
      if (b != 0) return false;
    }
    return true;
  }

  @override
  void setFloodScopeKey(Uint8List? key) {
    _floodScopeOverride = key == null ? null : Uint8List.fromList(key);
    _floodUnscoped = false;
  }

  @override
  void setFloodUnscoped() => _floodUnscoped = true;

  @override
  Future<void> setDefaultFloodScope(String name, Uint8List? key) async {
    final prefsCopy = NodePrefs()..copyFrom(prefs);
    prefsCopy
      ..defaultScopeName = name
      ..defaultScopeKey = key == null ? null : Uint8List.fromList(key);
    await _commit(_snapshot(prefs: prefsCopy));
  }

  @override
  (String, Uint8List?) getDefaultFloodScope() =>
      (prefs.defaultScopeName, prefs.defaultScopeKey);

  @override
  Future<void> reboot() async {
    // Dispatch first: a failure before the write must be reported, not hidden
    // behind a successful virtual cleanup.
    try {
      await link.reboot();
    } on DeviceCommandError catch (e) {
      _physicalDiagnostic = e.message ?? e.toString();
      throw _operationError(e);
    } catch (_) {
      throw const CompanionOperationError(
        errCodeBadState,
        message: 'reboot dispatch failed',
      );
    }

    _radioRequiresReboot = false;
    // A soft restart of the node engine: drop ephemeral runtime state while
    // keeping persisted prefs, contacts, channels and the queued messages.
    _clearIdentityRuntimeState();
    _lifecycleGeneration++;
  }

  /// Dispatch the physical `poweroff` CLI without waiting for a reply, then
  /// stop semantic TX/RX until an explicit start/new connection.
  Future<void> shutdown() async {
    if (_poweredOff) return;
    if (physical.firmwareVerCode < 14) {
      throw const CompanionOperationError(
        errCodeUnsupportedCmd,
        message: 'physical firmware does not support shutdown',
      );
    }
    _poweredOff = true;
    try {
      await link.shutdown();
    } on DeviceCommandError catch (e) {
      _poweredOff = false;
      _physicalDiagnostic = e.message ?? e.toString();
      throw _operationError(e);
    } catch (_) {
      _poweredOff = false;
      throw const CompanionOperationError(
        errCodeBadState,
        message: 'shutdown dispatch failed',
      );
    }

    _radioRequiresReboot = false;
    _clearIdentityRuntimeState();
    _lifecycleGeneration++;
    battery.stop();
    link.setRawRxListener(null);
    try {
      await onPoweredOff?.call();
    } catch (_) {
      _physicalDiagnostic = 'poweroff state notification failed';
    }
  }

  void _startKeepAlive(Uint8List pubkey, int keepAliveSecs) {
    if (keepAliveSecs <= 0) return;
    final key = bytesToHex(pubkey);
    final conn = _connections.putIfAbsent(
      key,
      () => _Connection(
          Uint8List.fromList(pubkey), Duration(seconds: keepAliveSecs)),
    );
    conn.interval = Duration(seconds: keepAliveSecs);
    conn.lastActivity = clock.monotonicSeconds;
    conn.timer?.cancel();
    conn.timer =
        Timer.periodic(conn.interval, (_) => unawaited(_sendKeepAlive(conn)));
  }

  void _stopKeepAlive(Uint8List pubkey) {
    _connections.remove(bytesToHex(pubkey))?.stop();
  }

  /// Diagnostic/test hook: send a keep-alive request now for every active
  /// connection without waiting for the interval timer.
  Future<void> sendKeepAlivesNow() async {
    for (final conn in _connections.values.toList()) {
      await _sendKeepAlive(conn);
    }
  }

  void _markConnectionActive(Uint8List pubkey) {
    final conn = _connections[bytesToHex(pubkey)];
    if (conn != null) {
      conn.lastActivity = clock.monotonicSeconds;
    }
  }

  Future<void> _sendKeepAlive(_Connection conn) async {
    // A queued timer callback from the previous identity must not transmit or
    // recreate a session after an identity switch.
    if (_semanticBlocked || !_connections.containsValue(conn)) return;
    final generation = _identityGeneration;
    final now = clock.monotonicSeconds;
    final expire = conn.lastActivity + (conn.interval.inSeconds * 5 ~/ 2);
    if (now >= expire) {
      _connections.remove(bytesToHex(conn.pubkey));
      conn.stop();
      return;
    }
    final contact = getContactByKey(conn.pubkey);
    if (contact == null) {
      _connections.remove(bytesToHex(conn.pubkey));
      conn.stop();
      return;
    }
    // Keep-alive is only usable once we know the direct path to the server.
    if (!contact.hasDirectRoute) return;

    const syncSince = 0;
    final timestamp = _nextRequestTag();
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeKeepAlive,
      data: (BufferWriter()..writeUInt32Le(syncSince)).toBytes(),
      timestamp: timestamp,
      flood: false,
    );
    if (!_identityCurrent(generation) || !_connections.containsValue(conn)) {
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

  @override
  AdvertPath? getAdvertPath(Uint8List prefix) =>
      _advertPaths[bytesToHex(prefix)];

  @override
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
        timestamp: _nextVirtualTimestamp(),
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
    final generation = _identityGeneration;
    Timer.run(() => unawaited(_onAdvert(packet, generation)));
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
  // Radio configuration (pass-through)
  // -------------------------------------------------------------------------

  @override
  Future<void> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  }) {
    return _runConfig(() async {
      if (freqHz < 150000000 || freqHz > 2500000000) {
        throw _illegalArgument('frequency outside 150000-2500000 kHz');
      }
      if (bwHz < 7000 || bwHz > 500000) {
        throw _illegalArgument('bandwidth outside 7000-500000 Hz');
      }
      if (sf < 5 || sf > 12 || cr < 5 || cr > 8) {
        throw _illegalArgument('invalid spreading factor or coding rate');
      }

      var repeat = clientRepeat;
      if (physical.firmwareVerCode < 9) {
        if (repeat != null) {
          throw const CompanionOperationError(
            errCodeUnsupportedCmd,
            message: 'client repeat requires physical firmware v9+',
          );
        }
      } else if (repeat == null) {
        // Preserve the current physical repeat: query it fresh and send an
        // explicit 0/1 byte. If the query fails, do not write.
        try {
          final info = await link.deviceInfo();
          if (info.clientRepeat != 0 && info.clientRepeat != 1) {
            throw _illegalArgument('invalid physical client repeat');
          }
          repeat = info.clientRepeat == 1;
          physical = physical.copyWith(
            firmwareVerCode: info.firmwareVerCode,
            clientRepeat: info.clientRepeat,
            pathHashMode: info.pathHashMode,
          );
        } on DeviceCommandError catch (e) {
          // No write was attempted, so this is a query failure, not an
          // uncertain mutation.
          throw _queryError(e);
        }
      }

      final params = RadioParams(
        frequencyHz: freqHz,
        bandwidthHz: bwHz,
        spreadingFactor: sf,
        codingRate: cr,
        txPowerDbm: prefs.txPowerDbm,
      );
      try {
        await link.setRadioParams(params, clientRepeat: repeat);
      } on DeviceCommandError catch (e) {
        if (e.mayHaveApplied) {
          _radioCacheUncertain = true;
          _radioCacheVerified = false;
          _needsReconcile = true;
        }
        _physicalDiagnostic = e.message ?? e.toString();
        throw _operationError(e);
      }

      // The write was acknowledged: commit the confirmed requested values and
      // then attempt exactly one readback.
      prefs.frequencyHz = freqHz;
      prefs.bandwidthHz = bwHz;
      prefs.spreadingFactor = sf;
      prefs.codingRate = cr;
      if (repeat != null) {
        physical = physical.copyWith(clientRepeat: repeat ? 1 : 0);
      }
      _radioCacheUncertain = false;
      _radioCacheVerified = false;
      _physicalDiagnostic = null;
      _persist();
      await _readBackSelfInfo();
      _notifyPhysicalConfigChanged();
    });
  }

  @override
  Future<void> setTxPower(int dbm) {
    return _runConfig(() async {
      if (dbm < -9) {
        throw _illegalArgument('TX power below -9 dBm');
      }
      if (dbm > physical.maxTxPower) {
        throw _illegalArgument(
          'TX power $dbm exceeds physical maximum ${physical.maxTxPower}',
        );
      }
      try {
        await link.setTxPower(dbm);
      } on DeviceCommandError catch (e) {
        if (e.mayHaveApplied) {
          _radioCacheUncertain = true;
          _radioCacheVerified = false;
          _needsReconcile = true;
        }
        _physicalDiagnostic = e.message ?? e.toString();
        throw _operationError(e);
      }
      prefs.txPowerDbm = dbm;
      _radioCacheUncertain = false;
      _radioCacheVerified = false;
      _physicalDiagnostic = null;
      _persist();
      await _readBackSelfInfo();
      _notifyPhysicalConfigChanged();
    });
  }

  /// One bounded SELF_INFO readback after a confirmed physical write. Failure is
  /// diagnostic only: the write was acknowledged, so the caller still succeeds
  /// with the requested values marked unverified.
  Future<void> _readBackSelfInfo({bool markReconcile = true}) async {
    try {
      final info = await link.selfInfo();
      prefs.frequencyHz = info.radioParams.frequencyHz;
      prefs.bandwidthHz = info.radioParams.bandwidthHz;
      prefs.spreadingFactor = info.radioParams.spreadingFactor;
      prefs.codingRate = info.radioParams.codingRate;
      prefs.txPowerDbm = info.txPowerDbm;
      prefs.maxTxPower = info.maxTxPower;
      physical = physical.copyWith(maxTxPower: info.maxTxPower);
      _radioCacheUncertain = false;
      _radioCacheVerified = true;
      _needsReconcile = false;
      _physicalDiagnostic = null;
      _persist();
    } on DeviceCommandError catch (e) {
      _radioCacheVerified = false;
      _needsReconcile = markReconcile;
      _physicalDiagnostic = e.message ?? e.toString();
    }
  }

  /// Adopt the connected device's actual radio parameters as the node's own
  /// without re-configuring the device (used at attach/reconnect time).
  ///
  /// Only RF/TX values belong to the physical radio. Path-hash mode, name,
  /// location and other preferences are virtual state and are deliberately not
  /// adopted here.
  void syncRadioParams(RadioParams params) {
    prefs.frequencyHz = params.frequencyHz;
    prefs.bandwidthHz = params.bandwidthHz;
    prefs.spreadingFactor = params.spreadingFactor;
    prefs.codingRate = params.codingRate;
    prefs.txPowerDbm = params.txPowerDbm;
    _radioCacheUncertain = false;
    _radioCacheVerified = true;
    _needsReconcile = false;
    _physicalDiagnostic = null;
    _persist();
  }

  @override
  int getPathHashMode() => prefs.pathHashMode;

  /// Set the virtual path-hash mode. Modes 0/1/2 select a 1/2/3-byte hash on
  /// new virtual floods. This is virtual state only: the physical device's
  /// mode is never changed.
  @override
  Future<void> setPathHashMode(int mode) async {
    final prefsCopy = NodePrefs()..copyFrom(prefs);
    prefsCopy.pathHashMode = mode.clamp(0, 2);
    await _commit(_snapshot(prefs: prefsCopy));
  }

  @override
  Future<TuningParams> getTuningParams() {
    return _runConfig(() async {
      if (_needsReconcile) {
        _needsReconcile = false;
        await _readBackSelfInfo(markReconcile: false);
      }
      try {
        final params = await link.tuningParams();
        prefs.rxDelayBaseMs = params.rxDelayBaseMs;
        prefs.airtimeFactorMs = params.airtimeFactorMs;
        _hasTuningCache = true;
        _tuningCacheVerified = true;
        _physicalDiagnostic = null;
        _persist();
        return params;
      } on DeviceCommandError catch (e) {
        if (_hasTuningCache) {
          _tuningCacheVerified = false;
          _physicalDiagnostic = e.message ?? e.toString();
          return TuningParams(
            rxDelayBaseMs: prefs.rxDelayBaseMs,
            airtimeFactorMs: prefs.airtimeFactorMs,
          );
        }
        throw _queryError(e);
      }
    });
  }

  @override
  Future<void> setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) {
    return _runConfig(() async {
      final params = TuningParams(
        rxDelayBaseMs: rxDelayBaseMs,
        airtimeFactorMs: airtimeFactorMs,
      );
      try {
        await link.setTuningParams(params);
      } on DeviceCommandError catch (e) {
        if (e.mayHaveApplied) {
          _radioCacheUncertain = true;
          _radioCacheVerified = false;
          _needsReconcile = true;
        }
        _physicalDiagnostic = e.message ?? e.toString();
        throw _operationError(e);
      }

      prefs.rxDelayBaseMs = rxDelayBaseMs;
      prefs.airtimeFactorMs = airtimeFactorMs;
      _hasTuningCache = true;
      _tuningCacheVerified = false;
      _physicalDiagnostic = null;
      _persist();
      try {
        final readBack = await link.tuningParams();
        prefs.rxDelayBaseMs = readBack.rxDelayBaseMs;
        prefs.airtimeFactorMs = readBack.airtimeFactorMs;
        _tuningCacheVerified = true;
        _persist();
      } on DeviceCommandError catch (e) {
        _tuningCacheVerified = false;
        _needsReconcile = true;
        _physicalDiagnostic = e.message ?? e.toString();
      }
      _notifyPhysicalConfigChanged();
    });
  }

  @override
  Future<String?> runCliCommand(String command) async {
    try {
      return await _routeCli(CliParser.parseText(command));
    } on CliFormatException catch (e) {
      return _cliReply(e.prefix, 'Error: illegal argument');
    }
  }

  @override
  Future<String> runCliCommandBytes(Uint8List payload) async {
    try {
      return await _routeCli(CliParser.parseBytes(payload));
    } on CliFormatException catch (e) {
      return _cliReply(e.prefix, 'Error: illegal argument');
    }
  }

  Future<String> _routeCli(CliInvocation invocation) async {
    switch (invocation.target) {
      case CliTarget.unknown:
        return _cliReply(invocation.prefix, 'Unknown command');
      case CliTarget.disabled:
        return _cliReply(invocation.prefix, 'Error: disabled');
      case CliTarget.virtual:
        try {
          final reply = await _runVirtualCli(invocation.command);
          return _cliReply(invocation.prefix, reply);
        } on CompanionOperationError catch (e) {
          return _cliReply(invocation.prefix, _cliOperationError(e));
        }
      case CliTarget.physical:
        return _runPhysicalCli(invocation);
      case CliTarget.lifecycle:
        try {
          if (invocation.command == 'reboot') {
            await reboot();
          } else {
            await shutdown();
          }
          return _cliReply(invocation.prefix, 'OK');
        } on CompanionOperationError catch (e) {
          return _cliReply(invocation.prefix, _cliOperationError(e));
        }
    }
  }

  String _cliReply(String? prefix, String text, {bool secret = false}) =>
      CliParser.boundReply(prefix, text, secret: secret);

  String _cliOperationError(CompanionOperationError e) {
    if (e.disabled) return 'Error: disabled';
    return switch (e.code) {
      errCodeFileIoError || errCodeTableFull => 'Error: storage failure',
      errCodeBadState => 'Error: device unavailable',
      errCodeIllegalArg => 'Error: illegal argument',
      _ => 'Error: unsupported',
    };
  }

  String _cliDeviceError(DeviceCommandError e) => switch (e.kind) {
        DeviceCommandErrorKind.disabled => 'Error: disabled',
        DeviceCommandErrorKind.unsupported => 'Error: unsupported',
        DeviceCommandErrorKind.timeout ||
        DeviceCommandErrorKind.disconnected ||
        DeviceCommandErrorKind.malformed =>
          'Error: device unavailable',
        DeviceCommandErrorKind.device => switch (e.code) {
            errCodeIllegalArg => 'Error: illegal argument',
            errCodeUnsupportedCmd => 'Error: unsupported',
            errCodeFileIoError => 'Error: storage failure',
            errCodeBadState => 'Error: device unavailable',
            _ => 'Error: device error',
          },
      };

  Future<String> _runVirtualCli(String command) async {
    switch (command) {
      case 'get name':
        return '> ${prefs.nodeName}';
      case 'get path.hash.mode':
        return '> ${prefs.pathHashMode}';
      case 'get multi.acks':
        return '> ${prefs.multiAcks}';
      case 'get tz.offset':
        return '> ${prefs.timezoneOffsetHours}';
      case 'board':
        return virtualBoardName;
      case 'ver':
        return virtualCliVersion;
    }

    if (command.startsWith('set name ')) {
      final name = command.substring(9);
      if (!_validCliName(name)) return 'Error, bad chars';
      await setAdvertName(name);
      return 'OK';
    }
    if (command.startsWith('set path.hash.mode ')) {
      final mode = _strictCliInt(command.substring(19));
      if (mode == null || mode < 0 || mode > 2) {
        return 'Error, must be 0,1, or 2';
      }
      await setPathHashMode(mode);
      return 'OK';
    }
    if (command.startsWith('set multi.acks ')) {
      final value = _strictCliInt(command.substring(15));
      if (value == null || value < 0 || value > 255) {
        return 'Error: illegal argument';
      }
      await setMultiAcks(value);
      return 'OK';
    }
    if (command.startsWith('set tz.offset ')) {
      final hours = _strictCliInt(command.substring(14));
      if (hours == null || hours < -12 || hours > 14) {
        return 'Error, must be from -12 to +14';
      }
      await setTimezoneOffsetHours(hours);
      return 'OK';
    }

    return 'Unknown command';
  }

  bool _validCliName(String value) {
    if (value.isEmpty || utf8.encode(value).length > 31) return false;
    const forbidden = '[]\\:,?*';
    if (value.runes.any((r) => forbidden.runes.contains(r))) return false;
    return validateAdvertName(value) != null;
  }

  static final RegExp _cliIntPattern = RegExp(r'^[+-]?[0-9]+$');

  int? _strictCliInt(String value) =>
      _cliIntPattern.hasMatch(value) ? int.tryParse(value) : null;

  Future<String> _runPhysicalCli(CliInvocation invocation) async {
    final CliPhysicalCommand spec;
    try {
      spec = CliPhysicalValidator.validate(
        invocation.command,
        maxTxPower: physical.maxTxPower,
      );
    } on CliFormatException {
      return _cliReply(invocation.prefix, 'Error: illegal argument');
    }
    if (physical.firmwareVerCode < 14) {
      return _cliReply(invocation.prefix, 'Error: unsupported');
    }

    try {
      final reply = await _runConfig(() async {
        final text = await link.runCliCommand(spec.command);
        await _refreshPhysicalCliCaches(spec, text);
        return text;
      });
      return _cliReply(invocation.prefix, reply, secret: spec.replyIsSecret);
    } on DeviceCommandError catch (e) {
      _physicalDiagnostic = e.message ?? e.toString();
      if (e.mayHaveApplied) {
        if (spec.refreshRadio) {
          _radioCacheUncertain = true;
          _radioCacheVerified = false;
        }
        if (spec.refreshTuning) {
          _tuningCacheVerified = false;
        }
        _needsReconcile = true;
      }
      return _cliReply(invocation.prefix, _cliDeviceError(e));
    } on CompanionOperationError catch (e) {
      _physicalDiagnostic = e.message;
      return _cliReply(invocation.prefix, _cliOperationError(e));
    }
  }

  bool _cliTextIsError(String text) =>
      text.contains('Error') ||
      text.contains('ERROR') ||
      text.contains('Unknown command');

  Future<void> _refreshPhysicalCliCaches(
    CliPhysicalCommand spec,
    String reply,
  ) async {
    if (spec.savedRadio && !_cliTextIsError(reply)) {
      _radioRequiresReboot = true;
    }
    if (spec.refreshRadio) {
      await _readBackSelfInfo();
    }
    if (spec.refreshTuning) {
      await _refreshTuningCacheDirect();
    }
    if (spec.refreshRadio || spec.refreshTuning) {
      _notifyPhysicalConfigChanged();
    }
  }

  /// Bounded tuning readback for the physical CLI transaction. Unlike
  /// [getTuningParams], this must not recursively take the config lock.
  Future<void> _refreshTuningCacheDirect() async {
    try {
      final params = await link.tuningParams();
      prefs.rxDelayBaseMs = params.rxDelayBaseMs;
      prefs.airtimeFactorMs = params.airtimeFactorMs;
      _hasTuningCache = true;
      _tuningCacheVerified = true;
      _physicalDiagnostic = null;
      _persist();
    } on DeviceCommandError catch (e) {
      _tuningCacheVerified = false;
      _needsReconcile = true;
      _physicalDiagnostic = e.message ?? e.toString();
    }
  }

  @override
  Future<Uint8List> getAllowedRepeatFreq() async {
    try {
      return await link.getAllowedRepeatFreq();
    } on DeviceCommandError catch (e) {
      throw _queryError(e);
    }
  }

  @override
  Future<Map<String, Object?>> getStats(int statsType) async {
    switch (statsType) {
      case statsTypeCore:
        final batteryMv = await battery.refresh();
        final uptime = (clock.monotonicMilliseconds -
                _startedAtMonotonicMillis)
            .clamp(0, 0xFFFFFFFF) ~/
            1000;
        return {
          'battery_mv': batteryMv,
          'uptime_secs': uptime,
          'errors': _packetStats['recv_errors'] ?? 0,
          'queue_len': _messageQueue.length,
        };
      case statsTypeRadio:
        return {
          'noise_floor': 0,
          'last_rssi': _lastRxRssi,
          'last_snr_scaled': _lastRxSnrScaled,
          'tx_air_secs': _txAirMicros ~/ 1000000,
          'rx_air_secs': _rxAirMicros ~/ 1000000,
        };
      default:
        return Map<String, Object?>.from(_packetStats);
    }
  }

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
  }) async {
    // Suppress new semantic transmissions while an identity switch is paused
    // or identity storage is uncertain. Already-started sends are awaited by
    // the replacement path before the key changes.
    if (_semanticBlocked) return;
    if (identityGeneration != null &&
        !_identityCurrent(identityGeneration)) {
      return;
    }
    if (flood && !preservePath) {
      packet.path = Uint8List(0);
      packet.pathLenByte = PathUtils.encodePathLen(
        prefs.pathHashMode.clamp(0, 2) + 1,
        0,
      );
    }
    if (scoped && flood) {
      final scope = _effectiveFloodScope();
      if (scope != null) packet.applyFloodScope(scope);
    }
    _packetStats['sent'] = (_packetStats['sent'] ?? 0) + 1;
    _packetStats[flood ? 'flood_tx' : 'direct_tx'] =
        (_packetStats[flood ? 'flood_tx' : 'direct_tx'] ?? 0) + 1;
    final bytes = packet.writeTo();
    _txAirMicros += _airtimeMicrosFor(bytes.length);
    _activePhysicalTx++;
    try {
      await link.sendRawPacket(bytes, priority);
    } finally {
      _activePhysicalTx--;
      if (_activePhysicalTx == 0) {
        final idle = _physicalTxIdle;
        _physicalTxIdle = null;
        if (idle != null && !idle.isCompleted) idle.complete();
      }
    }
    await _mirrorOutbound(bytes);
  }

  Future<void> _mirrorOutbound(Uint8List bytes) async {
    final router = localRouter;
    if (router == null || _retired) return;
    try {
      await router.mirrorOutbound(
        bytes,
        fromPublicKey: identity.publicKey,
      );
      _localRoutingDiagnostic = null;
    } catch (e) {
      // A mirror failure must never turn a successful RF send into a failure.
      _localRoutingDiagnostic = 'local mirror failed: $e';
    }
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
  }) async {
    if (_semanticBlocked) return;
    final generation = _identityGeneration;
    if (!peerOrigin) {
      pushSink?.pushRawRxData(snr, rssi, raw);
      _rxAirMicros += _airtimeMicrosFor(raw.length);
    }
    final packet = Packet.readFrom(raw);
    if (packet == null) {
      _packetStats['recv_errors'] = (_packetStats['recv_errors'] ?? 0) + 1;
      return;
    }
    _packetStats['recv'] = (_packetStats['recv'] ?? 0) + 1;
    _packetStats[packet.isRouteFlood ? 'flood_rx' : 'direct_rx'] =
        (_packetStats[packet.isRouteFlood ? 'flood_rx' : 'direct_rx'] ?? 0) + 1;
    packet.snr = snr;
    packet.rssi = rssi;
    _lastRxRssi = rssi;
    _lastRxSnrScaled = (snr * 4).round();

    // Trace routes carry accumulated SNR bytes in the path field, not remaining
    // route hashes. The trace handler validates that the requested path is
    // complete before surfacing it.
    if (packet.payloadType == payloadTypeTrace) {
      _onTrace(packet);
      return;
    }

    // Control discovery raw packets preserve this path for diagnostics, but
    // semantic delivery at this endpoint requires a fully consumed direct route.
    // A local mirror copy is already at its final destination even when the
    // original packet still carries a direct path.
    final endpointConsumed =
        peerOrigin || packet.isRouteFlood || packet.pathHashCount == 0;
    if (!endpointConsumed) {
      // Stock endpoints can still observe early ACKs before the route is
      // consumed; everything else remains raw-logged only.
      switch (packet.payloadType) {
        case payloadTypeAck:
          _onAck(packet);
        case payloadTypeMultipart:
          _onMultipart(packet);
        default:
          break;
      }
      return;
    }

    switch (packet.payloadType) {
      case payloadTypeReq:
        await _onRequest(packet, generation);
      case payloadTypeRawCustom:
        _onRawCustom(packet);
      case payloadTypeAdvert:
        await _onAdvert(packet, generation);
      case payloadTypeTxtMsg:
        await _onDirectText(packet, generation);
      case payloadTypeGrpTxt:
        await _onGroupText(packet, generation, peerOrigin: peerOrigin);
      case payloadTypeGrpData:
        await _onGroupData(packet, generation);
      case payloadTypeControl:
        _onControlData(packet);
      case payloadTypeTrace:
        _onTrace(packet);
      case payloadTypeAck:
        _onAck(packet);
      case payloadTypeMultipart:
        _onMultipart(packet);
      case payloadTypePath:
        await _onPathReturn(packet, generation);
      case payloadTypeResponse:
        await _onResponse(packet, generation);
      default:
        break;
    }
  }

  Future<void> _onAdvert(Packet packet, int generation) async {
    if (packet.payload.length <
        pubKeySize + timestampSize + signatureSize + 1) {
      return;
    }
    if (!await PacketBuilder.verifyAdvert(packet.payload)) return;
    if (!_identityCurrent(generation)) return;
    final pubkey = Uint8List.fromList(packet.payload.sublist(0, pubKeySize));
    if (_bytesEqual(pubkey, identity.publicKey)) return;
    final ts = BufferReader(packet.payload.sublist(pubKeySize)).readUInt32Le();
    final appdata =
        packet.payload.sublist(pubKeySize + timestampSize + signatureSize);
    final decoded = PacketBuilder.decodeAdvertData(appdata);
    if (!decoded.valid || !decoded.hasName) return;
    final name = validateAdvertName(decoded.name);
    if (name == null) return;
    final now = clock.wallSeconds;
    final type = decoded.flags & 0x0F;

    // A matching anonymous slot is cleared before the normal new/update flow.
    final transientIdx = _transientContacts
        .indexWhere((c) => c.publicKeyHex == bytesToHex(pubkey));
    if (transientIdx >= 0) {
      if (ts <= _transientContacts[transientIdx].lastAdvertTimestamp) return;
      _transientContacts.removeAt(transientIdx);
    }

    final existingIdx = contacts
        .indexWhere((c) => c.publicKeyHex == bytesToHex(pubkey));
    if (existingIdx >= 0) {
      final existing = contacts[existingIdx];
      if (ts <= existing.lastAdvertTimestamp) return;
      final updated = existing.clone()
        ..name = name
        ..advType = type
        ..lastAdvertTimestamp = ts
        ..lastmod = now
        ..rawAdvert = _normalizedAdvertBlob(packet);
      if (decoded.hasLocation) {
        updated
          ..gpsLat = decoded.lat
          ..gpsLon = decoded.lon;
      }
      final candidateContacts = [for (final c in contacts) c.clone()];
      candidateContacts[existingIdx] = updated;
      try {
        await _commit(
          _snapshot(
            contacts: candidateContacts,
            advertPaths: _advertPathCandidate(packet, pubkey, name, now),
          ),
          identityGeneration: generation,
        );
      } on CompanionOperationError catch (e) {
        _storageDiagnostic = e.message;
        return;
      }
      if (!_identityCurrent(generation)) return;
      pushSink?.pushAdvert(pubkey);
      return;
    }

    final newContact = Contact(
      publicKey: pubkey,
      name: name,
      advType: type,
      flags: 0,
      outPathLen: -1,
      lastAdvertTimestamp: ts,
      lastmod: now,
      gpsLat: decoded.hasLocation ? decoded.lat : 0.0,
      gpsLon: decoded.hasLocation ? decoded.lon : 0.0,
      rawAdvert: _normalizedAdvertBlob(packet),
    );
    final pathCache = _advertPathCandidate(packet, pubkey, name, now);

    if (!_shouldAutoAddType(type) || !_hopAllowed(packet.pathHashCount)) {
      // Discovery only: no persistent contact, but remember the inbound path.
      try {
        await _commit(
          _snapshot(advertPaths: pathCache),
          identityGeneration: generation,
        );
      } on CompanionOperationError catch (e) {
        _storageDiagnostic = e.message;
      }
      if (!_identityCurrent(generation)) return;
      pushSink?.pushNewAdvert(_contactFrameBody(newContact));
      return;
    }

    final candidateContacts = [for (final c in contacts) c.clone()];
    Contact? evicted;
    if (candidateContacts.length >= virtualMaxContacts) {
      final overwrite = _oldestOverwritableIndex(candidateContacts);
      if (overwrite < 0) {
        try {
          await _commit(
            _snapshot(advertPaths: pathCache),
            identityGeneration: generation,
          );
        } on CompanionOperationError catch (e) {
          _storageDiagnostic = e.message;
        }
        if (!_identityCurrent(generation)) return;
        pushSink?.pushNewAdvert(_contactFrameBody(newContact));
        pushSink?.pushContactsFull();
        return;
      }
      evicted = candidateContacts[overwrite];
      candidateContacts[overwrite] = newContact;
    } else {
      candidateContacts.add(newContact);
    }

    try {
      await _commit(
        _snapshot(
          contacts: candidateContacts,
          advertPaths: pathCache,
        ),
        identityGeneration: generation,
      );
    } on CompanionOperationError catch (e) {
      _storageDiagnostic = e.message;
      if (!_identityCurrent(generation)) return;
      if (e.code == errCodeTableFull) {
        // Virtual quota is a full-table condition for auto-add discovery.
        pushSink?.pushNewAdvert(_contactFrameBody(newContact));
        pushSink?.pushContactsFull();
      }
      return;
    }
    if (!_identityCurrent(generation)) return;
    if (evicted != null) {
      _forgetContactState(evicted.publicKey);
      pushSink?.pushContactDeleted(evicted.publicKey);
    }
    // Pinned BaseChatMesh behavior: a stored new candidate pushes ADVERT (0x80),
    // while NEW_ADVERT (0x8A) is reserved for discovered-but-not-stored ones.
    pushSink?.pushAdvert(pubkey);
  }

  Future<void> _onDirectText(Packet packet, int generation) async {
    if (packet.payload.length < 2) return;
    if (packet.payload[0] != _selfHash) return; // not addressed to us
    final srcHash = packet.payload[1];
    final decrypted = await _decryptFromSource(
      srcHash,
      packet.payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
    if (plaintext.length < 5) return;
    final r = BufferReader(plaintext);
    final ts = r.readUInt32Le();
    final flagsByte = r.readByte();
    final txtType = (flagsByte >> 2) & 0x3F;

    // Signed messages carry a 4-byte sender prefix before the text.
    late String text;
    Uint8List? rawCommand;
    late Uint8List ackBytes;
    if (txtType == txtTypeSigned) {
      if (plaintext.length < 9) return;
      r.skipBytes(4); // sender prefix (informational)
      text = r.readCString();
      // Track the room-server sync cursor (highest signed timestamp seen).
      if (ts > sender.syncSince) {
        sender.syncSince = ts;
        _persist();
      }
      final textLen = utf8.encode(text).length;
      final end = (9 + textLen).clamp(0, plaintext.length);
      // The firmware ACKs signed messages with
      // sha256(plaintext up to the text end | self pubkey).
      ackBytes = Uint8List.fromList(
          CryptoUtils.sha256(
                  [...plaintext.sublist(0, end), ...identity.publicKey])
              .sublist(0, 4));
    } else {
      if (txtType == txtTypeCliCommand) {
        rawCommand = _readCStringBytes(plaintext, r.position);
      }
      text = r.readCString();
      final textBytes = utf8.encode(text);
      final hash = PacketBuilder.ackHash(
        timestamp: ts,
        flagsByte: flagsByte,
        text: textBytes,
        senderPubkey: sender.publicKey,
      );
      // Plain ACKs append the extended-attempt byte (the byte after the text's
      // NUL) and one random byte; do not truncate them back to four bytes.
      final extendedIndex = 5 + textBytes.length + 1;
      final extendedAttempt =
          extendedIndex < plaintext.length ? plaintext[extendedIndex] : 0;
      ackBytes = Uint8List.fromList([
        ...hash,
        extendedAttempt,
        Random.secure().nextInt(256),
      ]);
    }

    // Only plain and signed messages are acknowledged; CLI data/commands are
    // not. ACKs are scheduled as endpoint transmissions (never forwarded).
    if (!_identityCurrent(generation)) return;
    final expectsAck = txtType == txtTypePlain || txtType == txtTypeSigned;
    if (expectsAck) {
      _scheduleTextAck(packet, sender, await identity.sharedSecret(sender.publicKey), ackBytes);
    }

    // Deduplicate before any remote CLI side effect. Duplicate reception of
    // plain/signed messages is still ACKed above but not queued twice.
    if (_isDuplicate(packet.calculatePacketHash())) return;

    if (txtType == txtTypeCliCommand) {
      if (_isPersistentContact(sender) && (sender.flags & 0x10) != 0) {
        await _handleRemoteCli(
          sender,
          ts,
          rawCommand ?? Uint8List.fromList(utf8.encode(text)),
          generation,
        );
        return;
      }
      // No 0x10 permission: preserve stock behavior by queueing the command
      // unchanged, with no execution and no automatic reply.
    }

    await _enqueueMessage(
      QueuedMessage(
        senderKey: sender.publicKey,
        txtType: txtType,
        timestamp: ts,
        text: text,
        snr: packet.snr,
        rssi: packet.rssi,
      ),
      identityGeneration: generation,
    );
  }

  Uint8List _readCStringBytes(Uint8List data, int start) {
    final out = <int>[];
    for (var i = start; i < data.length; i++) {
      if (data[i] == 0) break;
      out.add(data[i]);
    }
    return Uint8List.fromList(out);
  }

  bool _isPersistentContact(Contact contact) {
    final hex = contact.publicKeyHex;
    return contacts.any((c) => c.publicKeyHex == hex);
  }

  /// Try every known contact whose first public-key byte matches [srcHash].
  /// Selecting the first hash match would let a 1-byte collision pick the wrong
  /// permission set or prevent decryption of the real sender.
  Future<(Contact, Uint8List)?> _decryptFromSource(
    int srcHash,
    Uint8List ciphertext,
    int generation,
  ) async {
    for (final contact in _allContacts) {
      if (contact.publicKey.isEmpty || contact.publicKey[0] != srcHash) {
        continue;
      }
      final secret = await identity.sharedSecret(contact.publicKey);
      if (!_identityCurrent(generation)) return null;
      try {
        final plaintext = CryptoUtils.macThenDecrypt(
          secret.sublist(0, 16),
          secret,
          ciphertext,
        );
        if (!_identityCurrent(generation)) return null;
        return (contact, plaintext);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<void> _handleRemoteCli(
    Contact sender,
    int requestTimestamp,
    Uint8List commandBytes,
    int generation,
  ) async {
    String reply;
    String? prefix;
    try {
      final invocation = CliParser.parseBytes(commandBytes);
      prefix = invocation.prefix;
      final denial = CliRemotePolicy.denialFor(invocation);
      if (denial != null) {
        reply = denial;
      } else {
        reply = await _runVirtualCli(invocation.command);
      }
    } on CliFormatException catch (e) {
      prefix = e.prefix;
      reply = 'Error: illegal argument';
    } on CompanionOperationError catch (e) {
      reply = _cliOperationError(e);
    }
    if (!_identityCurrent(generation)) return;
    _scheduleCliReply(sender, requestTimestamp, _cliReply(prefix, reply),
        generation);
  }

  void _scheduleCliReply(
    Contact sender,
    int requestTimestamp,
    String reply,
    int generation,
  ) {
    if (!_identityCurrent(generation)) return;
    _scheduleAck(const Duration(milliseconds: 600), () {
      unawaited(_sendCliReply(sender, requestTimestamp, reply, generation));
    });
  }

  Future<void> _sendCliReply(
    Contact sender,
    int requestTimestamp,
    String reply,
    int generation,
  ) async {
    if (!_identityCurrent(generation) || _semanticBlocked) return;
    var timestamp = clock.wallSeconds;
    if (timestamp <= requestTimestamp) timestamp = requestTimestamp + 1;
    if (timestamp <= _lastPacketTimestamp) timestamp = _lastPacketTimestamp + 1;
    _lastPacketTimestamp = timestamp;
    final (packet, _) = await PacketBuilder.createTextMessage(
      contact: sender,
      identity: identity,
      message: reply,
      txtType: txtTypeCliData,
      timestamp: timestamp,
    );
    if (!_identityCurrent(generation)) return;
    final flood = !sender.hasDirectRoute;
    await _transmit(
      packet,
      flood: flood,
      scoped: true,
      identityGeneration: generation,
    );
  }

  /// Endpoint ACK schedule (never the repeater forwarding fan-out):
  /// * known direct route, multi_acks=0: ACK at 200ms
  /// * known direct route, multi_acks>0: ONE multipart ACK at 200ms, ACK at 500ms
  /// * unknown route: flooded ACK at 200ms
  /// * received flooded: encrypted path-return ACK at 200ms
  void _scheduleTextAck(
    Packet packet,
    Contact sender,
    Uint8List secret,
    Uint8List ackBytes,
  ) {
    const firstDelay = Duration(milliseconds: 200);
    if (packet.isRouteFlood) {
      final pathReturn = PacketBuilder.createPathReturn(
        destHashByte: sender.publicKey[0],
        srcHashByte: identity.publicKey[0],
        secret: secret,
        path: packet.path,
        pathLenEncoded: packet.pathLenByte,
        extraType: payloadTypeAck,
        extra: ackBytes,
      );
      _scheduleAck(
        firstDelay,
        () => unawaited(_transmit(pathReturn, flood: true, scoped: true)),
      );
      return;
    }

    final ack = PacketBuilder.createAckPacket(ackBytes);
    if (!sender.hasDirectRoute) {
      ack.header = (ack.header & ~phRouteMask) | routeTypeFlood;
      _scheduleAck(
        firstDelay,
        () => unawaited(_transmit(ack, flood: true, scoped: true)),
      );
      return;
    }

    ack.setPath(sender.outPath, sender.outPathLen);
    if (prefs.multiAcks > 0) {
      final multi = PacketBuilder.createMultiAck(ackBytes, 1)
        ..setPath(sender.outPath, sender.outPathLen);
      _scheduleAck(
        firstDelay,
        () => unawaited(_transmit(multi, flood: false)),
      );
      _scheduleAck(
        const Duration(milliseconds: 500),
        () => unawaited(_transmit(ack, flood: false)),
      );
    } else {
      _scheduleAck(
        firstDelay,
        () => unawaited(_transmit(ack, flood: false)),
      );
    }
  }

  Future<void> _onGroupText(
    Packet packet,
    int generation, {
    bool peerOrigin = false,
  }) async {
    if (packet.payload.length < 3) return;
    final channelHash = packet.payload[0];
    Channel? channel;
    int? channelIdx;
    channels.forEach((idx, ch) {
      if (_channelHash(ch.secret) == channelHash) {
        channel = ch;
        channelIdx = idx;
      }
    });
    if (channel == null) return;
    final ch = channel!;
    final secret = Uint8List(32);
    secret.setRange(0, ch.secret.length.clamp(0, 32), ch.secret);
    late Uint8List plaintext;
    try {
      plaintext = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        packet.payload.sublist(1),
      );
    } catch (_) {
      return;
    }
    final packetHash = bytesToHex(packet.calculatePacketHash());
    final sentCount = _sentGroupPacketHashes[packetHash];
    if (sentCount != null) {
      if (sentCount == 1) {
        _sentGroupPacketHashes.remove(packetHash);
      } else {
        _sentGroupPacketHashes[packetHash] = sentCount - 1;
      }
      return;
    }
    if (plaintext.length < 5) return;
    final r = BufferReader(plaintext);
    final ts = r.readUInt32Le();
    r.skipBytes(1); // flags
    final text = r.readCString();
    // Raw RX is forwarded separately for path/repeat tracking; don't queue our
    // own channel TX as a new incoming message. A locally mirrored peer copy is
    // not our own TX even when both identities share a display name.
    if (!peerOrigin && text.startsWith('${prefs.nodeName}: ')) return;
    if (!_identityCurrent(generation)) return;
    if (_isDuplicate(packet.calculatePacketHash())) return;
    await _enqueueMessage(
      QueuedMessage(
        senderKey: Uint8List(32),
        timestamp: ts,
        text: text,
        isChannel: true,
        channelIdx: channelIdx ?? 0,
        pathLen: packet.isRouteFlood ? packet.pathLenByte : 0xFF,
        snr: packet.snr,
        rssi: packet.rssi,
      ),
      identityGeneration: generation,
    );
  }

  Future<void> _onGroupData(Packet packet, int generation) async {
    if (packet.payload.length < 4) return;
    final channelHash = packet.payload[0];
    Channel? channel;
    int? channelIdx;
    channels.forEach((idx, ch) {
      if (_channelHash(ch.secret) == channelHash) {
        channel = ch;
        channelIdx = idx;
      }
    });
    if (channel == null) return;
    final ch = channel!;
    final secret = Uint8List(32);
    secret.setRange(0, ch.secret.length.clamp(0, 32), ch.secret);
    late Uint8List plaintext;
    try {
      plaintext = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        packet.payload.sublist(1),
      );
    } catch (_) {
      return;
    }
    if (plaintext.length < 3) return;
    final dataType = plaintext[0] | (plaintext[1] << 8);
    final dataLen = plaintext[2];
    if (dataType == dataTypeReserved ||
        dataLen > maxChannelDataLength ||
        plaintext.length < 3 + dataLen) {
      return;
    }
    if (!_identityCurrent(generation)) return;
    if (_isDuplicate(packet.calculatePacketHash())) return;
    await _enqueueMessage(
      QueuedMessage(
        senderKey: Uint8List(32),
        isChannel: true,
        channelIdx: channelIdx ?? 0,
        pathLen: packet.isRouteFlood ? packet.pathLenByte : 0xFF,
        snr: packet.snr,
        rssi: packet.rssi,
        channelDataType: dataType,
        channelDataPayload: Uint8List.fromList(
          plaintext.sublist(3, 3 + dataLen),
        ),
      ),
      identityGeneration: generation,
    );
  }

  Future<void> _onRequest(Packet packet, int generation) async {
    if (packet.payload.length < 2) return;
    if (packet.payload[0] != _selfHash) return;
    final decrypted = await _decryptFromSource(
      packet.payload[1],
      packet.payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
    // tag u32 + protocol code are the minimum request body.
    if (plaintext.length < 5) return;
    final tag = BufferReader(plaintext).readUInt32Le();
    final protocolCode = plaintext[4];
    if (protocolCode != reqTypeGetTelemetryData) return;
    // Validate the inverse-mask byte before reading it.
    if (plaintext.length < 6) return;
    final inverseMask = plaintext[5];
    if (!_isPersistentContact(sender)) return;

    final permissions = _grantedTelemetryPermissions(sender, inverseMask);
    if ((permissions & telemPermBase) == 0) return;

    final millivolts = await battery.refresh(force: true);
    if (!_identityCurrent(generation)) return;
    final lpp = _encodeTelemetryLpp(
      millivolts,
      includeLocation: (permissions & telemPermLocation) != 0,
    );
    final reply = Uint8List.fromList([
      ...(BufferWriter()..writeUInt32Le(tag)).toBytes(),
      ...lpp,
    ]);
    final senderCopy = sender.clone();
    final requestPath = Uint8List.fromList(packet.path);
    final requestPathLen = packet.pathLenByte;
    final requestWasFlood = packet.isRouteFlood;
    _scheduleAck(const Duration(milliseconds: 300), () {
      unawaited(_sendTelemetryReply(
        senderCopy,
        reply,
        requestWasFlood: requestWasFlood,
        requestPath: requestPath,
        requestPathLen: requestPathLen,
        generation: generation,
      ));
    });
  }

  int _grantedTelemetryPermissions(Contact sender, int inverseMask) {
    var permissions = 0;
    final baseFlag = (sender.flags & 0x02) != 0;
    final locationFlag = (sender.flags & 0x04) != 0;
    final envFlag = (sender.flags & 0x08) != 0;
    if (prefs.telemetryModeBase == teleModeAllowAll ||
        (prefs.telemetryModeBase == teleModeAllowFlags && baseFlag)) {
      permissions |= telemPermBase;
    }
    if (prefs.telemetryModeLocation == teleModeAllowAll ||
        (prefs.telemetryModeLocation == teleModeAllowFlags && locationFlag)) {
      permissions |= telemPermLocation;
    }
    if (prefs.telemetryModeEnvironment == teleModeAllowAll ||
        (prefs.telemetryModeEnvironment == teleModeAllowFlags && envFlag)) {
      permissions |= telemPermEnvironment;
    }
    return permissions & (~inverseMask & 0xFF);
  }

  Uint8List _encodeTelemetryLpp(
    int millivolts, {
    required bool includeLocation,
  }) {
    final w = BufferWriter()
      ..writeByte(telemChannelSelf)
      ..writeByte(0x74) // CayenneLPP voltage, 0.01 V
      ..writeUInt16Be((millivolts / 10).round().clamp(0, 0xFFFF));
    if (includeLocation) {
      w
        ..writeByte(telemChannelSelf)
        ..writeByte(0x88); // CayenneLPP GPS
      _writeSigned24(w, (prefs.latitude * 10000).round());
      _writeSigned24(w, (prefs.longitude * 10000).round());
      _writeSigned24(w, 0); // altitude
    }
    return w.toBytes();
  }

  void _writeSigned24(BufferWriter w, int value) {
    final clamped = value.clamp(-0x800000, 0x7FFFFF);
    final encoded = clamped < 0 ? clamped + 0x1000000 : clamped;
    w
      ..writeByte((encoded >> 16) & 0xFF)
      ..writeByte((encoded >> 8) & 0xFF)
      ..writeByte(encoded & 0xFF);
  }

  Future<void> _sendTelemetryReply(
    Contact sender,
    Uint8List data, {
    required bool requestWasFlood,
    required Uint8List requestPath,
    required int requestPathLen,
    required int generation,
  }) async {
    if (!_identityCurrent(generation) || _semanticBlocked) return;
    if (requestWasFlood) {
      final secret = await identity.sharedSecret(sender.publicKey);
      if (!_identityCurrent(generation)) return;
      final pathReturn = PacketBuilder.createPathReturn(
        destHashByte: sender.publicKey[0],
        srcHashByte: identity.publicKey[0],
        secret: secret,
        path: requestPath,
        pathLenEncoded: requestPathLen,
        extraType: payloadTypeResponse,
        extra: data,
      );
      await _transmit(
        pathReturn,
        flood: true,
        scoped: true,
        identityGeneration: generation,
      );
      return;
    }

    final flood = !sender.hasDirectRoute;
    final response = await PacketBuilder.createProtocolResponse(
      contact: sender,
      identity: identity,
      data: data,
      flood: flood,
    );
    if (!_identityCurrent(generation)) return;
    await _transmit(
      response,
      flood: flood,
      scoped: flood,
      identityGeneration: generation,
    );
  }

  void _onControlData(Packet packet) {
    if (packet.payload.isEmpty) return;
    // Discovery/probe control payloads are zero-hop direct. Flooded or
    // still-in-transit control data is not delivered as a local discovery event.
    if (!packet.isRouteDirect || packet.pathHashCount != 0) return;
    if (_isDuplicate(packet.calculatePacketHash())) return;
    pushSink?.pushControlData(
      packet.snr,
      packet.rssi,
      packet.pathLenByte,
      packet.payload,
    );
  }

  void _onRawCustom(Packet packet) {
    // Raw custom delivery is direct-route zero-hop only. Flooded/raw-in-transit
    // packets remain available through the full 0x88 raw RX log.
    if (!packet.isRouteDirect || packet.pathHashCount != 0) return;
    if (_isDuplicate(packet.calculatePacketHash())) return;
    pushSink?.pushRawData(packet.snr, packet.rssi, packet.payload);
  }

  /// Handle a returned trace packet (`PAYLOAD_TYPE_TRACE`, route direct). The
  /// payload is `tag(4) + auth(4) + flags(1) + requested path hashes`; the
  /// routing path holds one accumulated SNR byte per hop. The proxy does not
  /// forward traces, so it only reports the result once the requested path has
  /// been fully consumed (the trace has returned to us).
  void _onTrace(Packet packet) {
    if (!packet.isRouteDirect) return;
    final payload = packet.payload;
    if (payload.length < 9) return;
    final r = BufferReader(payload);
    final tag = r.readUInt32Le();
    final authCode = r.readUInt32Le();
    final flags = r.readByte();
    final pathSz = flags & 0x03;
    final pathHashes = Uint8List.fromList(payload.sublist(9));
    final pathLen = pathHashes.length;

    final hopCount = packet.path.length;
    if ((hopCount << pathSz) < pathLen) return; // not the terminus

    final snrCount = pathLen >> pathSz;
    final pathSnrs = Uint8List.fromList(
      packet.path.sublist(0, snrCount.clamp(0, packet.path.length)),
    );
    final finalSnrByte = (packet.snr * 4).round().clamp(-128, 127) & 0xFF;
    pushSink?.pushTraceData(
      pathLen,
      flags,
      tag,
      authCode,
      pathHashes,
      pathSnrs,
      finalSnrByte,
    );
  }

  void _onAck(Packet packet) {
    if (packet.payload.length < 4) return;
    final crc = packet.payload[0] |
        (packet.payload[1] << 8) |
        (packet.payload[2] << 16) |
        (packet.payload[3] << 24);
    // Keep-alive ACKs are matched separately and not surfaced to the client.
    for (final conn in _connections.values) {
      if (conn.expectedAck != null && conn.expectedAck == (crc & 0xFFFFFFFF)) {
        conn.expectedAck = null;
        conn.lastActivity = clock.monotonicSeconds;
        return;
      }
    }
    _confirmAck(crc);
  }

  /// Handle a `PAYLOAD_TYPE_MULTIPART` packet. Only multipart ACKs are used by
  /// the firmware: the first byte is `remaining << 4 | PAYLOAD_TYPE_ACK` and the
  /// rest is the 4-byte ACK hash of an ordinary ACK.
  void _onMultipart(Packet packet) {
    if (packet.payload.length < 5) return;
    final innerType = packet.payload[0] & 0x0F;
    if (innerType != payloadTypeAck) return;
    final ackPacket = Packet()
      ..header = packet.header
      ..pathLenByte = packet.pathLenByte
      ..path = packet.path
      ..payload = Uint8List.fromList(packet.payload.sublist(1));
    _onAck(ackPacket);
  }

  void _confirmAck(int crc) {
    final idx = _pendingAcks.indexWhere((a) => a.crc == (crc & 0xFFFFFFFF));
    if (idx < 0) return;
    _pendingAcks.removeAt(idx).timer.cancel();
    pushSink?.pushSendConfirmed(crc & 0xFFFFFFFF);
  }

  /// Handle a returned-path packet (payload type `0x08`). The encrypted inner
  /// payload is `path_len | path | extra_type | extra`. When the extra is an
  /// ACK hash we confirm the pending send; the path is the route back to the
  /// sender, so we cache it for future direct sends.
  Future<void> _onPathReturn(Packet packet, int generation) async {
    final payload = packet.payload;
    if (payload.length < 2) return;
    if (payload[0] != _selfHash) return; // not addressed to us
    final srcHash = payload[1];
    final decrypted = await _decryptFromSource(
      srcHash,
      payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
    if (plaintext.isEmpty) return;
    final pathLenEncoded = plaintext[0];
    final pathByteLen = PathUtils.getByteLength(pathLenEncoded);
    final extraStart = 1 + pathByteLen;
    if (plaintext.length <= extraStart) return;
    final extraType = plaintext[extraStart];
    final extra = plaintext.sublist(extraStart + 1);

    if (pathByteLen > 0 && PathUtils.isValidPathLen(pathLenEncoded)) {
      sender.outPath = Uint8List.fromList(plaintext.sublist(1, extraStart));
      sender.outPathLen = pathLenEncoded;
      sender.lastmod = clock.wallSeconds;
      final isTransient =
          _transientContacts.any((c) => c.publicKeyHex == sender.publicKeyHex);
      if (!isTransient && _identityCurrent(generation)) {
        try {
          await addUpdateContact(sender, identityGeneration: generation);
        } on CompanionOperationError catch (e) {
          _storageDiagnostic = e.message;
        }
        if (!_identityCurrent(generation)) return;
        pushSink?.pushPathUpdated(sender.publicKey);
      }
    }
    if (!_identityCurrent(generation)) return;

    if (extraType == payloadTypeAck && extra.length >= 4) {
      final crc =
          extra[0] | (extra[1] << 8) | (extra[2] << 16) | (extra[3] << 24);
      _confirmAck(crc);
    } else if (extraType == payloadTypeResponse) {
      _dispatchResponse(
        sender.publicKey,
        extra,
        outPath: Uint8List.fromList(plaintext.sublist(1, extraStart)),
        outPathLen: pathLenEncoded,
        inPath: packet.path,
        inPathLen: packet.pathLenByte,
      );
    }
  }

  /// Handle a `PAYLOAD_TYPE_RESPONSE` datagram (a response to a request sent as
  /// a direct datagram rather than a returned-path packet).
  Future<void> _onResponse(Packet packet, int generation) async {
    final payload = packet.payload;
    if (payload.length < 2) return;
    if (payload[0] != _selfHash) return;
    final srcHash = payload[1];
    final decrypted = await _decryptFromSource(
      srcHash,
      payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
    _dispatchResponse(sender.publicKey, plaintext);
  }

  /// Route a request response (login/status/path-discovery) to the matching
  /// pending request. Returned-path responses also carry the learned paths.
  void _dispatchResponse(
    Uint8List senderPubkey,
    Uint8List data, {
    Uint8List? outPath,
    int? outPathLen,
    Uint8List? inPath,
    int? inPathLen,
  }) {
    if (data.length < 4) return;
    final tag = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    final prefix4 = Uint8List.fromList(senderPubkey.sublist(0, 4));
    _markConnectionActive(senderPubkey);

    final discoveryTarget = _pendingDiscovery[tag];
    if (outPath != null &&
        outPathLen != null &&
        inPath != null &&
        inPathLen != null &&
        discoveryTarget != null &&
        _bytesEqual(discoveryTarget, senderPubkey)) {
      _pendingDiscovery.remove(tag);
      pushSink?.pushPathDiscoveryResponse(
        Uint8List.fromList(senderPubkey.sublist(0, 6)),
        outPathLen,
        outPath,
        inPathLen,
        inPath,
      );
      return;
    }

    final telemetryTarget = _pendingTelemetry[tag];
    if (telemetryTarget != null &&
        _bytesEqual(telemetryTarget, senderPubkey) &&
        data.length > 4) {
      _pendingTelemetry.remove(tag);
      pushSink?.pushTelemetryResponse(
        Uint8List.fromList(senderPubkey.sublist(0, 6)),
        Uint8List.fromList(data.sublist(4)),
      );
      return;
    }

    final binaryTarget = _pendingBinary[tag];
    if (binaryTarget != null && _bytesEqual(binaryTarget, senderPubkey)) {
      _pendingBinary.remove(tag);
      pushSink?.pushBinaryResponse(
        tag,
        Uint8List.fromList(data.length > 4 ? data.sublist(4) : const []),
      );
      return;
    }

    if (_pendingLogin != null && _bytesEqual(_pendingLogin!, prefix4)) {
      _pendingLogin = null;
      _handleLoginResponse(senderPubkey, data);
      return;
    }

    if (_pendingStatus != null && _bytesEqual(_pendingStatus!, prefix4)) {
      _pendingStatus = null;
      if (data.length > 4) {
        pushSink?.pushStatusResponse(
          Uint8List.fromList(senderPubkey.sublist(0, 6)),
          Uint8List.fromList(data.sublist(4)),
        );
      }
      return;
    }

    // Valid authenticated responses that match no pending request are
    // unsolicited pushes (for example sensor telemetry), not virtual requests.
    // Preserve tag + payload bytes exactly, including their timestamp/LPP.
    pushSink?.pushBinaryResponse(
      tag,
      Uint8List.fromList(data.length > 4 ? data.sublist(4) : const []),
    );
  }

  void _handleLoginResponse(Uint8List senderPubkey, Uint8List data) {
    final prefix6 = Uint8List.fromList(senderPubkey.sublist(0, 6));
    // Legacy repeater login replies with the literal "OK".
    if (data.length >= 6 && data[4] == 0x4F && data[5] == 0x4B) {
      pushSink?.pushLoginSuccess(prefix6, legacy: true);
      return;
    }
    if (data.length > 4 && data[4] == respServerLoginOk) {
      final tag =
          data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
      final keepAliveSecs = data.length > 5 ? data[5] * 16 : 0;
      if (keepAliveSecs > 0) _startKeepAlive(senderPubkey, keepAliveSecs);
      pushSink?.pushLoginSuccess(
        prefix6,
        permissions: data.length > 6 ? data[6] : 0,
        serverTag: tag,
        acl: data.length > 7 ? data[7] : 0,
        firmwareVer: data.length > 12 ? data[12] : 0,
      );
      return;
    }
    pushSink?.pushLoginFail(prefix6);
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  /// Number of persistent contacts (transient anonymous slots excluded).
  int get persistentContactCount => contacts.length;

  /// Configured channel count, including the default Public channel.
  int get channelCount => channels.length;

  /// Messages waiting for `CMD_SYNC_NEXT_MESSAGE`.
  int get queuedMessageCount => _messageQueue.length;

  int get queuedDirectCount =>
      _messageQueue.where((message) => !message.isChannel).length;

  int get queuedChannelCount =>
      _messageQueue.where((message) => message.isChannel).length;

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
  int get storageUsedBytes => _snapshot().storageBytes;

  /// Current virtual storage usage in the wire's KiB unit.
  int get storageUsedKb => storageKibForBytes(storageUsedBytes);

  /// Last persistence/quota diagnostic (never contains secrets).
  String? get storageDiagnostic => _storageDiagnostic;

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
        channels: channels ?? this.channels,
        queue: queue ?? _messageQueue,
        advertPaths: advertPaths ?? _advertPaths,
        customSettings: customSettings ?? _customVars,
      );

  void _publish(NodeState state) {
    prefs.copyFrom(state.prefs);
    contacts
      ..clear()
      ..addAll(state.contacts);
    channels
      ..clear()
      ..addAll(state.channels);
    _messageQueue
      ..clear()
      ..addAll(state.queue);
    _advertPaths
      ..clear()
      ..addAll(state.advertPaths);
    _customVars
      ..clear()
      ..addAll(state.customSettings);
  }

  void _checkQuota(NodeState candidate) {
    final bytes = candidate.storageBytes;
    if (bytes <= storageQuotaBytes) return;
    final current = _snapshot().storageBytes;
    // Allow shrinking mutations of legacy over-quota state.
    if (bytes <= current) return;
    throw const CompanionOperationError(
      errCodeTableFull,
      message: 'virtual storage quota exceeded',
    );
  }

  Future<void> _saveState(NodeState state) async {
    final s = store;
    _checkQuota(state);
    if (s == null) return;
    try {
      await s.save(state);
      _storageDiagnostic = null;
    } on NodeStorageQuotaError catch (e) {
      _storageDiagnostic = e.toString();
      throw CompanionOperationError(
        errCodeTableFull,
        message: 'virtual storage quota exceeded',
      );
    } on FileSystemException catch (e) {
      _storageDiagnostic = e.message;
      throw CompanionOperationError(
        errCodeFileIoError,
        message: 'persistence failed: ${e.message}',
      );
    } catch (e) {
      _storageDiagnostic = '$e';
      throw CompanionOperationError(
        errCodeFileIoError,
        message: 'persistence failed',
      );
    }
  }

  /// Save a candidate, then publish it. A save failure leaves node state
  /// untouched so the client sees an honest error.
  ///
  /// [identityGeneration] scopes background RX mutations so a completion from
  /// the previous identity cannot save/publish over a successful switch.
  Future<void> _commit(NodeState candidate, {int? identityGeneration}) {
    if (_retired) {
      return Future<void>.error(const CompanionOperationError(
        errCodeBadState,
        message: 'mesh node has been retired',
      ));
    }
    if (_resetInProgress) {
      return Future<void>.error(const CompanionOperationError(
        errCodeBadState,
        message: 'virtual reset in progress',
      ));
    }
    return _runState(() async {
      if (identityGeneration != null &&
          !_identityCurrent(identityGeneration)) {
        return;
      }
      await _saveState(candidate);
      if (identityGeneration != null &&
          !_identityCurrent(identityGeneration)) {
        return;
      }
      _publish(candidate);
      _notifyStateChanged();
    });
  }

  void _notifyStateChanged() {
    try {
      onStateChanged?.call();
    } catch (_) {
      // A host notification failure must never roll back durable state.
    }
  }

  void _notifyPhysicalConfigChanged() {
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
    if (params != null) {
      prefs.frequencyHz = params.frequencyHz;
      prefs.bandwidthHz = params.bandwidthHz;
      prefs.spreadingFactor = params.spreadingFactor;
      prefs.codingRate = params.codingRate;
      prefs.txPowerDbm = params.txPowerDbm;
      _radioCacheUncertain = false;
      _radioCacheVerified = true;
      _needsReconcile = false;
    }
    if (tuning != null) {
      prefs.rxDelayBaseMs = tuning.rxDelayBaseMs;
      prefs.airtimeFactorMs = tuning.airtimeFactorMs;
      _hasTuningCache = true;
      _tuningCacheVerified = true;
    }
    if (capabilities != null) physical = capabilities;
    _physicalDiagnostic = null;
    _persist();
  }

  /// Wait for queued persistence writes to settle.
  Future<void> flush() async => store?.flush();

  /// Reset persisted virtual data to S2 defaults while retaining the identity.
  /// Does not touch the physical radio or device-target/session configuration.
  Future<void> resetVirtualState() async {
    await resetVirtualData();
  }

  Future<void> _enqueueMessage(
    QueuedMessage message, {
    int? identityGeneration,
  }) async {
    if (_retired) return;
    if (identityGeneration != null &&
        !_identityCurrent(identityGeneration)) {
      return;
    }
    final newOnly = _snapshot(queue: [message]);
    if (newOnly.storageBytes > storageQuotaBytes) {
      _packetStats['recv_errors'] = (_packetStats['recv_errors'] ?? 0) + 1;
      _storageDiagnostic = 'incoming message dropped: virtual storage quota';
      return; // the new message alone does not fit; keep older messages
    }
    final candidateQueue = [
      for (final m in _messageQueue) m.clone(),
      message.clone(),
    ];
    while (candidateQueue.length > maxQueueSize) {
      candidateQueue.removeAt(0); // drop oldest on overflow
    }
    var candidate = _snapshot(queue: candidateQueue);
    while (candidate.storageBytes > storageQuotaBytes &&
        candidateQueue.length > 1) {
      candidateQueue.removeAt(0);
      candidate = _snapshot(queue: candidateQueue);
    }
    if (candidate.storageBytes > storageQuotaBytes) {
      _packetStats['recv_errors'] = (_packetStats['recv_errors'] ?? 0) + 1;
      _storageDiagnostic = 'incoming message dropped: virtual storage quota';
      return;
    }
    try {
      await _commit(candidate, identityGeneration: identityGeneration);
    } on CompanionOperationError catch (e) {
      _packetStats['recv_errors'] = (_packetStats['recv_errors'] ?? 0) + 1;
      _storageDiagnostic = e.message;
      return;
    }
    if (identityGeneration != null &&
        !_identityCurrent(identityGeneration)) {
      return;
    }
    pushSink?.pushMsgWaiting();
  }

  /// Fire-and-forget persistence for internal state updates. Client-facing
  /// durable mutations use the awaitable [_commit] path instead.
  void _persist() {
    if (_retired) return;
    unawaited(_persistCurrent());
  }

  Future<void> _persistCurrent() async {
    if (_retired) return;
    try {
      await _runState(() async {
        await _saveState(_snapshot());
      });
    } on CompanionOperationError catch (e) {
      _storageDiagnostic = e.message;
    }
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// Drop identity-dependent runtime state when a persistent contact is
  /// removed or overwritten. The saved advert lives in the [Contact] itself.
  void _forgetContactState(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    _pendingAcks.removeWhere((ack) {
      final matches = bytesToHex(ack.contactPubkey) == hex;
      if (matches) ack.timer.cancel();
      return matches;
    });
    _connections.remove(hex)?.stop();
    if (_pendingLogin != null && _bytesEqual(_pendingLogin!, _prefix4(pubkey))) {
      _pendingLogin = null;
    }
    if (_pendingStatus != null &&
        _bytesEqual(_pendingStatus!, _prefix4(pubkey))) {
      _pendingStatus = null;
    }
    _pendingTelemetry.removeWhere((_, value) => _bytesEqual(value, pubkey));
    _pendingDiscovery.removeWhere((_, value) => _bytesEqual(value, pubkey));
    _pendingBinary.removeWhere((_, value) => _bytesEqual(value, pubkey));
  }

  static Uint8List _prefix4(Uint8List pubkey) =>
      Uint8List.fromList(pubkey.sublist(0, pubkey.length < 4 ? pubkey.length : 4));

  /// A received advert saved for sharing/export, always normalized to flood so
  /// region transport codes are not persisted.
  Uint8List _normalizedAdvertBlob(Packet packet) {
    final saved = Packet()
      ..header = (packet.header & ~phRouteMask) | routeTypeFlood
      ..pathLenByte = packet.pathLenByte
      ..path = Uint8List.fromList(packet.path)
      ..payload = Uint8List.fromList(packet.payload);
    return saved.writeTo();
  }

  bool _shouldAutoAddType(int type) {
    if ((prefs.manualAddContacts & 0x01) == 0) return true;
    final bit = switch (type) {
      advTypeChat => autoAddChat,
      advTypeRepeater => autoAddRepeater,
      advTypeRoom => autoAddRoom,
      advTypeSensor => autoAddSensor,
      _ => 0,
    };
    return bit != 0 && (prefs.autoaddConfig & bit) != 0;
  }

  bool _hopAllowed(int pathHashCount) {
    final limit = prefs.autoaddMaxHops;
    return limit == 0 || pathHashCount < limit;
  }

  Map<String, AdvertPath> _advertPathCandidate(
    Packet packet,
    Uint8List pubkey,
    String name,
    int now,
  ) {
    final prefix = Uint8List.fromList(pubkey.sublist(0, 7));
    final key = bytesToHex(prefix);
    final map = <String, AdvertPath>{
      for (final entry in _advertPaths.entries)
        entry.key: entry.value.clone(),
    };
    map[key] = AdvertPath(
      publicKeyPrefix: prefix,
      name: name,
      pathLen: packet.pathLenByte,
      path: packet.path,
      recvTimestamp: now,
    );
    while (map.length > maxAdvertPathCacheEntries) {
      String? oldestKey;
      int? oldestTimestamp;
      for (final entry in map.entries) {
        final timestamp = entry.value.recvTimestamp;
        if (oldestTimestamp == null || timestamp < oldestTimestamp) {
          oldestTimestamp = timestamp;
          oldestKey = entry.key;
        }
      }
      if (oldestKey == null) break;
      map.remove(oldestKey);
    }
    return map;
  }

  Uint8List _contactFrameBody(Contact c) {
    final pathLen = c.outPathLen < 0 ? 0xFF : c.outPathLen.clamp(0, 255);
    final w = BufferWriter()
      ..writeBytes(c.publicKey)
      ..writeByte(c.advType)
      ..writeByte(c.flags)
      ..writeByte(pathLen);
    w.writeBytesPadded(c.outPath, maxPathSize);
    w.writeCString(c.name, maxNameSize);
    w.writeUInt32Le(c.lastAdvertTimestamp);
    w.writeInt32Le((c.gpsLat * 1e6).round());
    w.writeInt32Le((c.gpsLon * 1e6).round());
    w.writeUInt32Le(c.lastmod);
    return w.toBytes();
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
