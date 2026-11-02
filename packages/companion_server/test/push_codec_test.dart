import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('quantization and key prefixes', () {
    test('snrByte rounds, clamps, and wraps to an unsigned byte', () {
      expect(snrByte(6), 24);
      expect(snrByte(-1), 252);
      expect(snrByte(100), 127);
      expect(snrByte(-100), 128);
    });

    test('rssiByte clamps and wraps to an unsigned byte', () {
      expect(rssiByte(-70), 186);
      expect(rssiByte(200), 127);
      expect(rssiByte(-200), 128);
    });

    test('keyPrefix truncates but never pads', () {
      expect(keyPrefix(Uint8List.fromList([1, 2, 3]), 2), [1, 2]);
      expect(keyPrefix(Uint8List.fromList([1, 2]), 6), [1, 2]);
    });
  });

  group('push frames', () {
    test('msg waiting and contacts full are one byte', () {
      expect(encodePushMsgWaiting(), [0x83]);
      expect(encodePushContactsFull(), [0x90]);
    });

    test('send confirmed carries the ack and trip time little-endian', () {
      expect(
        encodePushSendConfirmed(0x01020304, tripTimeMs: 5),
        [0x82, 4, 3, 2, 1, 5, 0, 0, 0],
      );
    });

    test('advert-style pushes use the full key or a short key as-is', () {
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      expect(encodePushAdvert(key), [0x80, ...key]);
      expect(encodePushPathUpdated(key), [0x81, ...key]);
      expect(encodePushContactDeleted(key), [0x8F, ...key]);
      expect(encodePushAdvert(Uint8List.fromList([1, 2])), [0x80, 1, 2]);
    });

    test('new advert carries an already-encoded contact frame', () {
      expect(
          encodePushNewAdvert(Uint8List.fromList([9, 8, 7])), [0x8A, 9, 8, 7]);
    });

    test('telemetry, binary, and status responses reserve a zero byte', () {
      final prefix = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
      expect(
        encodePushTelemetryResponse(prefix, Uint8List.fromList([9])),
        [0x8B, 0, 1, 2, 3, 4, 5, 6, 9],
      );
      expect(
        encodePushBinaryResponse(0x01020304, Uint8List.fromList([9])),
        [0x8C, 0, 4, 3, 2, 1, 9],
      );
      expect(
        encodePushStatusResponse(prefix, Uint8List.fromList([9])),
        [0x87, 0, 1, 2, 3, 4, 5, 6, 9],
      );
    });

    test('raw RX keeps a raw RSSI byte; raw data clamps it', () {
      expect(
        encodePushRawRxData(6, -70, Uint8List.fromList([1, 2])),
        [0x88, 24, 186, 1, 2],
      );
      expect(
        encodePushRawRxData(6, 300, Uint8List.fromList([1])),
        [0x88, 24, 44, 1],
      );
      expect(
        encodePushRawData(6, -70, Uint8List.fromList([1, 2])),
        [0x84, 24, 186, 0xFF, 1, 2],
      );
    });

    test('path discovery uses explicit path lengths', () {
      expect(
        encodePushPathDiscoveryResponse(
          Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]),
          2,
          Uint8List.fromList([0xAA, 0xBB]),
          1,
          Uint8List.fromList([0xCC]),
        ),
        [0x8D, 0, 1, 2, 3, 4, 5, 6, 2, 0xAA, 0xBB, 1, 0xCC],
      );
    });

    test('login success has legacy and full layouts', () {
      final prefix = Uint8List.fromList([1, 2, 3, 4, 5, 6]);
      expect(
        encodePushLoginSuccess(prefix, legacy: true),
        [0x85, 0, 1, 2, 3, 4, 5, 6],
      );
      expect(
        encodePushLoginSuccess(
          prefix,
          permissions: 0x0F,
          serverTag: 0x01020304,
          acl: 0x0A,
          firmwareVer: 12,
        ),
        [0x85, 0x0F, 1, 2, 3, 4, 5, 6, 4, 3, 2, 1, 0x0A, 12],
      );
      expect(encodePushLoginFail(prefix), [0x86, 0, 1, 2, 3, 4, 5, 6]);
    });

    test('control data quantizes both signal fields', () {
      expect(
        encodePushControlData(-1, -70, 2, Uint8List.fromList([1, 2])),
        [0x8E, 252, 186, 2, 1, 2],
      );
    });

    test('trace data matches the firmware layout', () {
      expect(
        encodePushTraceData(
          4,
          2,
          0x01020304,
          0x05060708,
          Uint8List.fromList([0xAA, 0xBB]),
          Uint8List.fromList([24, 20]),
          16,
        ),
        [
          0x89, 0, 4, 2, 4, 3, 2, 1, 8, 7, 6, 5, 0xAA, 0xBB, 24, 20, 16, //
        ],
      );
    });
  });

  group('reply frames', () {
    test('current time is little-endian', () {
      expect(encodeCurrTime(0x01020304), [9, 4, 3, 2, 1]);
    });

    test('sent defaults to ten seconds and accepts a per-command override', () {
      const result = SentResult(
        success: true,
        isFlood: true,
        expectedAck: 0x01020304,
        timeoutMs: 7,
      );
      expect(encodeSent(result), [6, 1, 4, 3, 2, 1, 7, 0, 0, 0]);
      expect(
        encodeSent(const SentResult(success: true, expectedAck: 1)),
        [6, 0, 1, 0, 0, 0, 0x10, 0x27, 0, 0],
      );
      expect(
        encodeSent(
          const SentResult(success: true, expectedAck: 1),
          defaultTimeoutMs: 5000,
        ),
        [6, 0, 1, 0, 0, 0, 0x88, 0x13, 0, 0],
      );
      expect(
        encodeSentValues(isFlood: false, expectedAck: 2, timeoutMs: 3),
        [6, 0, 2, 0, 0, 0, 3, 0, 0, 0],
      );
    });
  });

  group('message frames', () {
    final key = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7]);
    final direct = QueuedMessage(
      senderKey: key,
      pathLen: 2,
      timestamp: 0x01020304,
      text: 'hi',
      snr: 6,
    );

    test('direct V3 and legacy layouts', () {
      expect(
        encodeMessageFrame(direct, appTargetVer: 3),
        [16, 24, 0, 0, 1, 2, 3, 4, 5, 6, 2, 0, 4, 3, 2, 1, 0x68, 0x69],
      );
      expect(
        encodeMessageFrame(direct, appTargetVer: 2),
        [7, 1, 2, 3, 4, 5, 6, 2, 0, 4, 3, 2, 1, 0x68, 0x69],
      );
    });

    test('short sender keys are zero-padded to six bytes', () {
      expect(
        encodeMessageFrame(
          QueuedMessage(
            senderKey: Uint8List.fromList([1, 2]),
            pathLen: 0,
            timestamp: 1,
            text: 'x',
          ),
          appTargetVer: 2,
        ),
        [7, 1, 2, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0x78],
      );
    });

    test('channel text V3 and legacy layouts', () {
      final channel = QueuedMessage(
        senderKey: Uint8List(0),
        isChannel: true,
        channelIdx: 4,
        pathLen: 1,
        timestamp: 0x01020304,
        text: 'hi',
        snr: 6,
      );
      expect(
        encodeMessageFrame(channel, appTargetVer: 3),
        [17, 24, 0, 0, 4, 1, 0, 4, 3, 2, 1, 0x68, 0x69],
      );
      expect(
        encodeMessageFrame(channel, appTargetVer: 2),
        [8, 4, 1, 0, 4, 3, 2, 1, 0x68, 0x69],
      );
    });

    test('channel data truncates to the push payload limit', () {
      final payload =
          Uint8List.fromList(List.generate(maxChannelDataLength + 2, (i) => i));
      final frame = encodeMessageFrame(
        QueuedMessage(
          senderKey: Uint8List(0),
          isChannel: true,
          channelIdx: 1,
          pathLen: 0,
          channelDataType: 0x1234,
          channelDataPayload: payload,
        ),
        appTargetVer: 3,
      );
      expect(frame[0], respCodeChannelDataRecv);
      expect(frame[1], 0);
      expect(frame.sublist(2, 6), [0, 0, 1, 0]);
      expect(frame.sublist(6, 9), [0x34, 0x12, maxChannelDataLength]);
      expect(frame.sublist(9), payload.sublist(0, maxChannelDataLength));
    });
  });
}
