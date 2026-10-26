import 'dart:typed_data';

import 'buffer.dart';
import 'constants.dart';
import 'paths.dart';

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
    this.syncSince = 0,
    Uint8List? rawAdvert,
  })  : outPath = Uint8List.fromList(outPath),
        rawAdvert = rawAdvert == null ? null : Uint8List.fromList(rawAdvert),
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

  /// Highest signed-message timestamp seen from this contact (room-server sync
  /// cursor), sent on room login.
  int syncSince;

  /// The last raw advert packet received from this contact (or built for self),
  /// used for `CMD_EXPORT_CONTACT`/`CMD_SHARE_CONTACT`. Mirrors the firmware's
  /// per-contact saved advert blob. Null until an advert is seen.
  Uint8List? rawAdvert;

  String get publicKeyHex => bytesToHex(publicKey);

  Uint8List get publicKeyPrefix6 => Uint8List.sublistView(publicKey, 0, 6);

  /// Whether [outPathLen] is a learned direct route.
  ///
  /// Zero is a valid zero-hop direct route and must not be confused with the
  /// `0xFF`/-1 "route unknown" state; both cases have an empty path buffer.
  bool get hasDirectRoute =>
      outPathLen >= 0 &&
      PathUtils.isValidPathLen(outPathLen) &&
      outPath.length >= PathUtils.getByteLength(outPathLen);

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
        syncSince: syncSince,
        rawAdvert: rawAdvert,
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
    this.nodeName = 'MeshChameleon',
    this.advType = advTypeChat,
    this.txPowerDbm = 20,
    this.maxTxPower = defaultMaxTxPowerDbm,
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
    this.autoaddMaxHops = 0,
    this.timezoneOffsetHours = 0,
    this.clientRepeat = 0,
    this.pathHashMode = 0,
    this.rxDelayBaseMs = 0,
    this.airtimeFactorMs = 0,
    this.defaultScopeName = '',
    this.defaultScopeKey,
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

  /// Optional max-hop auto-add limit (0 = unlimited), persisted with the
  /// auto-add configuration.
  int autoaddMaxHops;

  /// Virtual timezone offset in whole hours (does not alter epoch seconds).
  int timezoneOffsetHours;

  int clientRepeat;
  int pathHashMode;

  /// Device radio tuning (`CMD_GET/SET_TUNING_PARAMS`): the receive-delay base
  /// and airtime factor, both in milliseconds ×1000 on the wire.
  int rxDelayBaseMs;
  int airtimeFactorMs;

  /// Default flood scope (`CMD_SET_DEFAULT_FLOOD_SCOPE`): a region name and its
  /// 16-byte transport key, applied to flooded sends unless overridden.
  String defaultScopeName;
  Uint8List? defaultScopeKey;

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
    autoaddMaxHops = other.autoaddMaxHops;
    timezoneOffsetHours = other.timezoneOffsetHours;
    clientRepeat = other.clientRepeat;
    pathHashMode = other.pathHashMode;
    rxDelayBaseMs = other.rxDelayBaseMs;
    airtimeFactorMs = other.airtimeFactorMs;
    defaultScopeName = other.defaultScopeName;
    defaultScopeKey = other.defaultScopeKey == null
        ? null
        : Uint8List.fromList(other.defaultScopeKey!);
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
    this.manufacturer = 'MeshChameleon',
    this.version = 'meshchameleon 0.1.0',
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

/// Capabilities reported by the physical companion used as a radio modem.
///
/// Deliberately separate from the virtual [DeviceInfo] advertised to clients.
/// Physical firmware gates physical CLI support, but virtual protocol codes,
/// board strings, capacities and path-hash mode never come from the radio.
class PhysicalCapabilities {
  const PhysicalCapabilities({
    this.firmwareVerCode = defaultFirmwareVerCode,
    this.maxTxPower = defaultMaxTxPowerDbm,
    this.clientRepeat = 0,
    this.pathHashMode = 0,
  });

  factory PhysicalCapabilities.fromDeviceInfo(
    DeviceInfo info, {
    int maxTxPower = defaultMaxTxPowerDbm,
  }) =>
      PhysicalCapabilities(
        firmwareVerCode: info.firmwareVerCode,
        maxTxPower: maxTxPower,
        clientRepeat: info.clientRepeat,
        pathHashMode: info.pathHashMode,
      );

  final int firmwareVerCode;

  /// Maximum TX power (dBm) reported by the physical SELF_INFO.
  final int maxTxPower;

  /// Physical client-repeat byte (this setting controls the modem).
  final int clientRepeat;

  /// Physical path-hash mode. Stored separately and never used as virtual mode.
  final int pathHashMode;

