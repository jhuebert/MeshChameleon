import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('decodes and verifies an advert envelope', () async {
    final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 1);
    final packet = await PacketBuilder.createAdvert(
      identity: identity,
      name: 'peer',
      lat: 1.5,
      lon: -2.5,
      timestamp: 0x01020304,
      flood: true,
    );

    final advert = PacketBuilder.decodeAdvertPacket(packet.payload);
    expect(advert, isNotNull);
    expect(advert!.publicKey, identity.publicKey);
    expect(advert.timestamp, 0x01020304);
    expect(advert.signature, hasLength(signatureSize));
    expect(advert.appData, isNotEmpty);
    expect(await advert.verify(), isTrue);
  });

  test('rejects short advert envelopes and tampered appdata', () async {
    expect(PacketBuilder.decodeAdvertPacket(Uint8List(10)), isNull);

    final identity = await LocalIdentity.fromSeed(Uint8List(32)..[0] = 2);
    final packet = await PacketBuilder.createAdvert(
      identity: identity,
      name: 'peer',
      timestamp: 1,
    );
    final advert = PacketBuilder.decodeAdvertPacket(packet.payload)!;
    final tampered = AdvertPacket(
      publicKey: advert.publicKey,
      timestamp: advert.timestamp,
      signature: advert.signature,
      appData: Uint8List.fromList([...advert.appData, 0]),
    );
    expect(await tampered.verify(), isFalse);
  });
}
