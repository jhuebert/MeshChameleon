import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Serialized, atomic JSON-file writer.
///
/// Writes to `<path>.tmp` and renames it over the target so a crash cannot
/// leave a half-written file. Concurrent saves queue behind one another, and a
/// failed save does not poison later writes.
class JsonFile {
  JsonFile(this.file);

  final File file;
  Future<void> _tail = Future<void>.value();

  Future<void> write(
    Object? json, {
    FutureOr<void> Function()? beforeRename,
  }) {
    final encoded = jsonEncode(json);
    final write = _tail.then(
      (_) => _write(encoded, beforeRename),
      onError: (Object _) => _write(encoded, beforeRename),
    );
    _tail = write.then((_) {}, onError: (Object _) {});
    return write;
  }

  Future<void> _write(
    String encoded,
    FutureOr<void> Function()? beforeRename,
  ) async {
    await file.parent.create(recursive: true);
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(encoded, flush: true);
    try {
      if (beforeRename != null) await beforeRename();
      await temp.rename(file.path);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // Best-effort cleanup; the original error is more useful.
      }
      rethrow;
    }
  }

  Future<void> delete() async {
    if (await file.exists()) await file.delete();
  }
}
