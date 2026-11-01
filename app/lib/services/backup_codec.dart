import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Identifier stored in every backup envelope.
const String backupFormatId = 'meshchameleon.backup';

/// Current backup envelope version. Bump only for layout changes.
const int backupFormatVersion = 1;

/// PBKDF2 work factor for new backups.
const int backupKdfIterations = 210000;

/// Smallest accepted passphrase length.
const int minBackupPassphraseLength = 8;

/// Largest file accepted by the importer, before decryption.
const int maxBackupBytes = 64 * 1024 * 1024;

const int _minKdfIterations = 10000;
const int _maxKdfIterations = 2000000;
const int _saltBytes = 16;
const int _nonceBytes = 12;

/// A backup could not be created or opened.
///
/// [wrongPassphraseOrDamaged] deliberately covers both a wrong passphrase and
/// a tampered file: the user-facing message must not distinguish them.
class BackupException implements Exception {
  const BackupException(
    this.message, {
    this.wrongPassphraseOrDamaged = false,
  });

  final String message;
  final bool wrongPassphraseOrDamaged;

  @override
  String toString() => 'BackupException($message)';
}

/// Encrypts and decrypts the single-file backup format.
///
/// The envelope is a small JSON header plus an AES-256-GCM ciphertext. The
/// passphrase key is derived with PBKDF2-HMAC-SHA256. Header fields that affect
/// decryption are authenticated as additional data, so editing the version,
/// timestamp, KDF parameters, or nonce invalidates the file.
class BackupCodec {
  const BackupCodec._();

  static Future<Uint8List> seal({
    required Map<String, Object?> payload,
    required String passphrase,
    required String appVersion,
    DateTime? createdAt,
    Random? random,
  }) async {
    if (passphrase.length < minBackupPassphraseLength) {
      throw const BackupException(
        'Use a passphrase with at least $minBackupPassphraseLength characters',
      );
    }
    final rng = random ?? Random.secure();
    final salt = _randomBytes(rng, _saltBytes);
    final nonce = _randomBytes(rng, _nonceBytes);
    final header = <String, Object?>{
      'format': backupFormatId,
      'version': backupFormatVersion,
      'created_at': (createdAt ?? DateTime.now()).toUtc().toIso8601String(),
      'app_version': appVersion,
      'kdf': <String, Object?>{
        'algorithm': 'pbkdf2-hmac-sha256',
        'iterations': backupKdfIterations,
        'salt': base64Encode(salt),
      },
      'cipher': <String, Object?>{
        'algorithm': 'aes-256-gcm',
        'nonce': base64Encode(nonce),
      },
    };

    final key = await _deriveKey(passphrase, salt, backupKdfIterations);
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(jsonEncode(payload)),
      secretKey: key,
      nonce: nonce,
      aad: _aadFor(header),
    );
    (header['cipher']! as Map<String, Object?>)['mac'] =
        base64Encode(box.mac.bytes);

