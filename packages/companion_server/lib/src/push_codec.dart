import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Pure encoders for companion push frames and message responses.
///
/// Every function returns the frame body without the TCP serial header. The
/// values are intentionally plain (no bridge or server state) so the wire
/// layouts can be tested byte-for-byte.

/// Quantize an SNR in dB to the signed quarter-dB byte used on the wire.
int snrByte(double snr) => (snr * 4).round().clamp(-128, 127) & 0xFF;

/// Quantize an RSSI in dBm to the signed byte used on the wire.
int rssiByte(int rssi) => rssi.clamp(-128, 127) & 0xFF;

/// The first [length] bytes of [key], or the whole key when it is shorter.
List<int> keyPrefix(Uint8List key, int length) =>
    key.length <= length ? key : key.sublist(0, length);

/// Encode [text] truncated to at most [maxBytes] UTF-8 bytes.
///
/// Stock firmware copies raw bytes and may cut a UTF-8 sequence when the
/// companion frame is full; mirror that so frame lengths match.
Uint8List textBytesWithin(String text, int maxBytes) {
  if (maxBytes <= 0) return Uint8List(0);
  final bytes = utf8.encode(text);
  return Uint8List.fromList(
      bytes.length <= maxBytes ? bytes : bytes.sublist(0, maxBytes));
}

/// The four signed-message prefix bytes, zero-padded when absent.
Uint8List signedSenderPrefix(QueuedMessage msg) {
  final out = Uint8List(4);
  final prefix = msg.senderPrefix;
  if (prefix != null) {
    out.setRange(0, prefix.length.clamp(0, 4), prefix);
  }
  return out;
}

/// `PUSH_CODE_MSG_WAITING`.
Uint8List encodePushMsgWaiting() => Uint8List.fromList([pushCodeMsgWaiting]);

/// `PUSH_CODE_SEND_CONFIRMED`.
Uint8List encodePushSendConfirmed(int ackCrc, {int tripTimeMs = 0}) =>
    (BufferWriter()
          ..writeByte(pushCodeSendConfirmed)
          ..writeUInt32Le(ackCrc)
          ..writeUInt32Le(tripTimeMs))
        .toBytes();

/// `PUSH_CODE_ADVERT`.
Uint8List encodePushAdvert(Uint8List pubkey) => Uint8List.fromList([
      pushCodeAdvert,
      ...keyPrefix(pubkey, pubKeySize),
    ]);

/// `PUSH_CODE_NEW_ADVERT`.
Uint8List encodePushNewAdvert(Uint8List contactFrame) =>
    Uint8List.fromList([pushCodeNewAdvert, ...contactFrame]);

/// `PUSH_CODE_CONTACT_DELETED`.
Uint8List encodePushContactDeleted(Uint8List pubkey) => Uint8List.fromList([
      pushCodeContactDeleted,
      ...keyPrefix(pubkey, pubKeySize),
    ]);

/// `PUSH_CODE_CONTACTS_FULL`.
Uint8List encodePushContactsFull() =>
    Uint8List.fromList([pushCodeContactsFull]);

/// `PUSH_CODE_PATH_UPDATED`.
Uint8List encodePushPathUpdated(Uint8List pubkey) => Uint8List.fromList([
      pushCodePathUpdated,
      ...keyPrefix(pubkey, pubKeySize),
    ]);

/// `PUSH_CODE_TELEMETRY_RESPONSE`.
Uint8List encodePushTelemetryResponse(
  Uint8List pubkeyPrefix6,
  Uint8List data,
) =>
    Uint8List.fromList([
      pushCodeTelemetryResponse,
      0,
      ...keyPrefix(pubkeyPrefix6, keyPrefix6),
      ...data,
    ]);

/// `PUSH_CODE_BINARY_RESPONSE`.
Uint8List encodePushBinaryResponse(int tag, Uint8List data) =>
    Uint8List.fromList([
      pushCodeBinaryResponse,
      0,
      tag & 0xFF,
      (tag >> 8) & 0xFF,
      (tag >> 16) & 0xFF,
      (tag >> 24) & 0xFF,
      ...data,
    ]);

