import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'identity_index.dart';
import 'identity_repository.dart';
import 'identity_runtime.dart';
import 'local_mesh_router.dart';

/// Shared physical radio values applied to every live identity.
class SharedPhysicalSnapshot {
  const SharedPhysicalSnapshot({
    required this.radioParams,
    required this.tuningParams,
    required this.capabilities,
  });

  final RadioParams radioParams;
  final TuningParams tuningParams;
  final PhysicalCapabilities capabilities;

  int get clientRepeat => capabilities.clientRepeat;
}

/// Owns the identity catalog, all live runtimes, the shared radio hub, and the
/// local mirror between virtual identities.
class IdentityManager {
  IdentityManager({
    required this.repository,
    this.onChanged,
    this.onLog,
    this.notifyDebounce = const Duration(milliseconds: 250),
  });

  final IdentityRepository repository;
  final void Function()? onChanged;
  final void Function(String message)? onLog;
  final Duration notifyDebounce;

  IdentityIndex? _index;
  final List<IdentityRuntime> _runtimes = [];
  final Map<String, IdentityRuntime> _runtimeById = {};
  String? _activeId;
  String? _databaseError;
  bool _loaded = false;

  SharedRadioHub? _hub;
  LocalMeshRouter? _router;
  Uint8List? _devicePublicKey;
  PhysicalCapabilities? _physical;
  RadioParams? _radioParams;
  TuningParams? _tuning;
  List<IdentitySummary> _summaries = const [];
  Timer? _notifyTimer;

  bool get loaded => _loaded;
  bool get deviceAttached => _hub != null;
  String? get databaseError => _databaseError;
  String? get activeId => _activeId;
  List<IdentitySummary> get summaries => List.unmodifiable(_summaries);
  List<IdentityRuntime> get runtimes => List.unmodifiable(_runtimes);

  IdentityRuntime? get activeRuntime {
    final id = _activeId;
    return id == null ? null : _runtimeById[id];
  }

  MeshNode? get activeNode => activeRuntime?.node;
  LocalIdentity? get activeIdentity => activeRuntime?.identity;

  SharedPhysicalSnapshot? get physicalSnapshot {
    final params = _radioParams;
    final capabilities = _physical;
    if (params == null || capabilities == null) return null;
    return SharedPhysicalSnapshot(
      radioParams: params,
      tuningParams: _tuning ??
          const TuningParams(rxDelayBaseMs: 0, airtimeFactorMs: 0),
      capabilities: capabilities,
    );
  }

  IdentitySummary? get activeSummary {
    for (final summary in _summaries) {
      if (summary.active) return summary;
    }
    return null;
  }

  Future<void> load() async {
    try {
      _index = await repository.loadOrCreate();
      _activeId = _index!.activeId;
      _databaseError = null;
      _loaded = true;
      await refreshSummaries();
      onLog?.call('Loaded ${_index!.identities.length} identities');
      await repository.cleanupOrphans();
    } on IdentityIndexException catch (e) {
      _databaseError = e.message;
      _loaded = false;
      onLog?.call('Identity database unavailable: ${e.message}');
    } catch (e) {
      _databaseError = 'Identity database unavailable: $e';
      _loaded = false;
      onLog?.call('Identity database unavailable: $e');
    }
    _notifyNow();
  }

  Future<void> refreshSummaries() async {
    final index = _index ?? await repository.loadOrCreate();
    final out = <IdentitySummary>[];
    for (final record in index.identities) {
      final runtime = _runtimeById[record.id];
      final node = runtime?.node;
      if (node != null) {
        out.add(IdentitySummary(
          id: runtime!.record.id,
          name: node.prefs.nodeName,
          publicKey: runtime.identity!.publicKey,
          createdAt: runtime.record.createdAt,
          active: runtime.record.id == _activeId,
          live: true,
          keyAvailable: true,
          channelCount: node.channelCount,
          contactCount: node.persistentContactCount,
          queuedDirect: node.queuedDirectCount,
          queuedChannel: node.queuedChannelCount,
        ));
        continue;
      }
      final state = await repository.loadState(record.id);
      final keyAvailable =
          runtime?.keyAvailable ?? await repository.hasKey(record.id);
      out.add(IdentitySummary(
        id: record.id,
        name: state?.prefs.nodeName ?? record.name,
        publicKey: record.publicKey,
        createdAt: record.createdAt,
        active: record.id == _activeId,
        live: false,
        keyAvailable: keyAvailable,
        channelCount: state?.channels.length ?? 1,
        contactCount: state?.contacts.length ?? 0,
        queuedDirect:
            state?.queue.where((message) => !message.isChannel).length ?? 0,
        queuedChannel:
            state?.queue.where((message) => message.isChannel).length ?? 0,
        unavailableReason: runtime?.unavailableReason ??
            (keyAvailable ? null : 'Key unavailable'),
      ));
    }
    out.sort(_compareSummaries);
    _summaries = out;
  }

