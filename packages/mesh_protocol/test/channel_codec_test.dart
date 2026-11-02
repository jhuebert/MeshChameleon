import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('channelSecret32 zero-pads short secrets', () {
    final secret = Uint8List.fromList([1, 2, 3]);
    final key = channelSecret32(secret);
    expect(key, hasLength(32));
    expect(key.sublist(0, 3), [1, 2, 3]);
    expect(key.sublist(3), everyElement(0));
  });

  test('channelSecret32 truncates secrets longer than 32 bytes', () {
    final secret = Uint8List.fromList(List.generate(40, (i) => i));
    final key = channelSecret32(secret);
    expect(key, secret.sublist(0, 32));
  });

  test('channelHash hashes the first 16 padded bytes', () {
    final secret = Uint8List.fromList([1, 2, 3]);
    final expected =
        CryptoUtils.sha256(channelSecret32(secret).sublist(0, 16))[0];
    expect(channelHash(secret), expected);
  });

  test('channelKey returns the padded key and matching hash', () {
    final secret = Uint8List.fromList(List.generate(20, (i) => i));
    final key = channelKey(secret);
    expect(key.secret, channelSecret32(secret));
    expect(key.hash, channelHash(secret));
  });
}