/// `PUSH_CODE_LOG_RX_DATA`.
Uint8List encodePushRawRxData(double snr, int rssi, Uint8List raw) =>
    Uint8List.fromList([
      pushCodeLogRxData,
      snrByte(snr),
      rssi & 0xFF,
      ...raw,
    ]);

/// `PUSH_CODE_RAW_DATA`.
Uint8List encodePushRawData(double snr, int rssi, Uint8List payload) =>
    Uint8List.fromList([
      pushCodeRawData,
      snrByte(snr),
      rssiByte(rssi),
      0xFF,
      ...payload,
    ]);

/// `PUSH_CODE_PATH_DISCOVERY_RESPONSE`.
Uint8List encodePushPathDiscoveryResponse(
  Uint8List pubkeyPrefix6,
  int outPathLen,
  Uint8List outPath,
  int inPathLen,
  Uint8List inPath,
) =>
    (BufferWriter()
          ..writeByte(pushCodePathDiscoveryResponse)
          ..writeByte(0) // reserved
          ..writeBytes(keyPrefix(pubkeyPrefix6, keyPrefix6))
          ..writeByte(outPathLen & 0xFF)
          ..writeBytes(outPath)
          ..writeByte(inPathLen & 0xFF)
          ..writeBytes(inPath))
        .toBytes();

/// `PUSH_CODE_LOGIN_SUCCESS`.
Uint8List encodePushLoginSuccess(
  Uint8List pubkeyPrefix6, {
  bool legacy = false,
  int permissions = 0,
  int serverTag = 0,
  int acl = 0,
  int firmwareVer = 0,
}) {
  final w = BufferWriter()
    ..writeByte(pushCodeLoginSuccess)
    ..writeByte(legacy ? 0 : (permissions & 0xFF))
    ..writeBytes(keyPrefix(pubkeyPrefix6, keyPrefix6));
  if (!legacy) {
    w
      ..writeUInt32Le(serverTag)
      ..writeByte(acl & 0xFF)
      ..writeByte(firmwareVer & 0xFF);
  }
  return w.toBytes();
}

/// `PUSH_CODE_LOGIN_FAIL`.
Uint8List encodePushLoginFail(Uint8List pubkeyPrefix6) => Uint8List.fromList([
      pushCodeLoginFail,
      0,
      ...keyPrefix(pubkeyPrefix6, keyPrefix6),
    ]);

/// `PUSH_CODE_STATUS_RESPONSE`.
Uint8List encodePushStatusResponse(
  Uint8List pubkeyPrefix6,
  Uint8List data,
) =>
    Uint8List.fromList([
      pushCodeStatusResponse,
      0,
      ...keyPrefix(pubkeyPrefix6, keyPrefix6),
      ...data,
    ]);

/// `PUSH_CODE_CONTROL_DATA`.
Uint8List encodePushControlData(
  double snr,
  int rssi,
  int pathLen,
  Uint8List data,
) =>
    Uint8List.fromList([
      pushCodeControlData,
      snrByte(snr),
      rssiByte(rssi),
      pathLen & 0xFF,
      ...data,
    ]);

/// `PUSH_CODE_TRACE_DATA`.
Uint8List encodePushTraceData(
  int pathLen,
  int flags,
  int tag,
  int authCode,
  Uint8List pathHashes,
  Uint8List pathSnrs,
  int finalSnrByte,
) =>
    (BufferWriter()
          ..writeByte(pushCodeTraceData)
          ..writeByte(0) // reserved
          ..writeByte(pathLen & 0xFF)
          ..writeByte(flags & 0xFF)
          ..writeUInt32Le(tag & 0xFFFFFFFF)
          ..writeUInt32Le(authCode & 0xFFFFFFFF)
          ..writeBytes(pathHashes)
          ..writeBytes(pathSnrs)
          ..writeByte(finalSnrByte & 0xFF))
        .toBytes();

