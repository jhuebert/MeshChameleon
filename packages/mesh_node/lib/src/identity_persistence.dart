import 'dart:io';
import 'dart:math';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Host persistence boundary for the active virtual identity.
///
/// `MeshNode` owns the switch/generation logic; app and headless hosts provide
/// storage. Implementations must throw on failure rather than silently
/// reporting success.
abstract class VirtualIdentityPersistence {
  Future<LocalIdentity?> load();
  Future<void> save(LocalIdentity identity);
}

/// Process-lifetime identity persistence for the headless proxy.
///
/// Imports are durable only until the process exits. No file is created.
class MemoryIdentityPersistence implements VirtualIdentityPersistence {
  MemoryIdentityPersistence([LocalIdentity? initial]) : _identity = initial;

  LocalIdentity? _identity;

  @override
  Future<LocalIdentity?> load() async => _identity;

  @override
  Future<void> save(LocalIdentity identity) async {
    _identity = identity;
  }
}

/// Plaintext hex identity file for the headless proxy.
///
/// The file is replaced atomically: an empty temporary file in the same
/// directory is set to mode 0600 before any secret bytes are written, then
/// flushed and renamed over the destination. Parent directories are never
/// chmodded.
class FileIdentityPersistence implements VirtualIdentityPersistence {
  FileIdentityPersistence(this.file, {this.onTempPrepared});

  final File file;

  /// Test hook invoked after the empty temp file is made private and before
  /// the identity bytes are written.
  final void Function(File temp)? onTempPrepared;

  @override
  Future<LocalIdentity?> load() async {
    if (!await file.exists()) return null;
    final hex = (await file.readAsString()).trim();
    if (hex.isEmpty) {
      throw const FormatException('empty identity file');
    }
    final key = hexToBytes(hex);
    if (key.length != 64 || !await LocalIdentity.validateMeshcore64(key)) {
      throw const FormatException('invalid identity file');
    }
    return LocalIdentity.fromMeshcore64(key);
  }

  @override
  Future<void> save(LocalIdentity identity) async {
    final parent = file.parent;
    if (!await parent.exists()) {
      await parent.create(recursive: true);
    }
    final random = Random.secure().nextInt(1 << 32);
    final temp = File(
      '${file.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}-$random',
    );
    await temp.create(exclusive: true);
    try {
      if (!Platform.isWindows) {
        final chmod = await Process.run('chmod', ['600', temp.path]);
        if (chmod.exitCode != 0) {
          throw FileSystemException(
            'could not set identity temp file permissions',
            temp.path,
          );
        }
      }
      onTempPrepared?.call(temp);
      final raf = await temp.open(mode: FileMode.write);
      try {
        await raf.writeString(bytesToHex(identity.meshcore64));
        await raf.flush();
      } finally {
        await raf.close();
      }
      await temp.rename(file.path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }
}
