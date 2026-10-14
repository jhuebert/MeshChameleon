import 'dart:convert';
import 'dart:typed_data';

import 'buffer.dart';
import 'constants.dart';
import 'crypto.dart';
import 'identity.dart';
import 'models.dart';
import 'packet.dart';

/// Builds MeshCore on-air packets. Ported from `openhop_core` `PacketBuilder`.
class PacketBuilder {
  const PacketBuilder._();

  static int _routeTypeValue(bool hasPath) =>
      hasPath ? routeTypeDirect : routeTypeFlood;

  static Packet _packet(int header, List<int> payload) {
    final p = Packet()
      ..header = header
      ..payload = Uint8List.fromList(payload);
    return p;
  }

  /// Encode advert application data (`flags | [lat/lon] | name`).
  static Uint8List encodeAdvertData({
    required String name,
    double lat = 0.0,
    double lon = 0.0,
    int flags = advertFlagIsChatNode,
    int maxAdvertDataSize = 96,
  }) {
    final buf = BufferWriter();
    var finalFlags = flags;
    final hasLocation = lat != 0.0 || lon != 0.0;
    if (hasLocation) finalFlags |= advertFlagHasLocation;
    if (name.isNotEmpty) finalFlags |= advertFlagHasName;
    buf.writeByte(finalFlags);
    if (hasLocation) {
      buf.writeInt32Le((lat * 1e6).round());
      buf.writeInt32Le((lon * 1e6).round());
    }
    if (name.isNotEmpty) {
      final remaining = maxAdvertDataSize - buf.length;
      final nameBytes = BufferWriter()..writeString(name);
      buf.writeBytes(nameBytes.toBytes().take(remaining).toList());
    }
    return buf.toBytes();
  }

  /// Create a signed self-advert packet.
  static Future<Packet> createAdvert({
    required LocalIdentity identity,
    required String name,
    double lat = 0.0,
    double lon = 0.0,
    int flags = advertFlagIsChatNode,
    bool flood = true,
    int? timestamp,
  }) async {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final pubkey = identity.publicKey;
    final appdata = encodeAdvertData(name: name, lat: lat, lon: lon, flags: flags);
    final body = Uint8List.fromList([
      ...pubkey,
      ...(BufferWriter()..writeUInt32Le(ts)).toBytes(),
      ...appdata,
    ]);
    final signature = await identity.sign(body);
    final payload = Uint8List.fromList([
      ...pubkey,
      ...(BufferWriter()..writeUInt32Le(ts)).toBytes(),
      ...signature,
      ...appdata,
    ]);
    return _packet(
      Packet.createHeader(payloadTypeAdvert, flood ? routeTypeFlood : routeTypeDirect),
      payload,
    );
  }

  /// Truncated 4-byte ACK hash for a message sent by [senderPubkey].
  ///
  /// Matches the firmware: `sha256(timestamp | flags | text | sender_pubkey)`.
  static Uint8List ackHash({
    required int timestamp,
    required int flagsByte,
    required List<int> text,
    required Uint8List senderPubkey,
  }) {
    final input = BufferWriter()
      ..writeUInt32Le(timestamp)
      ..writeByte(flagsByte & 0xFF)
      ..writeBytes(text.where((b) => b != 0).toList());
    return CryptoUtils.sha256([...input.toBytes(), ...senderPubkey])
        .sublist(0, 4);
  }

  /// Create an ACK hash packet for a received message.
  static Packet createAck({
    required Uint8List senderPubkey,
    required int timestamp,
    required int attempt,
    required List<int> text,
  }) {
    if (senderPubkey.length != pubKeySize) {
      throw ArgumentError('pubkey must be 32 bytes');
    }
    final digest = ackHash(
      timestamp: timestamp,
      flagsByte: attempt,
      text: text,
      senderPubkey: senderPubkey,
    );
    return _packet(Packet.createHeader(payloadTypeAck, routeTypeDirect),
        digest);
  }

  /// Create an encrypted return-path packet carrying [extra] (e.g. an ACK
  /// hash), matching the firmware's `Mesh::createPathReturn`. Used to
  /// acknowledge a *flooded* direct message so the sender learns the path back
  /// and receives the ACK.
  static Packet createPathReturn({
    required int destHashByte,
    required int srcHashByte,
    required Uint8List secret,
    required List<int> path,
    required int pathLenEncoded,
    required int extraType,
    required List<int> extra,
  }) {
    final inner = BufferWriter()..writeByte(pathLenEncoded & 0xFF);
    inner.writeBytes(path);
    inner.writeByte(extraType & 0xFF);
    inner.writeBytes(extra);
    final aesKey = secret.sublist(0, 16);
    final cipher = CryptoUtils.encryptThenMac(aesKey, secret, inner.toBytes());
    final payload = Uint8List.fromList([destHashByte, srcHashByte, ...cipher]);
    return _packet(
        Packet.createHeader(payloadTypePath, routeTypeFlood), payload);
  }

  /// Compute the ACK CRC for an outgoing direct message.
  static int computeAckCrc({
    required int timestamp,
    required int flagsByte,
    required String message,
    required Uint8List selfPubkey,
  }) {
    final h = ackHash(
      timestamp: timestamp,
      flagsByte: flagsByte,
      text: utf8.encode(message),
      senderPubkey: selfPubkey,
    );
    return h[0] | (h[1] << 8) | (h[2] << 16) | (h[3] << 24);
  }

