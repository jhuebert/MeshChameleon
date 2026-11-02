import 'dart:typed_data';

import 'crypto.dart';

/// The on-air channel key: a stored channel secret zero-padded to 32 bytes.
Uint8List channelSecret32(Uint8List secret) {
  final key = Uint8List(32);
  key.setRange(0, secret.length.clamp(0, 32), secret);
  return key;
}

/// The firmware channel hash: the first byte of `sha256(key[0..16])`.
int channelHash(Uint8List secret) =>
    CryptoUtils.sha256(channelSecret32(secret).sublist(0, 16))[0];

/// The channel key and its hash byte, derived from one padded secret.
({Uint8List secret, int hash}) channelKey(Uint8List secret) {
  final key = channelSecret32(secret);
  return (
    secret: key,
    hash: CryptoUtils.sha256(key.sublist(0, 16))[0],
  );
}
