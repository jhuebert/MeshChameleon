import 'dart:typed_data';

import 'buffer.dart';
import 'constants.dart';

/// A mesh contact, mirroring the companion contact record.
class Contact {
  Contact({
    required this.publicKey,
    this.name = '',
    this.advType = 0,
    this.flags = 0,
    this.outPathLen = -1,
    List<int> outPath = const <int>[],
    this.lastAdvertTimestamp = 0,
    this.lastmod = 0,
    this.gpsLat = 0.0,
    this.gpsLon = 0.0,
  })  : outPath = Uint8List.fromList(outPath),
        assert(publicKey.length == pubKeySize, 'public key must be 32 bytes');

  final Uint8List publicKey;
  String name;
  int advType;
  int flags;
  int outPathLen;
  Uint8List outPath;
  int lastAdvertTimestamp;
  int lastmod;
  double gpsLat;
  double gpsLon;

  String get publicKeyHex => bytesToHex(publicKey);

  Uint8List get publicKeyPrefix6 => Uint8List.sublistView(publicKey, 0, 6);

  Contact clone() => Contact(
        publicKey: Uint8List.fromList(publicKey),
        name: name,
        advType: advType,
        flags: flags,
        outPathLen: outPathLen,
        outPath: Uint8List.fromList(outPath),
        lastAdvertTimestamp: lastAdvertTimestamp,
        lastmod: lastmod,
        gpsLat: gpsLat,
        gpsLon: gpsLon,
      );
}

/// A group channel (name + 16-byte PSK).
class Channel {
  Channel({required this.name, required this.secret});

  String name;
  Uint8List secret;
}

/// Local node configuration / self info.
class NodePrefs {
  NodePrefs({
    this.nodeName = 'MeshCore Proxy',
    this.advType = advTypeChat,
    this.txPowerDbm = 20,
    this.maxTxPower = 22,
    this.frequencyHz = 915000000,
    this.bandwidthHz = 250000,
    this.spreadingFactor = 10,
    this.codingRate = 5,
    this.latitude = 0.0,
    this.longitude = 0.0,
    this.advertLocPolicy = advertLocNone,
    this.multiAcks = 0,
    this.telemetryModeBase = teleModeDeny,
    this.telemetryModeLocation = teleModeDeny,
    this.telemetryModeEnvironment = teleModeDeny,
    this.manualAddContacts = 0,
    this.autoaddConfig = 0,
    this.clientRepeat = 0,
    this.pathHashMode = 0,
    this.exportPrivateKeyEnabled = false,
  });

  String nodeName;
  int advType;
  int txPowerDbm;
  int maxTxPower;
  int frequencyHz;
  int bandwidthHz;
  int spreadingFactor;
  int codingRate;
  double latitude;
  double longitude;
  int advertLocPolicy;
  int multiAcks;
  int telemetryModeBase;
  int telemetryModeLocation;
  int telemetryModeEnvironment;
  int manualAddContacts;
  int autoaddConfig;
  int clientRepeat;
  int pathHashMode;
  bool exportPrivateKeyEnabled;

  /// `SELF_INFO` telemetry byte: base | location<<2 | environment<<4.
  int get telemetryModes =>
      (telemetryModeBase & 0x03) |
      ((telemetryModeLocation & 0x03) << 2) |
      ((telemetryModeEnvironment & 0x03) << 4);

  /// Copy every field from [other] into this instance, preserving object
  /// identity. Used when restoring preferences loaded from a store.
  void copyFrom(NodePrefs other) {
    nodeName = other.nodeName;
    advType = other.advType;
    txPowerDbm = other.txPowerDbm;
    maxTxPower = other.maxTxPower;
    frequencyHz = other.frequencyHz;
    bandwidthHz = other.bandwidthHz;
    spreadingFactor = other.spreadingFactor;
    codingRate = other.codingRate;
    latitude = other.latitude;
    longitude = other.longitude;
    advertLocPolicy = other.advertLocPolicy;
    multiAcks = other.multiAcks;
    telemetryModeBase = other.telemetryModeBase;
    telemetryModeLocation = other.telemetryModeLocation;
    telemetryModeEnvironment = other.telemetryModeEnvironment;
    manualAddContacts = other.manualAddContacts;
    autoaddConfig = other.autoaddConfig;
    clientRepeat = other.clientRepeat;
    pathHashMode = other.pathHashMode;
    exportPrivateKeyEnabled = other.exportPrivateKeyEnabled;
  }
}

/// Device capabilities returned by `CMD_DEVICE_QUERY`.
class DeviceInfo {
  const DeviceInfo({
    this.firmwareVerCode = defaultFirmwareVerCode,
    this.maxContacts = 1000,
    this.maxChannels = 8,
    this.blePin = 0,
    this.buildDate = '',
    this.manufacturer = 'MeshCore Companion Proxy',
    this.version = 'meshcore-companion-proxy 0.1.0',
    this.clientRepeat = 0,
    this.pathHashMode = 0,
  });

  final int firmwareVerCode;
  final int maxContacts;
  final int maxChannels;
  final int blePin;
  final String buildDate;
  final String manufacturer;
  final String version;
  final int clientRepeat;
  final int pathHashMode;
}

/// Radio parameters read from / written to the device.
class RadioParams {
  const RadioParams({
    required this.frequencyHz,
    required this.bandwidthHz,
    required this.spreadingFactor,
    required this.codingRate,
    this.txPowerDbm = 20,
  });

  final int frequencyHz;
  final int bandwidthHz;
  final int spreadingFactor;
  final int codingRate;
  final int txPowerDbm;
}

/// Battery + storage reading.
class BatteryReading {
  const BatteryReading({
    required this.millivolts,
    required this.storageUsedKb,
    required this.storageTotalKb,
  });

  final int millivolts;
  final int storageUsedKb;
  final int storageTotalKb;
}

/// An inbound message awaiting delivery via `CMD_SYNC_NEXT_MESSAGE`.
class QueuedMessage {
  QueuedMessage({
    required this.senderKey,
    this.txtType = txtTypePlain,
    this.timestamp = 0,
    this.text = '',
    this.isChannel = false,
    this.channelIdx = 0,
    this.pathLen = 0,
    this.snr = 0.0,
    this.rssi = 0,
    this.channelDataType = 0,
    this.channelDataPayload,
  });

  final Uint8List senderKey;
  final int txtType;
  final int timestamp;
  final String text;
  final bool isChannel;
  final int channelIdx;
  final int pathLen;
  final double snr;
  final int rssi;

  /// Non-zero for group *data* (binary) channel messages; [channelDataPayload]
  /// then holds the raw payload and [text] is unused.
  final int channelDataType;
  final Uint8List? channelDataPayload;
}

/// Recently heard advertiser path information.
class AdvertPath {
  AdvertPath({
    required this.publicKeyPrefix,
    this.name = '',
    this.pathLen = 0,
    List<int> path = const <int>[],
    this.recvTimestamp = 0,
  }) : path = Uint8List.fromList(path);

  final Uint8List publicKeyPrefix; // 7 bytes
  final String name;
  final int pathLen;
  final Uint8List path;
  final int recvTimestamp;
}

/// Result of a message send operation.
class SentResult {
  const SentResult({
    required this.success,
    this.isFlood = false,
    this.expectedAck,
    this.timeoutMs,
  });

  const SentResult.failure() : this(success: false);

  final bool success;
  final bool isFlood;
  final int? expectedAck;
  final int? timeoutMs;
}