/// `RESP_CODE_CURR_TIME`, also used for the periodic heartbeat push.
Uint8List encodeCurrTime(int seconds) => (BufferWriter()
      ..writeByte(respCodeCurrTime)
      ..writeUInt32Le(seconds))
    .toBytes();

/// `RESP_CODE_SENT` from a bridge send result.
Uint8List encodeSent(SentResult result, {int defaultTimeoutMs = 10000}) =>
    encodeSentValues(
      isFlood: result.isFlood,
      expectedAck: result.expectedAck ?? 0,
      timeoutMs: result.timeoutMs ?? defaultTimeoutMs,
    );

/// `RESP_CODE_SENT` from explicit values.
Uint8List encodeSentValues({
  required bool isFlood,
  required int expectedAck,
  required int timeoutMs,
}) =>
    (BufferWriter()
          ..writeByte(respCodeSent)
          ..writeByte(isFlood ? 1 : 0)
          ..writeUInt32Le(expectedAck)
          ..writeUInt32Le(timeoutMs))
        .toBytes();

/// A `SYNC_NEXT_MESSAGE` response for [msg].
///
/// [appTargetVer] selects the V3 direct/channel layout used by newer clients.
Uint8List encodeMessageFrame(QueuedMessage msg, {required int appTargetVer}) {
  final snr = snrByte(msg.snr);
  final pathLenByte = msg.pathLen < 256 ? msg.pathLen : 0xFF;
  if (msg.isChannel) {
    if (msg.isChannelData) {
      final raw = msg.channelDataPayload ?? Uint8List(0);
      final payload = raw.length > maxChannelDataLength
          ? raw.sublist(0, maxChannelDataLength)
          : raw;
      return (BufferWriter()
            ..writeByte(respCodeChannelDataRecv)
            ..writeByte(snr)
            ..writeByte(0)
            ..writeByte(0)
            ..writeByte(msg.channelIdx)
            ..writeByte(pathLenByte)
            ..writeUInt16Le(msg.channelDataType & 0xFFFF)
            ..writeByte(payload.length)
            ..writeBytes(payload))
          .toBytes();
    }
    final w = BufferWriter();
    if (appTargetVer >= 3) {
      w
        ..writeByte(respCodeChannelMsgRecvV3)
        ..writeByte(snr)
        ..writeByte(0)
        ..writeByte(0)
        ..writeByte(msg.channelIdx)
        ..writeByte(pathLenByte)
        ..writeByte(msg.txtType)
        ..writeUInt32Le(msg.timestamp);
    } else {
      w
        ..writeByte(respCodeChannelMsgRecv)
        ..writeByte(msg.channelIdx)
        ..writeByte(pathLenByte)
        ..writeByte(msg.txtType)
        ..writeUInt32Le(msg.timestamp);
    }
    w.writeBytes(textBytesWithin(msg.text, maxCompanionPayloadSize - w.length));
    return w.toBytes();
  }
  final prefix = msg.senderKey.length >= keyPrefix6
      ? msg.senderKey.sublist(0, keyPrefix6)
      : Uint8List.fromList([
          ...msg.senderKey,
          ...List.filled(keyPrefix6 - msg.senderKey.length, 0),
        ]);
  final w = BufferWriter();
  if (appTargetVer >= 3) {
    w
      ..writeByte(respCodeContactMsgRecvV3)
      ..writeByte(snr)
      ..writeByte(0)
      ..writeByte(0)
      ..writeBytes(prefix)
      ..writeByte(pathLenByte)
      ..writeByte(msg.txtType)
      ..writeUInt32Le(msg.timestamp);
  } else {
    w
      ..writeByte(respCodeContactMsgRecv)
      ..writeBytes(prefix)
      ..writeByte(pathLenByte)
      ..writeByte(msg.txtType)
      ..writeUInt32Le(msg.timestamp);
  }
  if (msg.txtType == txtTypeSigned) {
    w.writeBytes(signedSenderPrefix(msg));
  }
  w.writeBytes(textBytesWithin(msg.text, maxCompanionPayloadSize - w.length));
  return w.toBytes();
}
