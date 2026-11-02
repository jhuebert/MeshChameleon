import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'backup_codec.dart';
import 'identity_index.dart';
import 'identity_repository.dart';
import 'identity_store.dart';
import 'json_file.dart';
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

  /// Marker written before the restore swap. If the process dies mid-restore,
  /// the next launch rolls the previous catalog and keys back instead of
  /// starting with a valid catalog whose keys were never written.
  static const String restoreMarkerName = 'restore-in-progress.json';
  static const int restoreMarkerVersion = 1;

  File get _restoreMarker =>
      File('${repository.supportDirectory.path}/$restoreMarkerName');

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
      if (bytesToHex(key.publicKey) != bytesToHex(record.publicKey)) {
        throw BackupException(
          'Identity "${record.name}" changed while the backup was being made; '
          'try again',
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

      final current = repository.identitiesDirectory;
      final oldIds = <String>{};
      try {
        final currentIndex = await repository.indexStore.load();
        for (final record
            in currentIndex?.identities ?? const <IdentityRecord>[]) {
          oldIds.add(record.id);
        }
      } catch (_) {
        // A corrupt current catalog must not block restoring a good backup.
      }
      // Also cover identity directories whose catalog was already unreadable.
      try {
        if (await current.exists()) {
          await for (final entity in current.list()) {
            if (entity is! Directory) continue;
            final id = entity.path.split(Platform.pathSeparator).last;
            if (RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) oldIds.add(id);
          }
        }
      } catch (_) {
        // Best effort; the backup's own ids are still restored below.
      }
      oldIds.addAll(data.index.identities.map((record) => record.id));
      final oldKeys = <String, LocalIdentity?>{};
      for (final id in oldIds) {
        oldKeys[id] = await identityStore.loadById(id);
      }
      final oldSession = await sessionStore.load();
      final oldNetwork = await networkConnectionStore.load();

      final recovery = Directory('${support.path}/identities.recovery-$stamp');
      final hadCurrent = await current.exists();
      final marker = JsonFile(_restoreMarker);
      final markerJson = <String, Object?>{
        'version': restoreMarkerVersion,
        'complete': false,
        'stamp': stamp,
        'had_current': hadCurrent,
        'old_ids': oldIds.toList(),
        'old_key_ids': [
          for (final entry in oldKeys.entries)
            if (entry.value != null) entry.key,
        ],
      };
      try {
        for (final entry in oldKeys.entries) {
          final key = entry.value;
          if (key != null) {
            await identityStore.saveRestoreBackup(entry.key, key);
          }
        }
        await marker.write(markerJson);
      } catch (e) {
        for (final id in oldIds) {
          try {
            await identityStore.deleteRestoreBackup(id);
          } catch (_) {}
        }
        rethrow;
      }

      var movedCurrent = false;
      var movedStaging = false;
      try {
        if (hadCurrent) {
          await current.rename(recovery.path);
          movedCurrent = true;
        }
        await stagingIdentities.rename(current.path);
        movedStaging = true;
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
        var filesRolledBack = true;
        try {
          // Only move the staged catalog aside if the swap actually installed
          // it. If the first rename failed, `current` is still the live data.
          if (movedStaging && await current.exists()) {
            await current.rename('${staging.path}/failed-identities');
          }
          if (movedCurrent &&
              await recovery.exists() &&
              !await current.exists()) {
            await recovery.rename(current.path);
          }
        } catch (rollbackError) {
          filesRolledBack = false;
          onLog?.call('Could not roll back identity files: $rollbackError');
        }
        var keysRolledBack = true;
        for (final entry in oldKeys.entries) {
          try {
            final key = entry.value;
            if (key == null) {
              await identityStore.deleteById(entry.key);
            } else {
              await identityStore.saveById(entry.key, key);
            }
          } catch (keyError) {
            keysRolledBack = false;
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
        if (keysRolledBack && filesRolledBack) {
          try {
            await marker.delete();
          } catch (markerError) {
            onLog?.call('Could not clear the restore marker: $markerError');
          }
          for (final id in oldIds) {
            try {
              await identityStore.deleteRestoreBackup(id);
            } catch (_) {}
          }
        }
        rethrow;
      }

      // Mark the restore complete before dropping the rollback snapshots. If
      // only this marker cleanup fails, the next launch must not roll back a
      // restore that already succeeded.
      try {
        await marker.write(<String, Object?>{...markerJson, 'complete': true});
      } catch (e) {
        onLog?.call('Could not mark the restore complete: $e');
      }
      var markerCleared = false;
      try {
        await marker.delete();
        markerCleared = !await marker.file.exists();
      } catch (e) {
        onLog?.call('Could not clear the restore marker: $e');
      }
      if (markerCleared) {
        for (final id in oldIds) {
          try {
            await identityStore.deleteRestoreBackup(id);
          } catch (_) {}
        }
      }

      // Replace all local keys, not just the ones named by the backup.
      for (final id in oldIds.difference(data.keys.keys.toSet())) {
        try {
          await identityStore.deleteById(id);
        } catch (e) {
          onLog?.call('Could not remove an old identity key: $e');
        }
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

  /// Roll back a restore that was interrupted by process death.
  ///
  /// Call once at startup before loading identities. A completed marker is
  /// only cleaned up; an incomplete marker restores the recovery directory and
  /// the temporary old-key snapshots.
  Future<void> recoverInterruptedRestore() async {
    final markerFile = _restoreMarker;
    if (!await markerFile.exists()) return;

    Map<String, Object?> marker;
    try {
      final decoded = jsonDecode(await markerFile.readAsString());
      if (decoded is! Map) throw const FormatException('not an object');
      marker = decoded.cast<String, Object?>();
      if (marker['version'] != restoreMarkerVersion) {
        throw const FormatException('unsupported marker version');
      }
    } catch (e) {
      onLog?.call('An interrupted restore marker is unreadable: $e');
      return;
    }

    final stamp = marker['stamp'];
    if (stamp is! String ||
        stamp.isEmpty ||
        stamp.contains('/') ||
        stamp.contains(r'\') ||
        stamp.contains('..')) {
      onLog?.call('An interrupted restore marker has an invalid stamp');
      return;
    }
    final oldIds = _markerIds(marker['old_ids']);
    final oldKeyIds = _markerIds(marker['old_key_ids']);

    if (marker['complete'] == true) {
      await _clearRestoreMarker(markerFile, oldIds);
      return;
    }

    final current = repository.identitiesDirectory;
    final recovery = Directory(
        '${repository.supportDirectory.path}/identities.recovery-$stamp');
    if (await recovery.exists()) {
      if (await current.exists()) {
        final failed = Directory(
          '${repository.supportDirectory.path}/identities.failed-restore-'
          '$stamp-${DateTime.now().millisecondsSinceEpoch}',
        );
        await current.rename(failed.path);
      }
      await recovery.rename(current.path);
      onLog?.call('Recovered identity files from an interrupted restore');
    }

    for (final id in oldIds) {
      if (oldKeyIds.contains(id)) {
        final oldKey = await identityStore.loadRestoreBackup(id);
        if (oldKey != null) {
          await identityStore.saveById(id, oldKey);
        } else {
          onLog?.call('Could not recover an old identity key during rollback');
        }
      } else {
        await identityStore.deleteById(id);
      }
      await identityStore.deleteRestoreBackup(id);
    }
    await _clearRestoreMarker(markerFile, oldIds, deleteKeys: false);
    onLog?.call('Rolled back an interrupted backup restore');
  }

  Set<String> _markerIds(Object? raw) {
    final ids = <String>{};
    if (raw is! List) return ids;
    final valid = RegExp(r'^[0-9a-f]{32}$');
    for (final value in raw) {
      if (value is String && valid.hasMatch(value)) ids.add(value);
    }
    return ids;
  }

  Future<void> _clearRestoreMarker(
    File markerFile,
    Set<String> oldIds, {
    bool deleteKeys = true,
  }) async {
    if (deleteKeys) {
      for (final id in oldIds) {
        try {
          await identityStore.deleteRestoreBackup(id);
        } catch (_) {}
      }
    }
    try {
      if (await markerFile.exists()) await markerFile.delete();
    } catch (e) {
      onLog?.call('Could not remove the restore marker: $e');
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