  PhysicalCapabilities copyWith({
    int? firmwareVerCode,
    int? maxTxPower,
    int? clientRepeat,
    int? pathHashMode,
  }) =>
      PhysicalCapabilities(
        firmwareVerCode: firmwareVerCode ?? this.firmwareVerCode,
        maxTxPower: maxTxPower ?? this.maxTxPower,
        clientRepeat: clientRepeat ?? this.clientRepeat,
        pathHashMode: pathHashMode ?? this.pathHashMode,
      );
}

/// Build the virtual companion's advertised capabilities.
///
/// [clientRepeat] is the physical modem's repeat byte (S2); [pathHashMode] is
/// virtual state. The default is the activated MeshCore 1.18 baseline
/// ([targetFirmwareVerCode]/[targetCompatibilityVersion]); set
/// [targetBaseline] to false only for historical/golden comparisons.
DeviceInfo buildVirtualDeviceInfo({
  int clientRepeat = 0,
  int pathHashMode = 0,
  bool targetBaseline = true,
}) =>
    DeviceInfo(
      firmwareVerCode:
          targetBaseline ? targetFirmwareVerCode : defaultFirmwareVerCode,
      maxContacts: virtualMaxContacts,
      maxChannels: virtualMaxChannels,
      blePin: 0,
      buildDate: '',
      manufacturer: virtualBoardName,
      version: targetBaseline ? targetCompatibilityVersion : activeDeviceVersion,
      clientRepeat: clientRepeat,
      pathHashMode: pathHashMode,
    );

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

/// Device radio tuning parameters (`RESP_CODE_TUNING_PARAMS`). Both values are
/// milliseconds ×1000 on the wire (`rx_delay_base`, `airtime_factor`).
class TuningParams {
  const TuningParams({
    required this.rxDelayBaseMs,
    required this.airtimeFactorMs,
  });

  final int rxDelayBaseMs;
  final int airtimeFactorMs;

  /// Parse `[RESP_CODE_TUNING_PARAMS][rx u32 le][af u32 le]`.
  static TuningParams? parse(Uint8List frame) {
    if (frame.length < 9 || frame[0] != respCodeTuningParams) return null;
    final r = BufferReader(frame)..skipBytes(1);
    return TuningParams(
      rxDelayBaseMs: r.readUInt32Le(),
      airtimeFactorMs: r.readUInt32Le(),
    );
  }
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

/// Parsed `RESP_CODE_STATS` + `STATS_TYPE_RADIO` from the physical companion.
class RadioStats {
  const RadioStats({
    required this.noiseFloorDbm,
    required this.lastRssiDbm,
    required this.lastSnrScaled,
    required this.txAirSecs,
    required this.rxAirSecs,
  });

  final int noiseFloorDbm;
  final int lastRssiDbm;
  final int lastSnrScaled;
  final int txAirSecs;
  final int rxAirSecs;

  /// Parse `[RESP_CODE_STATS][STATS_TYPE_RADIO][noise i16][rssi i8][snr*4 i8]`
  /// followed by the TX/RX airtime counters.
  static RadioStats? parse(Uint8List frame) {
    if (frame.length < 14 ||
        frame[0] != respCodeStats ||
        frame[1] != statsTypeRadio) {
      return null;
    }
    try {
      final r = BufferReader(frame)..skipBytes(2);
      final noiseFloor = r.readInt16Le();
      final lastRssi = r.readInt8();
      final lastSnrScaled = r.readInt8();
      final txAirSecs = r.readUInt32Le();
      final rxAirSecs = r.readUInt32Le();
      return RadioStats(
        noiseFloorDbm: noiseFloor,
        lastRssiDbm: lastRssi,
        lastSnrScaled: lastSnrScaled,
        txAirSecs: txAirSecs,
        rxAirSecs: rxAirSecs,
      );
    } catch (_) {
      return null;
    }
  }
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

  QueuedMessage clone() => QueuedMessage(
        senderKey: Uint8List.fromList(senderKey),
        txtType: txtType,
        timestamp: timestamp,
        text: text,
        isChannel: isChannel,
        channelIdx: channelIdx,
        pathLen: pathLen,
        snr: snr,
        rssi: rssi,
        channelDataType: channelDataType,
        channelDataPayload: channelDataPayload == null
            ? null
            : Uint8List.fromList(channelDataPayload!),
      );
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

  AdvertPath clone() => AdvertPath(
        publicKeyPrefix: Uint8List.fromList(publicKeyPrefix),
        name: name,
        pathLen: pathLen,
        path: path,
        recvTimestamp: recvTimestamp,
      );
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