  static int _compareSummaries(IdentitySummary a, IdentitySummary b) {
    if (a.active != b.active) return a.active ? -1 : 1;
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    if (byName != 0) return byName;
    final byAge = a.createdAt.compareTo(b.createdAt);
    if (byAge != 0) return byAge;
    return a.id.compareTo(b.id);
  }

  /// Start one live runtime for every catalog record.
  Future<void> startLive({
    required RadioLink base,
    required PhysicalCapabilities physical,
    required RadioParams radioParams,
    Uint8List? devicePublicKey,
  }) async {
    await stopLive(notify: false);
    _devicePublicKey =
        devicePublicKey == null ? null : Uint8List.fromList(devicePublicKey);
    _physical = physical;
    _radioParams = radioParams;
    try {
      _tuning = await base.tuningParams();
    } catch (_) {
      _tuning = null;
    }
    _hub = SharedRadioHub(base);
    _router = LocalMeshRouter(
      liveNodes: () =>
          _runtimes.where((runtime) => runtime.node != null).map((r) => r.node!),
      blockedPeer: () => _devicePublicKey,
      onLog: onLog,
    );
    _hub!.attach();

    _index = await repository.loadOrCreate();
    _activeId = _index!.activeId;
    final seenKeys = <String, String>{};
    for (final record in _index!.identities) {
      await _startRuntime(
        record,
        hub: _hub!,
        physical: physical,
        radioParams: radioParams,
        tuning: _tuning,
        seenKeys: seenKeys,
      );
    }
    await refreshSummaries();
    _notifyNow();
  }

  Future<void> _startRuntime(
    IdentityRecord record, {
    required SharedRadioHub hub,
    required PhysicalCapabilities physical,
    required RadioParams radioParams,
    required TuningParams? tuning,
    required Map<String, String> seenKeys,
  }) async {
    final runtime = IdentityRuntime(record);
    _runtimes.add(runtime);
    _runtimeById[record.id] = runtime;

    final identity = await repository.loadKey(record.id);
    if (identity == null) {
      runtime.unavailableReason = 'Key unavailable';
      return;
    }
    final publicHex = bytesToHex(identity.publicKey);
    if (_devicePublicKey != null &&
        bytesToHex(_devicePublicKey!) == publicHex) {
      runtime.unavailableReason = 'Conflicts with the attached companion';
      onLog?.call('Identity ${record.id} conflicts with the attached radio');
      return;
    }
    if (seenKeys.containsKey(publicHex)) {
      runtime.unavailableReason = 'Duplicate identity key';
      onLog?.call('Identity ${record.id} duplicates another identity key');
      return;
    }
    seenKeys[publicHex] = record.id;

    var effectiveRecord = record;
    if (!_bytesEqual(record.publicKey, identity.publicKey)) {
      try {
        effectiveRecord = await repository.updatePublicKey(
          record.id,
          identity.publicKey,
          attachedDeviceKeyHex:
              _devicePublicKey == null ? null : bytesToHex(_devicePublicKey!),
        );
        _replaceRecord(effectiveRecord);
        onLog?.call('Reconciled public key for identity ${record.id}');
      } catch (e) {
        runtime.unavailableReason = 'Identity key conflict';
        onLog?.call('Could not reconcile identity key: $e');
        return;
      }
    }

    // Quarantine a corrupt state file before the node's lenient store load
    // would otherwise start fresh silently.
    await repository.loadState(record.id);
    final store = repository.openNodeStore(record.id);
    final linkView = hub.viewFor(record.id);
    final MeshNode node;
    try {
      node = MeshNode(
        identity: identity,
        link: linkView,
        physical: physical,
        store: store,
        prefs: NodePrefs(nodeName: effectiveRecord.name),
        identityPersistence: repository.persistenceFor(
          record.id,
          validate: (candidate) => _validateImportedKey(record.id, candidate),
        ),
        onIdentityChanged: (changed) =>
            _handleIdentityChanged(runtime, changed),
        onStateChanged: () => _handleStateChanged(runtime),
        onPhysicalConfigChanged: () => _handlePhysicalConfigChanged(runtime),
        localRouter: _router,
      );
      await node.load();
      node.adoptPhysicalCapabilities(physical);
      node.syncRadioParams(radioParams);
      if (tuning != null) node.syncPhysicalState(tuning: tuning);
    } catch (e) {
      runtime.unavailableReason = 'Could not load identity state';
      onLog?.call('Could not start identity ${record.id}: $e');
      return;
    }

    runtime
      ..identity = identity
      ..node = node
      ..store = store
      ..linkView = linkView
      ..unavailableReason = null;
    await _reconcileName(runtime);
    node.start();
    onLog?.call('Started identity ${runtime.record.name} (${record.id})');
  }

