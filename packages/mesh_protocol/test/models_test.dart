import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('Contact', () {
    Uint8List key([int first = 7]) => Uint8List(32)..[0] = first;

    test('encodes the companion contact record layout', () {
      final contact = Contact(
        publicKey: key(),
        name: 'peer',
        advType: advTypeRepeater,
        flags: 0x11,
        outPathLen: 2,
        outPath: [0xAA, 0xBB],
        lastAdvertTimestamp: 0x11223344,
        gpsLat: 40.5,
        gpsLon: -96.25,
        lastmod: 0x55667788,
      );
      final body = contact.toCompanionFrameBody();
      expect(body, hasLength(pubKeySize + 3 + maxPathSize + maxNameSize + 16));

      final r = BufferReader(body);
      expect(r.readBytes(pubKeySize), key());
      expect(r.readByte(), advTypeRepeater);
      expect(r.readByte(), 0x11);
      expect(r.readByte(), 2);
      expect(r.readBytes(maxPathSize).sublist(0, 2), [0xAA, 0xBB]);
      expect(r.readBytes(maxNameSize).sublist(0, 4), [0x70, 0x65, 0x65, 0x72]);
      expect(r.readUInt32Le(), 0x11223344);
      expect(r.readInt32Le(), 40500000);
      expect(r.readInt32Le(), -96250000);
      expect(r.readUInt32Le(), 0x55667788);
      expect(r.remaining, 0);
    });

    test('writes 0xFF for an unknown route and clamps explicit lengths', () {
      final unknown = Contact(publicKey: key(), outPathLen: -1);
      expect(unknown.toCompanionFrameBody()[34], 0xFF);

      final clamped = Contact(publicKey: key(), outPathLen: 300);
      expect(clamped.toCompanionFrameBody()[34], 255);
    });

    test('hasDirectRoute distinguishes unknown, zero-hop, and learned paths',
        () {
      expect(Contact(publicKey: key(), outPathLen: -1).hasDirectRoute, isFalse);
      expect(
        Contact(publicKey: key(), outPathLen: 0, outPath: const [])
            .hasDirectRoute,
        isTrue,
      );
      expect(
        Contact(publicKey: key(), outPathLen: 2, outPath: [1, 2])
            .hasDirectRoute,
        isTrue,
      );
      expect(
        Contact(publicKey: key(), outPathLen: 2, outPath: [1]).hasDirectRoute,
        isFalse,
      );
      // 0xFF decodes to a reserved four-byte hash width.
      expect(
        Contact(publicKey: key(), outPathLen: 0xFF, outPath: const [])
            .hasDirectRoute,
        isFalse,
      );
    });

    test('constructor and clone take independent copies', () {
      final path = [1, 2];
      final advert = Uint8List.fromList([9, 9]);
      final contact = Contact(
        publicKey: key(),
        name: 'a',
        outPathLen: 2,
        outPath: path,
        rawAdvert: advert,
      );
      path[0] = 99;
      advert[0] = 1;
      expect(contact.outPath, [1, 2]);
      expect(contact.rawAdvert, [9, 9]);

      final clone = contact.clone();
      expect(clone.publicKey, contact.publicKey);
      expect(clone.publicKey, isNot(same(contact.publicKey)));
      expect(clone.name, contact.name);
      expect(clone.outPath, contact.outPath);
      expect(clone.outPath, isNot(same(contact.outPath)));
      expect(clone.rawAdvert, contact.rawAdvert);
      expect(clone.rawAdvert, isNot(same(contact.rawAdvert)));
      expect(clone.publicKeyHex, contact.publicKeyHex);
    });

    test('publicKeyHex is lowercase hex', () {
      final contact = Contact(publicKey: Uint8List(32)..[0] = 0xAB);
      expect(contact.publicKeyHex, startsWith('ab'));
      expect(contact.publicKeyHex, hasLength(64));
    });

    test('clone preserves null rawAdvert and sync cursor', () {
      final contact = Contact(publicKey: key(), syncSince: 1234);
      final clone = contact.clone();
      expect(clone.rawAdvert, isNull);
      expect(clone.syncSince, 1234);
    });
  });

  group('NodePrefs', () {
    test('packs telemetry permission modes', () {
      final prefs = NodePrefs(
        telemetryModeBase: teleModeAllowAll,
        telemetryModeLocation: teleModeAllowFlags,
        telemetryModeEnvironment: teleModeAllowAll,
      );
      expect(prefs.telemetryModes, 2 | (1 << 2) | (2 << 4));
    });

    test('copyFrom replaces every field, including a cloned scope key', () {
      final target = NodePrefs();
      final key = Uint8List(16)..[0] = 5;
      final source = NodePrefs(
        nodeName: 'source',
        advType: advTypeRoom,
        txPowerDbm: 10,
        maxTxPower: 17,
        frequencyHz: 869000000,
        bandwidthHz: 125000,
        spreadingFactor: 11,
        codingRate: 8,
        latitude: 1.5,
        longitude: -2.5,
        advertLocPolicy: advertLocShare,
        multiAcks: 3,
        telemetryModeBase: 1,
        telemetryModeLocation: 2,
        telemetryModeEnvironment: 3,
        manualAddContacts: 1,
        autoaddConfig: 0x06,
        autoaddMaxHops: 4,
        timezoneOffsetHours: -6,
        clientRepeat: 1,
        pathHashMode: 2,
        rxDelayBaseMs: 100,
        airtimeFactorMs: 200,
        defaultScopeName: 'Region',
        defaultScopeKey: key,
      );
      target.copyFrom(source);
      expect(target.nodeName, 'source');
      expect(target.advType, advTypeRoom);
      expect(target.txPowerDbm, 10);
      expect(target.maxTxPower, 17);
      expect(target.frequencyHz, 869000000);
      expect(target.bandwidthHz, 125000);
      expect(target.spreadingFactor, 11);
      expect(target.codingRate, 8);
      expect(target.latitude, 1.5);
      expect(target.longitude, -2.5);
      expect(target.advertLocPolicy, advertLocShare);
      expect(target.multiAcks, 3);
      expect(target.telemetryModeBase, 1);
      expect(target.telemetryModeLocation, 2);
      expect(target.telemetryModeEnvironment, 3);
      expect(target.manualAddContacts, 1);
      expect(target.autoaddConfig, 0x06);
      expect(target.autoaddMaxHops, 4);
      expect(target.timezoneOffsetHours, -6);
      expect(target.clientRepeat, 1);
      expect(target.pathHashMode, 2);
      expect(target.rxDelayBaseMs, 100);
      expect(target.airtimeFactorMs, 200);
      expect(target.defaultScopeName, 'Region');
      expect(target.defaultScopeKey, key);
      expect(target.defaultScopeKey, isNot(same(key)));
    });

    test('copyFrom clears a null scope key', () {
      final target = NodePrefs(defaultScopeKey: Uint8List(16));
      target.copyFrom(NodePrefs());
      expect(target.defaultScopeKey, isNull);
    });
  });

  group('PhysicalCapabilities', () {
    test('adopts firmware, repeat, and path-hash values from DeviceInfo', () {
      const info = DeviceInfo(
        firmwareVerCode: 12,
        clientRepeat: 1,
        pathHashMode: 2,
      );
      final caps = PhysicalCapabilities.fromDeviceInfo(info, maxTxPower: 17);
      expect(caps.firmwareVerCode, 12);
      expect(caps.maxTxPower, 17);
      expect(caps.clientRepeat, 1);
      expect(caps.pathHashMode, 2);
    });

    test('copyWith replaces only supplied fields', () {
      const caps = PhysicalCapabilities(
        firmwareVerCode: 11,
        maxTxPower: 22,
        clientRepeat: 0,
        pathHashMode: 1,
      );
      final updated = caps.copyWith(firmwareVerCode: 14, clientRepeat: 1);
      expect(updated.firmwareVerCode, 14);
      expect(updated.clientRepeat, 1);
      expect(updated.maxTxPower, 22);
      expect(updated.pathHashMode, 1);
      expect(caps.firmwareVerCode, 11);
    });
  });

  group('TuningParams.parse', () {
    test('parses the scaled millisecond values', () {
      final frame = (BufferWriter()
            ..writeByte(respCodeTuningParams)
            ..writeUInt32Le(250)
            ..writeUInt32Le(1000))
          .toBytes();
      final params = TuningParams.parse(frame)!;
      expect(params.rxDelayBaseMs, 250);
      expect(params.airtimeFactorMs, 1000);
    });

    test('rejects short frames and wrong response codes', () {
      expect(TuningParams.parse(Uint8List(8)), isNull);
      expect(
        TuningParams.parse((BufferWriter()
              ..writeByte(respCodeOk)
              ..writeUInt32Le(1)
              ..writeUInt32Le(2))
            .toBytes()),
        isNull,
      );
    });
  });

  group('RadioStats.parse', () {
    Uint8List frame({
      int code = respCodeStats,
      int type = statsTypeRadio,
      int noise = -110,
      int rssi = -70,
      int snr = 24,
      int tx = 3,
      int rx = 4,
    }) =>
        (BufferWriter()
              ..writeByte(code)
              ..writeByte(type)
              ..writeUInt16Le(noise & 0xFFFF)
              ..writeByte(rssi & 0xFF)
              ..writeByte(snr & 0xFF)
              ..writeUInt32Le(tx)
              ..writeUInt32Le(rx))
            .toBytes();

    test('parses a radio stats frame', () {
      final stats = RadioStats.parse(frame())!;
      expect(stats.noiseFloorDbm, -110);
      expect(stats.lastRssiDbm, -70);
      expect(stats.lastSnrScaled, 24);
      expect(stats.txAirSecs, 3);
      expect(stats.rxAirSecs, 4);
    });

    test('rejects short, wrong-code, and wrong-type frames', () {
      expect(RadioStats.parse(Uint8List(13)), isNull);
      expect(RadioStats.parse(frame(code: respCodeOk)), isNull);
      expect(RadioStats.parse(frame(type: statsTypeCore)), isNull);
    });
  });

  group('QueuedMessage', () {
    test('clone copies sender key and channel data payload', () {
      final msg = QueuedMessage(
        senderKey: Uint8List(32)..[0] = 3,
        txtType: txtTypeSigned,
        timestamp: 100,
        text: 'hello',
        isChannel: true,
        channelIdx: 4,
        pathLen: 7,
        snr: 3.5,
        rssi: -80,
        channelDataType: 0x1234,
        channelDataPayload: Uint8List.fromList([1, 2, 3]),
      );
      final clone = msg.clone();
      expect(clone.senderKey, msg.senderKey);
      expect(clone.senderKey, isNot(same(msg.senderKey)));
      expect(clone.txtType, txtTypeSigned);
      expect(clone.timestamp, 100);
      expect(clone.text, 'hello');
      expect(clone.isChannel, isTrue);
      expect(clone.channelIdx, 4);
      expect(clone.pathLen, 7);
      expect(clone.snr, 3.5);
      expect(clone.rssi, -80);
      expect(clone.channelDataType, 0x1234);
      expect(clone.channelDataPayload, [1, 2, 3]);
      expect(clone.channelDataPayload, isNot(same(msg.channelDataPayload)));
    });

    test('clone preserves a null channel data payload', () {
      final clone = QueuedMessage(senderKey: Uint8List(32)).clone();
      expect(clone.channelDataPayload, isNull);
    });
  });

  group('AdvertPath', () {
    test('clone copies prefix and path bytes', () {
      final record = AdvertPath(
        publicKeyPrefix: Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
        name: 'peer',
        pathLen: 2,
        path: [0xAA, 0xBB],
        recvTimestamp: 99,
      );
      final clone = record.clone();
      expect(clone.publicKeyPrefix, record.publicKeyPrefix);
      expect(clone.publicKeyPrefix, isNot(same(record.publicKeyPrefix)));
      expect(clone.path, record.path);
      expect(clone.path, isNot(same(record.path)));
      expect(clone.name, 'peer');
      expect(clone.pathLen, 2);
      expect(clone.recvTimestamp, 99);
    });

    test('constructor copies its path argument', () {
      final path = [1, 2];
      final record = AdvertPath(publicKeyPrefix: Uint8List(7), path: path);
      path[0] = 9;
      expect(record.path, [1, 2]);
    });
  });

  group('SentResult', () {
    test('failure is unsuccessful and empty', () {
      const result = SentResult.failure();
      expect(result.success, isFalse);
      expect(result.isFlood, isFalse);
      expect(result.expectedAck, isNull);
      expect(result.timeoutMs, isNull);
    });
  });

  group('DeviceInfo defaults', () {
    test('uses the generic firmware code and product version', () {
      const info = DeviceInfo();
      expect(info.firmwareVerCode, defaultFirmwareVerCode);
      expect(info.version, activeDeviceVersion);
      expect(info.manufacturer, 'MeshChameleon');
      expect(info.maxContacts, 1000);
      expect(info.maxChannels, 8);
    });
  });
}
