import 'dart:convert';
import 'dart:io';

import 'json_file.dart';

/// Why a persisted JSON document could not be used.
enum JsonDocumentFailure {
  /// The file exists but is not valid JSON or does not match the schema.
  corrupt,

  /// The file was written by a build with a newer schema version.
  unsupportedVersion,

  /// The file could not be read (permissions, I/O error).
  unreadable,
}

/// A persisted document that cannot be loaded safely.
///
/// Corrupt and newer-version files are moved aside before this is thrown, so a
/// later save cannot silently destroy the only copy.
class JsonDocumentException implements Exception {
  const JsonDocumentException({
    required this.path,
    required this.failure,
    this.cause,
    this.quarantinePath,
  });

  final String path;
  final JsonDocumentFailure failure;
  final Object? cause;

  /// Where the original file was preserved, when quarantine succeeded.
  final String? quarantinePath;

  String get message {
    final preserved =
        quarantinePath == null ? '' : ' (preserved at $quarantinePath)';
    return switch (failure) {
      JsonDocumentFailure.corrupt => 'corrupt document at $path$preserved',
      JsonDocumentFailure.unsupportedVersion =>
        'unsupported document version at $path$preserved',
      JsonDocumentFailure.unreadable => 'unreadable document at $path',
    };
  }

  @override
  String toString() => message;
}

/// A persisted document that declares a newer schema than this build supports.
class JsonDocumentVersionException extends JsonDocumentException {
  const JsonDocumentVersionException({
    required super.path,
    required this.version,
    required this.supported,
    super.quarantinePath,
  }) : super(failure: JsonDocumentFailure.unsupportedVersion);

  final Object? version;
  final int supported;

  @override
  String get message {
    final preserved =
        quarantinePath == null ? '' : ' (preserved at $quarantinePath)';
    return 'unsupported document version $version '
        '(this build supports $supported) at $path$preserved';
  }
}

/// A lazily resolved, atomically written JSON document.
///
/// Missing files load as null. A corrupt, unreadable, or newer-version file
/// throws a [JsonDocumentException]; corrupt/newer files are quarantined first
/// so a later save cannot silently overwrite them. Writes and deletes
/// propagate failures to the caller through the underlying [JsonFile].
class JsonDocumentStore<T> {
  JsonDocumentStore({
    required this.resolveFile,
    required this.decode,
    required this.encode,
    this.version,
    this.quarantineOnError = true,
  });

  final Future<File> Function() resolveFile;
  final T? Function(Object? json) decode;
  final Object? Function(T value) encode;

  /// Current schema version, when the document has one.
  ///
  /// A document that declares a newer version is rejected before [decode] runs
  /// so a future layout is never mistaken for valid current data.
  final int? version;

  /// Whether corrupt/newer files are moved aside before the error is thrown.
  /// Set false for callers that implement their own backup/rollback policy.
  final bool quarantineOnError;

  File? _file;
  JsonFile? _writer;

  Future<File> _resolve() async => _file ??= await resolveFile();

  Future<JsonFile> _writeHandle() async =>
      _writer ??= JsonFile(await _resolve());

  Future<T?> load() async {
    File? file;
    try {
      file = await _resolve();
      if (!await file.exists()) return null;
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        throw const FormatException('empty document');
      }
      final decoded = jsonDecode(raw);
      final supported = version;
      if (supported != null && decoded is Map) {
        final rawVersion = decoded['version'];
        if (rawVersion is num &&
            rawVersion == rawVersion.toInt() &&
            rawVersion.toInt() > supported) {
          throw JsonDocumentVersionException(
            path: file.path,
            version: rawVersion,
            supported: supported,
          );
        }
      }
      final value = decode(decoded);
      if (value == null) throw const FormatException('invalid document');
      return value;
    } on JsonDocumentVersionException catch (e) {
      final quarantined =
          quarantineOnError && file != null ? await _quarantine(file) : null;
      throw JsonDocumentVersionException(
        path: e.path,
        version: e.version,
        supported: e.supported,
        quarantinePath: quarantined?.path,
      );
    } on FileSystemException catch (e) {
      throw JsonDocumentException(
        path: file?.path ?? '',
        failure: JsonDocumentFailure.unreadable,
        cause: e,
      );
    } on JsonDocumentException {
      rethrow;
    } catch (e) {
      final quarantined =
          quarantineOnError && file != null ? await _quarantine(file) : null;
      throw JsonDocumentException(
        path: file?.path ?? '',
        failure: JsonDocumentFailure.corrupt,
        cause: e,
        quarantinePath: quarantined?.path,
      );
    }
  }

  Future<void> save(T value) async {
    await (await _writeHandle()).write(encode(value));
  }

  Future<void> delete() async {
    await (await _writeHandle()).delete();
  }

  Future<File?> _quarantine(File file) async {
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final target = File('${file.path}.quarantine-$stamp');
    try {
      if (!await file.exists()) return null;
      return await file.rename(target.path);
    } catch (_) {
      // The typed error still reports the original path; the caller can decide
      // whether to retry or ask the user to remove the file.
      return null;
    }
  }
}
