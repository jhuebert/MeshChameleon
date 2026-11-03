import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'backup_codec.dart';
import 'identity_index.dart';
import 'network_connection_store.dart';
import 'session_store.dart';

/// Fully validated backup contents used by the restore path.
class BackupData {
  BackupData({
    required this.index,
    required this.keys,
    required this.states,
    required this.network,
    required this.session,
  });

  final IdentityIndex index;
  final Map<String, LocalIdentity> keys;
  final Map<String, Map<String, Object?>?> states;
  final List<SavedNetworkConnection>? network;
  final SessionConfig? session;
}

/// Validates a decoded backup payload before any local data is touched.
class BackupValidator {
  const BackupValidator();

  Future<BackupData> validate(Map<String, Object?> payload) async {
    final indexJson = payload['index'];
    if (indexJson is! Map) {
      throw const BackupException('That backup has no identity catalog');
    }
    final IdentityIndex index;
    try {
      index =
          IdentityIndex.fromJson(indexJson.cast<String, Object?>()).upgraded();
    } on IdentityIndexException catch (e) {
      throw BackupException('That backup catalog is invalid: ${e.message}');
    }
    if (index.identities.isEmpty) {
      throw const BackupException('That backup contains no identities');
    }
    final active = index.activeRecord;
    if (active == null || !active.enabled) {
      throw const BackupException('That backup has no usable active identity');
    }

    final rawIdentities = payload['identities'];
    if (rawIdentities is! Map) {
      throw const BackupException('That backup has no identity keys');
    }
    if (rawIdentities.length != index.identities.length) {
      throw const BackupException('That backup contains unexpected identities');
    }

    final keys = <String, LocalIdentity>{};
    final states = <String, Map<String, Object?>?>{};
    final seen = <String>{};
    for (final record in index.identities) {
      final entry = rawIdentities[record.id];
      if (entry is! Map) {
        throw BackupException(
          'That backup is missing identity "${record.name}"',
        );
      }
      final keyHex = entry['key'];
      if (keyHex is! String) {
        throw BackupException(
          'That backup is missing the key for "${record.name}"',
        );
      }
      LocalIdentity identity;
      try {
        final bytes = hexToBytes(keyHex);
        if (bytes.length != 64 ||
            !await LocalIdentity.validateMeshcore64(bytes)) {
          throw const FormatException('invalid key');
        }
        identity = await LocalIdentity.import(bytes);
      } catch (_) {
        throw BackupException(
          'That backup has an invalid key for "${record.name}"',
        );
      }
      final publicHex = bytesToHex(identity.publicKey);
      if (publicHex != bytesToHex(record.publicKey) || !seen.add(publicHex)) {
        throw BackupException(
          'That backup key does not match "${record.name}"',
        );
      }
      keys[record.id] = identity;

      final stateJson = entry['state'];
      if (stateJson == null) {
        states[record.id] = null;
        continue;
      }
      if (stateJson is! Map) {
        throw BackupException(
          'That backup has invalid state for "${record.name}"',
        );
      }
      try {
        states[record.id] =
            NodeState.fromJson(stateJson.cast<String, Object?>()).toJson();
      } catch (_) {
        throw BackupException(
          'That backup has invalid state for "${record.name}"',
        );
      }
    }

    return BackupData(
      index: index,
      keys: keys,
      states: states,
      network: _parseNetwork(payload['network_connections']),
      session: _parseSession(payload['session']),
    );
  }

  List<SavedNetworkConnection>? _parseNetwork(Object? raw) {
    if (raw == null) return null;
    try {
      return decodeNetworkConnections(raw, strict: true);
    } on FormatException {
      throw const BackupException('That backup has invalid saved connections');
    }
  }

  SessionConfig? _parseSession(Object? raw) {
    if (raw == null) return null;
    if (raw is! Map) {
      throw const BackupException('That backup has invalid session settings');
    }
    final session = SessionConfig.fromJson(raw.cast<String, dynamic>());
    if (session == null) {
      throw const BackupException('That backup has invalid session settings');
    }
    return session;
  }
}
