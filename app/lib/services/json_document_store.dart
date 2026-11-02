import 'dart:convert';
import 'dart:io';

import 'json_file.dart';

/// A lazily resolved, atomically written JSON document.
///
/// Reads are best-effort: a missing, corrupt, or unreadable file yields null so
/// startup is never blocked by a bad document. Writes and deletes propagate
/// failures to the caller through the underlying [JsonFile].
class JsonDocumentStore<T> {
  JsonDocumentStore({
    required this.resolveFile,
    required this.decode,
    required this.encode,
  });

  final Future<File> Function() resolveFile;
  final T? Function(Object? json) decode;
  final Object? Function(T value) encode;

  File? _file;
  JsonFile? _writer;

  Future<File> _resolve() async => _file ??= await resolveFile();

  Future<JsonFile> _writeHandle() async =>
      _writer ??= JsonFile(await _resolve());

  Future<T?> load() async {
    try {
      final file = await _resolve();
      if (!await file.exists()) return null;
      return decode(jsonDecode(await file.readAsString()));
    } catch (_) {
      // A corrupt or unreadable document must never block startup.
      return null;
    }
  }

  Future<void> save(T value) async {
    await (await _writeHandle()).write(encode(value));
  }

  Future<void> delete() async {
    await (await _writeHandle()).delete();
  }
}