  Future<void> _reconcileName(IdentityRuntime runtime) async {
    final node = runtime.node;
    if (node == null) return;
    final name = node.prefs.nodeName;
    if (name == runtime.record.name) return;
    try {
      final updated = await repository.updateName(runtime.record.id, name);
      runtime.record = updated;
      _replaceRecord(updated);
    } catch (e) {
      onLog?.call('Could not cache identity name: $e');
    }
  }

  void _replaceRecord(IdentityRecord record) {
    final index = _index;
    if (index == null) return;
    _index = index.copyWith(
      identities: [
        for (final item in index.identities)
          if (item.id == record.id) record else item,
      ],
    );
  }

  Future<void> stopLive({bool notify = true}) async {
    for (final runtime in List<IdentityRuntime>.of(_runtimes)) {
      try {
        await runtime.node?.retire();
      } catch (e) {
        onLog?.call('Could not retire one identity cleanly: $e');
      }
      runtime.clear();
    }
    _runtimes.clear();
    _runtimeById.clear();
    final hub = _hub;
    _hub = null;
    _router = null;
    _devicePublicKey = null;
    if (hub != null) {
      await hub.detach();
      hub.dispose();
    }
    if (_loaded) await refreshSummaries();
    if (notify) _notifyNow();
  }

  Future<void> _handleIdentityChanged(
    IdentityRuntime runtime,
    LocalIdentity identity,
  ) async {
    runtime.identity = identity;
    try {
      final updated = await repository.updatePublicKey(
        runtime.record.id,
        identity.publicKey,
        attachedDeviceKeyHex:
            _devicePublicKey == null ? null : bytesToHex(_devicePublicKey!),
      );
      runtime.record = updated;
      _replaceRecord(updated);
    } catch (e) {
      onLog?.call('Could not update the identity index after a key import: $e');
    }
    _scheduleNotify();
  }

  Future<void> _validateImportedKey(
    String recordId,
    LocalIdentity candidate,
  ) async {
    final candidateHex = bytesToHex(candidate.publicKey);
    if (_devicePublicKey != null &&
        bytesToHex(_devicePublicKey!) == candidateHex) {
      throw const CompanionOperationError(
        errCodeIllegalArg,
        message: 'the attached companion identity cannot be used virtually',
      );
    }
    for (final runtime in _runtimes) {
      if (runtime.record.id == recordId) continue;
      final identity = runtime.identity;
      if (identity != null && bytesToHex(identity.publicKey) == candidateHex) {
        throw const CompanionOperationError(
          errCodeIllegalArg,
          message: 'that identity key is already in use',
        );
      }
    }
    for (final record in _index?.identities ?? const <IdentityRecord>[]) {
      if (record.id == recordId) continue;
      if (bytesToHex(record.publicKey) == candidateHex) {
        throw const CompanionOperationError(
          errCodeIllegalArg,
          message: 'that identity key is already in use',
        );
      }
    }
  }

  void _handleStateChanged(IdentityRuntime runtime) {
    if (runtime.node != null) {
      unawaited(_reconcileName(runtime).then((_) {
        if (_loaded) {
          unawaited(refreshSummaries().then((_) => _scheduleNotify()));
        }
      }));
    }
    _scheduleNotify();
  }

  void _handlePhysicalConfigChanged(IdentityRuntime runtime) {
    if (runtime.record.id != _activeId) return;
    final node = runtime.node;
    if (node == null) return;
    _radioParams = node.radioParams;
    _tuning = node.tuningParams;
    _physical = node.physical;
    for (final other in _runtimes) {
      if (identical(other, runtime) || other.node == null) continue;
      other.node!.syncPhysicalState(
        params: _radioParams,
        tuning: _tuning,
        capabilities: _physical,
      );
    }
  }

