import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'backup_codec.dart';
import 'identity_index.dart';
import 'identity_repository.dart';
import 'identity_store.dart';
import 'network_connection_store.dart';
import 'session_store.dart';

/// What a decoded backup contains, for the confirmation dialog.
class BackupPreview {
  const BackupPreview._({
    required this.identityCount,
    required this.contactCount,
    required this.channelCount,
    required this.messageCount,
    required _BackupData data,
  }) : _data = data;

  final int identityCount;
  final int contactCount;
  final int channelCount;
  final int messageCount;
  final _BackupData _data;
}

/// Builds and restores the single-file encrypted backup.
///
/// The payload keeps the same JSON shapes the app already persists, so a
/// restore writes through the normal stores instead of inventing a second data
/// model.
class BackupService {
  BackupService({
    required this.repository,
    required this.identityStore,
    required this.sessionStore,
    required this.networkConnectionStore,
    this.onLog,
  });

  final IdentityRepository repository;
  final IdentityStore identityStore;
  final SessionStore sessionStore;
  final NetworkConnectionStore networkConnectionStore;
  final void Function(String message)? onLog;

  /// Snapshot every persisted identity and its state, plus saved connections
  /// and the last session. Logs and diagnostics are deliberately excluded.
  Future<Map<String, Object?>> capture() async {
    final index = (await repository.loadOrCreate()).upgraded();
    final identities = <String, Object?>{};
    for (final record in index.identities) {
      final key = await identityStore.loadById(record.id);
      if (key == null) {
        throw BackupException(
          'Identity "${record.name}" has no readable key',
        );
      }
      final state = await _readState(record);
      identities[record.id] = <String, Object?>{
        'key': bytesToHex(key.meshcore64),
        'state': state?.toJson(),
      };
    }

    final network = await networkConnectionStore.load();
    return <String, Object?>{
      'index': index.toJson(),
      'identities': identities,
      'network_connections': encodeNetworkConnections(network),
      'session': (await sessionStore.load())?.toJson(),
    };
  }

  /// Decrypt and fully validate a backup before anything is touched.
  Future<BackupPreview> inspect({
    required Uint8List bytes,
    required String passphrase,
  }) async {
    final payload = await BackupCodec.open(
      bytes: bytes,
      passphrase: passphrase,
    );
    final data = await _validate(payload);
    var contacts = 0;
    var channels = 0;
    var messages = 0;
    for (final stateJson in data.states.values) {
      if (stateJson == null) continue;
      final state = NodeState.fromJson(stateJson);
      contacts += state.contacts.length;
      channels += state.channels.length;
      messages += state.queue.length;
    }
    return BackupPreview._(
      identityCount: data.index.identities.length,
      contactCount: contacts,
      channelCount: channels,
      messageCount: messages,
      data: data,
    );
  }

  /// Replace the local catalog, keys, states, connections, and session.
  ///
  /// The current identity directory is renamed to a recovery folder before the
  /// swap, so a failed write can be rolled back and the previous files remain
  /// available for manual recovery.
  Future<void> restore(BackupPreview preview) async {
    final data = preview._data;
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final support = repository.supportDirectory;
    final staging = Directory('${support.path}/restore-staging-$stamp');
    final stagingIdentities = Directory('${staging.path}/identities');
    await stagingIdentities.create(recursive: true);

    try {
      final stagingIndex = IdentityIndexStore(
        file: File('${stagingIdentities.path}/index.json'),
      );
      await stagingIndex.save(data.index);
      for (final entry in data.states.entries) {
        final stateJson = entry.value;
        if (stateJson == null) continue;
        final directory = Directory('${stagingIdentities.path}/${entry.key}');
        await directory.create(recursive: true);
        await JsonNodeStore(
          file: File('${directory.path}/node_state.json'),
        ).save(NodeState.fromJson(stateJson));
      }

      final oldKeys = <String, LocalIdentity?>{};
      for (final record in data.index.identities) {
        oldKeys[record.id] = await identityStore.loadById(record.id);
      }
      final oldSession = await sessionStore.load();
      final oldNetwork = await networkConnectionStore.load();

      final current = repository.identitiesDirectory;
      final recovery = Directory('${support.path}/identities.recovery-$stamp');
      final hadCurrent = await current.exists();
      try {
        if (hadCurrent) await current.rename(recovery.path);
        await stagingIdentities.rename(current.path);
        for (final entry in data.keys.entries) {
          await identityStore.saveById(entry.key, entry.value);
        }
        final session = data.session;
        if (session != null) {
          await sessionStore.save(session);
        } else {
          await sessionStore.delete();
        }
        final network = data.network;
        if (network != null) {
          await networkConnectionStore.save(network);
        } else {
          await networkConnectionStore.delete();
        }
      } catch (e) {
        onLog?.call('Restore failed; rolling back local data');
        try {
          if (await current.exists()) {
            await current.rename('${staging.path}/failed-identities');
          }
          if (hadCurrent) await recovery.rename(current.path);
        } catch (rollbackError) {
          onLog?.call('Could not roll back identity files: $rollbackError');
        }
        for (final entry in oldKeys.entries) {
          try {
            final key = entry.value;
            if (key == null) {
              await identityStore.deleteById(entry.key);
            } else {
              await identityStore.saveById(entry.key, key);
            }
          } catch (keyError) {
            onLog?.call('Could not roll back one identity key: $keyError');
          }
        }
        try {
          if (oldSession == null) {
            await sessionStore.delete();
          } else {
            await sessionStore.save(oldSession);
          }
          await networkConnectionStore.save(oldNetwork);
        } catch (settingsError) {
          onLog?.call('Could not roll back saved connections: $settingsError');
        }
        rethrow;
      }

      onLog?.call(
        'Restored ${data.index.identities.length} identities'
        '${hadCurrent ? '; previous files kept in ${recovery.path}' : ''}',
      );
      // Keep only the newest recovery copy so repeated restores do not grow
      // app storage without bound.
      try {
        await for (final entity in support.list()) {
          if (entity is! Directory) continue;
          final name = entity.path.split(Platform.pathSeparator).last;
          if (name.startsWith('identities.recovery-') &&
              entity.path != recovery.path) {
            await entity.delete(recursive: true);
          }
        }
      } catch (e) {
        onLog?.call('Could not prune an older recovery copy: $e');
      }
    } finally {
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {
        // Best effort; the next launch does not read this path.
      }
    }
  }

  Future<NodeState?> _readState(IdentityRecord record) async {
    final file = repository.stateFile(record.id);
    if (!await file.exists()) return null;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        throw const FormatException('state is not an object');
      }
      return NodeState.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      throw BackupException(
        'Identity "${record.name}" has unreadable state; fix or clear it first',
      );
    }
  }

  Future<_BackupData> _validate(Map<String, Object?> payload) async {
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

    final network = _parseNetwork(payload['network_connections']);
    final session = _parseSession(payload['session']);
    return _BackupData(
      index: index,
      keys: keys,
      states: states,
      network: network,
      session: session,
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

class _BackupData {
  _BackupData({
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