  /// Build an encrypted direct text message for [contact].
  ///
  /// Returns the packet and the ACK CRC expected from the recipient.
  static Future<(Packet, int)> createTextMessage({
    required Contact contact,
    required LocalIdentity identity,
    required String message,
    int attempt = 0,
    int txtType = txtTypePlain,
    int? timestamp,
  }) async {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final flagsByte = ((txtType & 0x3F) << 2) | (attempt & 0x03);
    final plaintext = BufferWriter()
      ..writeUInt32Le(ts)
      ..writeByte(flagsByte)
      ..writeString(message)
      ..writeByte(0);

    final secret = await identity.sharedSecret(contact.publicKey);
    final aesKey = secret.sublist(0, 16);
    final cipher = CryptoUtils.encryptThenMac(aesKey, secret, plaintext.toBytes());

    final destHash = contact.publicKey[0];
    final srcHash = identity.publicKey[0];
    final payload = Uint8List.fromList([destHash, srcHash, ...cipher]);

    final ackCrc = computeAckCrc(
      timestamp: ts,
      flagsByte: flagsByte,
      message: message,
      selfPubkey: identity.publicKey,
    );

    final hasPath = contact.outPath.isNotEmpty && contact.outPathLen > 0;
    final pkt = _packet(
      Packet.createHeader(payloadTypeTxtMsg, _routeTypeValue(hasPath)),
      payload,
    );
    if (hasPath) {
      pkt.setPath(contact.outPath, contact.outPathLen);
    }
    return (pkt, ackCrc);
  }

  /// Build an encrypted group/channel text message.
  static Packet createGroupText({
    required Channel channel,
    required String message,
    required String senderName,
    int? timestamp,
  }) {
    final secret = Uint8List(32);
    secret.setRange(0, channel.secret.length.clamp(0, 32), channel.secret);
    final channelHash = CryptoUtils.sha256(secret.sublist(0, 16))[0];
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final content = '$senderName: $message';
    final plaintext = BufferWriter()
      ..writeUInt32Le(ts)
      ..writeByte(0x00)
      ..writeString(content);
    final cipher = CryptoUtils.encryptThenMac(secret.sublist(0, 16), secret, plaintext.toBytes());
    final payload = Uint8List.fromList([channelHash, ...cipher]);
    return _packet(Packet.createHeader(payloadTypeGrpTxt, routeTypeFlood), payload);
  }

  /// Build a protocol request (repeater status/telemetry/etc.).
  static Future<Packet> createProtocolRequest({
    required Contact contact,
    required LocalIdentity identity,
    required int protocolCode,
    List<int> data = const [],
    int? timestamp,
  }) async {
    final ts = timestamp ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final plaintext = BufferWriter()
      ..writeUInt32Le(ts)
      ..writeByte(protocolCode)
      ..writeBytes(data);
    final secret = await identity.sharedSecret(contact.publicKey);
    final aesKey = secret.sublist(0, 16);
    final cipher = CryptoUtils.encryptThenMac(aesKey, secret, plaintext.toBytes());
    final payload = Uint8List.fromList([
      contact.publicKey[0],
      identity.publicKey[0],
      ...cipher,
    ]);
    final hasPath = contact.outPath.isNotEmpty && contact.outPathLen > 0;
    final pkt = _packet(
      Packet.createHeader(payloadTypeReq, _routeTypeValue(hasPath)),
      payload,
    );
    if (hasPath) pkt.setPath(contact.outPath, contact.outPathLen);
    return pkt;
  }

  /// Verify an advert packet and extract its encoded appdata.
  static Future<bool> verifyAdvert(Uint8List payload) async {
    // payload = pubkey(32) + timestamp(4) + signature(64) + appdata(...)
    if (payload.length < pubKeySize + timestampSize + signatureSize) return false;
    final pubkey = payload.sublist(0, pubKeySize);
    final ts = payload.sublist(pubKeySize, pubKeySize + timestampSize);
    final signature = payload.sublist(pubKeySize + timestampSize,
        pubKeySize + timestampSize + signatureSize);
    final appdata = payload.sublist(pubKeySize + timestampSize + signatureSize);
    return LocalIdentity.verify(
      Uint8List.fromList([...pubkey, ...ts, ...appdata]),
      signature,
      pubkey,
    );
  }

  /// Decode advert appdata into flag/location/name.
  static AdvertData decodeAdvertData(List<int> appdata) {
    if (appdata.isEmpty) return const AdvertData();
    final reader = BufferReader(Uint8List.fromList(appdata));
    final flags = reader.readByte();
    double lat = 0.0;
    double lon = 0.0;
    if (flags & advertFlagHasLocation != 0 && reader.remaining >= 8) {
      lat = reader.readInt32Le() / 1e6;
      lon = reader.readInt32Le() / 1e6;
    }
    String name = '';
    if (flags & advertFlagHasName != 0 && reader.remaining > 0) {
      name = reader.readCString();
    }
    return AdvertData(flags: flags, lat: lat, lon: lon, name: name);
  }
}

/// Decoded advert application data.
class AdvertData {
  const AdvertData({
    this.flags = 0,
    this.lat = 0.0,
    this.lon = 0.0,
    this.name = '',
  });

  final int flags;
  final double lat;
  final double lon;
  final String name;
}