  Future<void> reapplyPhysical({
    required PhysicalCapabilities physical,
    required RadioParams radioParams,
    TuningParams? tuning,
  }) async {
    _physical = physical;
    _radioParams = radioParams;
    if (tuning != null) _tuning = tuning;
    for (final runtime in _runtimes) {
      final node = runtime.node;
      if (node == null) continue;
      node.adoptPhysicalCapabilities(physical);
      node.syncRadioParams(radioParams);
      if (_tuning != null) node.syncPhysicalState(tuning: _tuning);
    }
  }

  Future<void> mirrorOutbound(
    Uint8List packet, {
    required Uint8List fromPublicKey,
  }) async {
    for (final runtime in List<IdentityRuntime>.of(_runtimes)) {
      final node = runtime.node;
      if (node == null) continue;
      if (_bytesEqual(node.identity.publicKey, fromPublicKey)) continue;
      try {
        await node.receiveLocal(packet);
      } catch (e) {
        onLog?.call('Local mirror to one identity failed: $e');
      }
    }
  }

  Future<IdentityRecord> create({String? name}) async {
    final record = await repository.create(name: name);
    _index = await repository.loadOrCreate();
    final hub = _hub;
    if (hub != null) {
      final seenKeys = <String, String>{};
      for (final runtime in _runtimes) {
        final identity = runtime.identity;
        if (identity != null) {
          seenKeys[bytesToHex(identity.publicKey)] = runtime.record.id;
        }
      }
      await _startRuntime(
        record,
        hub: hub,
        physical: _physical ?? const PhysicalCapabilities(),
        radioParams: _radioParams ??
            const RadioParams(
              frequencyHz: 915000000,
              bandwidthHz: 250000,
              spreadingFactor: 10,
              codingRate: 5,
            ),
        tuning: _tuning,
        seenKeys: seenKeys,
      );
    }
    await refreshSummaries();
    _notifyNow();
    return record;
  }

  Future<void> delete(String id) async {
    if (_activeId == id) {
      throw const IdentityDeleteException(
        'activate another identity before deleting this one',
      );
    }
    if ((_index?.identities.length ?? 0) <= 1) {
      throw const IdentityDeleteException('at least one identity must remain');
    }
    final runtime = _runtimeById[id];
    if (runtime != null) {
      await runtime.node?.retire();
      _runtimes.remove(runtime);
      _runtimeById.remove(id);
    }
    await repository.delete(id);
    _index = await repository.loadOrCreate();
    await refreshSummaries();
    _notifyNow();
  }

  Future<void> clearLocalData(String id) async {
    final runtime = _runtimeById[id];
    final node = runtime?.node;
    if (node != null) {
      await node.resetVirtualData(preserveName: true);
      await _reconcileName(runtime!);
    } else {
      await repository.clearLocalData(id);
    }
    await refreshSummaries();
    _notifyNow();
  }

  /// Activate [id], optionally switching a running companion server's bridge.
  Future<bool> activate(
    String id, {
    Future<void> Function(MeshNode node)? switchBridge,
  }) async {
    if (_activeId == id) return true;
    final index = _index;
    if (index == null || !index.identities.any((record) => record.id == id)) {
      return false;
    }
    if (_hub != null) {
      final runtime = _runtimeById[id];
      if (runtime?.node == null || runtime?.identity == null) return false;
    } else {
      final identity = await repository.loadKey(id);
      if (identity == null) return false;
      if (_devicePublicKey != null &&
          _bytesEqual(identity.publicKey, _devicePublicKey!)) {
        return false;
      }
    }
    await repository.setActive(id);
    _activeId = id;
    _index = _index!.copyWith(activeId: id);
    if (switchBridge != null) {
      final node = _runtimeById[id]?.node;
      if (node != null) await switchBridge(node);
    }
    await refreshSummaries();
    _notifyNow();
    return true;
  }

  /// Update the active selection without touching live nodes (used on startup).
  Future<void> selectPersistedActive() async {
    _index = await repository.loadOrCreate();
    _activeId = _index!.activeId;
    await refreshSummaries();
    _notifyNow();
  }

  void _scheduleNotify() {
    _notifyTimer?.cancel();
    _notifyTimer = Timer(notifyDebounce, _notifyNow);
  }

  void _notifyNow() {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    try {
      onChanged?.call();
    } catch (_) {}
  }

  Future<void> dispose() async {
    _notifyTimer?.cancel();
    await stopLive(notify: false);
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
