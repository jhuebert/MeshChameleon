import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/backup_codec.dart';

Map<String, Object?> _payload() => <String, Object?>{
      'greeting': 'hello',
      'count': 2,
      'nested': <String, Object?>{
        'list': <int>[1, 2, 3],
      },
    };

Future<Map<String, Object?>> _envelope(Uint8List bytes) async =>
    (jsonDecode(utf8.decode(bytes)) as Map).cast<String, Object?>();

void main() {
  const passphrase = 'correct horse battery';

  test('round-trips an encrypted payload', () async {
    final bytes = await BackupCodec.seal(
      payload: _payload(),
      passphrase: passphrase,
      appVersion: '1.0.0',
    );

    expect(bytes.length, greaterThan(0));
    final opened = await BackupCodec.open(
      bytes: bytes,
      passphrase: passphrase,
    );
    expect(opened, _payload());
  });

  test('rejects the wrong passphrase', () async {
    final bytes = await BackupCodec.seal(
      payload: _payload(),
      passphrase: passphrase,
      appVersion: '1.0.0',
    );

    await expectLater(
      BackupCodec.open(bytes: bytes, passphrase: 'not the passphrase'),
      throwsA(
        isA<BackupException>()
            .having((e) => e.wrongPassphraseOrDamaged, 'wrong', isTrue),
      ),
    );
  });

  test('rejects a tampered ciphertext', () async {
    final bytes = await BackupCodec.seal(
      payload: _payload(),
      passphrase: passphrase,
      appVersion: '1.0.0',
    );
    final envelope = await _envelope(bytes);
    final payload = base64Decode(envelope['payload']! as String);
    payload[0] ^= 0x01;
    envelope['payload'] = base64Encode(payload);
    final tampered = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));

    await expectLater(
      BackupCodec.open(bytes: tampered, passphrase: passphrase),
      throwsA(
        isA<BackupException>()
            .having((e) => e.wrongPassphraseOrDamaged, 'damaged', isTrue),
      ),
    );
  });

  test('rejects an edited header', () async {
    final bytes = await BackupCodec.seal(
      payload: _payload(),
      passphrase: passphrase,
      appVersion: '1.0.0',
    );
    final envelope = await _envelope(bytes);
    envelope['app_version'] = '9.9.9';
    final edited = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));

    await expectLater(
      BackupCodec.open(bytes: edited, passphrase: passphrase),
      throwsA(isA<BackupException>()),
    );
  });

  test('rejects a newer backup format', () async {
    final bytes = await BackupCodec.seal(
      payload: _payload(),
      passphrase: passphrase,
      appVersion: '1.0.0',
    );
    final envelope = await _envelope(bytes);
    envelope['version'] = backupFormatVersion + 1;
    final newer = Uint8List.fromList(utf8.encode(jsonEncode(envelope)));

    await expectLater(
      BackupCodec.open(bytes: newer, passphrase: passphrase),
      throwsA(
        isA<BackupException>().having(
          (e) => e.message,
          'message',
          contains('newer version'),
        ),
      ),
    );
  });

  test('rejects corrupt JSON and unrelated files', () async {
    await expectLater(
      BackupCodec.open(
        bytes: Uint8List.fromList(utf8.encode('not json')),
        passphrase: passphrase,
      ),
      throwsA(isA<BackupException>()),
    );
    await expectLater(
      BackupCodec.open(
        bytes: Uint8List.fromList(utf8.encode('{"hello":"world"}')),
        passphrase: passphrase,
      ),
      throwsA(isA<BackupException>()),
    );
  });

  test('requires a usable passphrase for new backups', () async {
    await expectLater(
      BackupCodec.seal(
        payload: _payload(),
        passphrase: 'short',
        appVersion: '1.0.0',
      ),
      throwsA(isA<BackupException>()),
    );
  });
}
