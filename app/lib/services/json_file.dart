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

  /// One tail per target path, shared by every [JsonFile] instance. Callers may
  /// construct a fresh store for the same file, so an instance-local queue is
  /// not enough to prevent two writes (or a write and a delete) from racing.
  static final Map<String, Future<void>> _tails = <String, Future<void>>{};

  Future<void> write(
    Object? json, {
    FutureOr<void> Function()? beforeRename,
  }) {
    final encoded = jsonEncode(json);
    return _enqueue(() => _write(encoded, beforeRename));
  }

  Future<void> delete() => _enqueue(() async {
        if (await file.exists()) await file.delete();
      });

  Future<void> _enqueue(Future<void> Function() action) {
    final key = file.absolute.path;
    final previous = _tails[key];
    final run = previous == null
        ? action()
        : previous.then(
            (_) => action(),
            onError: (Object _) => action(),
          );
    late final Future<void> tail;
    tail = run.then((_) {}, onError: (Object _) {});
    _tails[key] = tail;
    tail.whenComplete(() {
      if (identical(_tails[key], tail)) _tails.remove(key);
    });
    return run;
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
}
