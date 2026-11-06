import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'identity_index.dart';
import 'identity_repository.dart';
import 'identity_runtime.dart';
import 'local_mesh_router.dart';
import 'phone_location_service.dart';
import 'phone_sensor_settings.dart';

/// Builds one live [IdentityRuntime] from a catalog record.
///
/// Kept separate from [IdentityManager] so catalog mutation and summary
/// bookkeeping stay readable; the manager supplies callbacks for its private
/// state instead of exposing it.
class IdentityRuntimeBuilder {
  IdentityRuntimeBuilder({
    required this.repository,
    required this.router,
    required this.devicePublicKey,
    required this.onLog,
    required this.onRuntimeCreated,
    required this.onIdentityChanged,
    required this.onStateChanged,
    required this.onPhysicalConfigChanged,
    required this.onPoweredOff,
    required this.validateImportedKey,
    required this.onRecordChanged,
    this.phoneLocation,
    this.readPhoneBatteryPercent,
  });

  final IdentityRepository repository;
  final LocalMeshRouter? router;
  final Uint8List? devicePublicKey;
  final void Function(String message)? onLog;
  final void Function(IdentityRuntime runtime) onRuntimeCreated;
  final Future<void> Function(IdentityRuntime, LocalIdentity) onIdentityChanged;
  final void Function() onStateChanged;
  final void Function(IdentityRuntime) onPhysicalConfigChanged;
  final Future<void> Function()? onPoweredOff;
  final Future<void> Function(String recordId, LocalIdentity candidate)
      validateImportedKey;
  final void Function(IdentityRecord record) onRecordChanged;
  final PhoneLocationService? phoneLocation;
  final Future<int?> Function()? readPhoneBatteryPercent;

  Future<IdentityRuntime> start(
    IdentityRecord record, {
    required SharedRadioHub hub,
    required PhysicalCapabilities physical,
    required RadioParams radioParams,
    required TuningParams? tuning,
    required Set<String> seenKeys,
  }) async {
    final runtime = IdentityRuntime(record);
    onRuntimeCreated(runtime);
    if (!record.enabled) return runtime;

    final identity = await repository.loadKey(record.id);
    if (identity == null) {
      runtime.unavailableReason = 'Key unavailable';
      return runtime;
    }
    final publicHex = bytesToHex(identity.publicKey);
    if (devicePublicKey != null && bytesToHex(devicePublicKey!) == publicHex) {
      runtime.unavailableReason = 'Conflicts with the attached companion';
      onLog?.call('Identity ${record.id} conflicts with the attached radio');
      return runtime;
    }
    if (!seenKeys.add(publicHex)) {
      runtime.unavailableReason = 'Duplicate identity key';
      onLog?.call('Identity ${record.id} duplicates another identity key');
      return runtime;
    }

    var effectiveRecord = record;
    if (!bytesEqual(record.publicKey, identity.publicKey)) {
      try {
        effectiveRecord = await repository.updatePublicKey(
          record.id,
          identity.publicKey,
          attachedDeviceKeyHex:
              devicePublicKey == null ? null : bytesToHex(devicePublicKey!),
        );
        onRecordChanged(effectiveRecord);
        onLog?.call('Reconciled public key for identity ${record.id}');
      } catch (e) {
        runtime.unavailableReason = 'Identity key conflict';
        onLog?.call('Could not reconcile identity key: $e');
        return runtime;
      }
    }

    // Quarantine a corrupt state file before the node's lenient store load
    // would otherwise start fresh silently. A future schema is not corrupt:
    // keep the file and mark this runtime unavailable until the app is updated.
    try {
      await repository.loadState(record.id);
    } on NodeStateVersionException catch (e) {
      runtime.unavailableReason = e.message;
      onLog?.call(
        'Could not start identity ${record.id}: ${e.message}',
      );
      return runtime;
    }
    final store = repository.openNodeStore(record.id);
    final linkView = hub.viewFor(record.id);
    final location = phoneLocation;
    final settingsProvider = location == null
        ? const EmptyVirtualSensorSettingsProvider()
        : PhoneSensorSettingsProvider(
            identityId: record.id,
            onChanged: location.updateSettings,
          );
    final MeshNode node;
    try {
      node = MeshNode(
        identity: identity,
        link: linkView,
        physical: physical,
        store: store,
        prefs: NodePrefs(nodeName: effectiveRecord.name),
        sensorSettings: settingsProvider,
        readPhoneBatteryPercent: readPhoneBatteryPercent,
        identityPersistence: repository.persistenceFor(
          record.id,
          validate: (candidate) => validateImportedKey(record.id, candidate),
        ),
        onIdentityChanged: (changed) => onIdentityChanged(runtime, changed),
        onStateChanged: onStateChanged,
        onPhysicalConfigChanged: () => onPhysicalConfigChanged(runtime),
        onPoweredOff: onPoweredOff,
        localRouter: router,
        attachedDevicePublicKey: devicePublicKey,
      );
      await node.load();
      node.adoptPhysicalCapabilities(physical);
      node.syncRadioParams(radioParams);
      if (tuning != null) node.syncPhysicalState(tuning: tuning);
      if (location != null) {
        location.bindNode(record.id, node);
        settingsProvider.onSettingsChanged(node.getCustomVars());
      }
    } catch (e) {
      runtime.unavailableReason = 'Could not load identity state';
      onLog?.call('Could not start identity ${record.id}: $e');
      return runtime;
    }

    runtime
      ..identity = identity
      ..node = node
      ..unavailableReason = null;
    await reconcileName(runtime);
    node.start();
    onLog?.call('Started identity ${runtime.record.name} (${record.id})');
    return runtime;
  }

  Future<void> reconcileName(IdentityRuntime runtime) async {
    final node = runtime.node;
    if (node == null) return;
    final name = node.prefs.nodeName;
    if (name == runtime.record.name) return;
    try {
      final updated = await repository.updateName(runtime.record.id, name);
      runtime.record = updated;
      onRecordChanged(updated);
    } catch (e) {
      onLog?.call('Could not cache identity name: $e');
    }
  }
}
