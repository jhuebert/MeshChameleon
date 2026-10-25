import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'node_store.dart';
import 'sensor_settings.dart';

/// Result of the staged app-only virtual reset.
///
/// Data reset and key rotation are intentionally not a distributed transaction:
/// once [dataReset] is true the fresh virtual state is durable, even if a later
/// key save fails. In that partial case [identityRotated] is false and
/// [keyError] explains the failure; the old identity remains active.
class VirtualResetResult {
  const VirtualResetResult({
    required this.dataReset,
    required this.identityRotated,
    this.keyError,
  });

  final bool dataReset;
  final bool identityRotated;

  /// Non-null when data was reset but the requested new identity failed.
  final CompanionOperationError? keyError;

  bool get success => dataReset && keyError == null;
  bool get partialKeyFailure => dataReset && keyError != null;
}

/// S2-default virtual state used by resets (no identity, no physical data).
NodeState freshVirtualState([
  VirtualSensorSettingsProvider sensorSettings =
      const EmptyVirtualSensorSettingsProvider(),
]) {
  final channel = Channel(
    name: 'Public',
    secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
  );
  return NodeState(
    prefs: NodePrefs(),
    channels: {0: channel},
    customSettings: sensorSettings.initialSettings,
  );
}