    final envelope = <String, Object?>{
      ...header,
      'payload': base64Encode(box.cipherText),
    };
    return Uint8List.fromList(utf8.encode(jsonEncode(envelope)));
  }

  static Future<Map<String, Object?>> open({
    required List<int> bytes,
    required String passphrase,
  }) async {
    if (bytes.length > maxBackupBytes) {
      throw const BackupException('That backup file is too large');
    }

    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const BackupException('That file is not a MeshChameleon backup');
    }
    if (decoded is! Map) {
      throw const BackupException('That file is not a MeshChameleon backup');
    }
    final envelope = decoded.cast<String, Object?>();

    if (envelope['format'] != backupFormatId) {
      throw const BackupException('That file is not a MeshChameleon backup');
    }
    final version = envelope['version'];
    if (version is! num) {
      throw const BackupException('That backup file is damaged');
    }
    if (version != version.toInt()) {
      throw const BackupException('That backup file is damaged');
    }
    if (version.toInt() > backupFormatVersion) {
      throw const BackupException(
        'That backup was created by a newer version of MeshChameleon',
      );
    }
    if (version.toInt() != backupFormatVersion) {
      throw const BackupException('That backup format is not supported');
    }

    final createdAt = envelope['created_at'];
    final appVersion = envelope['app_version'];
    final kdf = envelope['kdf'];
    final cipher = envelope['cipher'];
    final payload = envelope['payload'];
    if (createdAt is! String ||
        appVersion is! String ||
        kdf is! Map ||
        cipher is! Map ||
        payload is! String) {
      throw const BackupException('That backup file is damaged');
    }

    final salt = _decodeBase64(kdf['salt']);
    final nonce = _decodeBase64(cipher['nonce']);
    final macBytes = _decodeBase64(cipher['mac']);
    final iterations = kdf['iterations'];
    if (kdf['algorithm'] != 'pbkdf2-hmac-sha256' ||
        cipher['algorithm'] != 'aes-256-gcm' ||
        iterations is! num ||
        iterations != iterations.toInt() ||
        iterations.toInt() < _minKdfIterations ||
        iterations.toInt() > _maxKdfIterations ||
        salt.length != _saltBytes ||
        nonce.length != _nonceBytes ||
        macBytes.length != 16) {
      throw const BackupException('That backup file is damaged');
    }
    final cipherText = _decodeBase64(payload);

    final header = <String, Object?>{
      'format': backupFormatId,
      'version': version.toInt(),
      'created_at': createdAt,
      'app_version': appVersion,
      'kdf': <String, Object?>{
        'algorithm': kdf['algorithm'],
        'iterations': iterations.toInt(),
        'salt': base64Encode(salt),
      },
      'cipher': <String, Object?>{
        'algorithm': cipher['algorithm'],
        'nonce': base64Encode(nonce),
      },
    };

    final key = await _deriveKey(passphrase, salt, iterations.toInt());
    List<int> clearText;
    try {
      clearText = await AesGcm.with256bits().decrypt(
        SecretBox(cipherText, nonce: nonce, mac: Mac(macBytes)),
        secretKey: key,
        aad: _aadFor(header),
      );
    } on SecretBoxAuthenticationError {
      throw const BackupException(
        'Wrong passphrase or damaged backup',
        wrongPassphraseOrDamaged: true,
      );
    }

    Object? body;
    try {
      body = jsonDecode(utf8.decode(clearText));
    } on FormatException {
      throw const BackupException('That backup file is damaged');
    }
    if (body is! Map) {
      throw const BackupException('That backup file is damaged');
    }
    return body.cast<String, Object?>();
  }

  static Future<SecretKey> _deriveKey(
    String passphrase,
    Uint8List salt,
    int iterations,
  ) {
    final pbkdf2 = Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: iterations,
      bits: 256,
    );
    return pbkdf2.deriveKey(
      secretKey: SecretKey(utf8.encode(passphrase)),
      nonce: salt,
    );
  }

  /// Stable encoding of the authenticated header fields.
  static List<int> _aadFor(Map<String, Object?> header) {
    final kdf = header['kdf']! as Map<String, Object?>;
    final cipher = header['cipher']! as Map<String, Object?>;
    return utf8.encode(
      [
        header['format'],
        header['version'],
        header['created_at'],
        header['app_version'],
        kdf['algorithm'],
        kdf['iterations'],
        kdf['salt'],
        cipher['algorithm'],
        cipher['nonce'],
      ].join('|'),
    );
  }

  static Uint8List _randomBytes(Random random, int length) =>
      Uint8List.fromList(
        List<int>.generate(length, (_) => random.nextInt(256)),
      );

  static Uint8List _decodeBase64(Object? value) {
    if (value is! String) {
      throw const BackupException('That backup file is damaged');
    }
    try {
      return base64Decode(value);
    } on FormatException {
      throw const BackupException('That backup file is damaged');
    }
  }
}
