import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Device link connection state.
enum LinkState { disconnected, connecting, connected }

/// Callback invoked for every raw over-air frame the device forwards.
typedef RawRxListener = void Function(double snr, int rssi, Uint8List raw);

/// Abstraction over a MeshCore companion device used purely as a radio.
abstract class RadioLink {
  Future<void> connect();
  Future<void> disconnect();
  Stream<LinkState> get state;
  LinkState get currentState;

  /// Transmit an arbitrary MeshCore packet on air.
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]);

  /// Register the callback for received raw frames.
  void setRawRxListener(RawRxListener? listener);

  Future<DeviceInfo> deviceInfo();
  Future<ParsedSelfInfo> selfInfo();
  Future<RadioParams> radioParams();

  /// Write radio parameters. When [clientRepeat] is supplied it is encoded
  /// explicitly (0 or 1); `null` leaves the optional byte out.
  Future<void> setRadioParams(RadioParams params, {bool? clientRepeat});
  Future<void> setTxPower(int dbm);

  /// Reboot the device (`CMD_REBOOT`).
  ///
  /// The firmware reboots the hardware — needed for saved radio-pref changes
  /// (`CMD_SET_RADIO_PARAMS`) to take effect — and does not send a reply.
  Future<void> reboot();

  /// Power the device off through the physical CLI (`CMD_RUN_CLI_COMMAND`
  /// `poweroff`, firmware v14+). No normal reply is expected.
  Future<void> shutdown();
  Future<BatteryReading?> battery();

  /// Read the device's radio tuning parameters (`CMD_GET_TUNING_PARAMS`).
  Future<TuningParams> tuningParams();

  /// Write the device's radio tuning parameters (`CMD_SET_TUNING_PARAMS`).
  Future<void> setTuningParams(TuningParams params);

  /// Set the device's path-hash mode (`CMD_SET_PATH_HASH_MODE`, fw v10+).
  Future<void> setPathHashMode(int mode);

  /// Run a CLI command on the device (`CMD_RUN_CLI_COMMAND`, fw v14+).
  ///
  /// Returns the CLI reply text (`RESP_CODE_CLI_REPLY`).
  Future<String> runCliCommand(String command);

  /// Ask the device for its 64-byte private key (`CMD_EXPORT_PRIVATE_KEY`).
  ///
  /// Returns the expanded key, or null when the firmware disables export
  /// (`RESP_CODE_DISABLED`). The returned key is secret: never log it.
  Future<Uint8List?> exportPrivateKey();

  /// The device's allowed repeat-frequency ranges
  /// (`CMD_GET_ALLOWED_REPEAT_FREQ`): raw `[lower(4)][upper(4)]...` bytes.
  Future<Uint8List> getAllowedRepeatFreq();
}

/// Frames the proxy sends to the device (the device-facing subset).
class DeviceFrames {
  const DeviceFrames._();

  static Uint8List deviceQuery({int appVersion = appProtocolVersion}) =>
      Uint8List.fromList([cmdDeviceQuery, appVersion]);

  static Uint8List appStart({
    int appVersion = appProtocolVersion,
    String appName = 'MeshCoreProxy',
  }) {
    final nameBytes = BufferWriter()..writeString(appName);
    return Uint8List.fromList([
      cmdAppStart,
      appVersion,
      0,
      0,
      0,
      0,
      0,
      0,
      ...nameBytes.toBytes(),
      0,
    ]);
  }

  static Uint8List getBattAndStorage() =>
      Uint8List.fromList([cmdGetBattAndStorage]);

  static Uint8List sendRawPacket(Uint8List packet, [int priority = 0]) =>
      Uint8List.fromList([cmdSendRawPacket, priority, ...packet]);

  static Uint8List setRadioParams(
    RadioParams params, {
    bool? clientRepeat,
  }) {
    final w = BufferWriter()
      ..writeByte(cmdSetRadioParams)
      // Firmware expects frequency in kHz and bandwidth in Hz.
      ..writeUInt32Le(params.frequencyHz ~/ 1000)
      ..writeUInt32Le(params.bandwidthHz)
      ..writeByte(params.spreadingFactor)
      ..writeByte(params.codingRate);
    if (clientRepeat != null) w.writeByte(clientRepeat ? 1 : 0);
    return w.toBytes();
  }

  static Uint8List setTxPower(int dbm) =>
      Uint8List.fromList([cmdSetRadioTxPower, dbm & 0xFF]);

  static Uint8List reboot() =>
      Uint8List.fromList([cmdReboot, ...'reboot'.codeUnits]);

  static Uint8List shutdown() => runCliCommand('poweroff');

  static Uint8List getTuningParams() =>
      Uint8List.fromList([cmdGetTuningParams]);

  static Uint8List setTuningParams(TuningParams params) => (BufferWriter()
        ..writeByte(cmdSetTuningParams)
        ..writeUInt32Le(params.rxDelayBaseMs)
        ..writeUInt32Le(params.airtimeFactorMs))
      .toBytes();

  static Uint8List setPathHashMode(int mode) =>
      Uint8List.fromList([cmdSetPathHashMode, 0, mode & 0xFF]);

  static Uint8List runCliCommand(String command) => Uint8List.fromList([
        cmdRunCliCommand,
        ...(BufferWriter()..writeString(command)).toBytes(),
      ]);

  static Uint8List exportPrivateKey() =>
      Uint8List.fromList([cmdExportPrivateKey]);

  static Uint8List getAllowedRepeatFreq() =>
      Uint8List.fromList([cmdGetAllowedRepeatFreq]);
}

/// Parse a reply to `CMD_EXPORT_PRIVATE_KEY`.
///
/// Returns the 64-byte expanded key, or null when the firmware disables export
/// (`RESP_CODE_DISABLED`). Throws on a truncated or unexpected reply. The key is
/// secret; callers must not log it.
Uint8List? parsePrivateKeyReply(Uint8List frame) {
  if (frame.isNotEmpty && frame[0] == respCodePrivateKey) {
    if (frame.length < 1 + privateKeySize) {
      throw StateError('truncated PRIVATE_KEY reply');
    }
    return Uint8List.fromList(frame.sublist(1, 1 + privateKeySize));
  }
  if (frame.isNotEmpty && frame[0] == respCodeDisabled) return null;
  throw StateError(
    'unexpected private-key reply ${frame.isEmpty ? '(empty)' : frame[0]}',
  );
}

/// Parsed `RESP_CODE_SELF_INFO` radio parameters and node name.
class ParsedSelfInfo {
  const ParsedSelfInfo({
    required this.publicKey,
    required this.radioParams,
    required this.nodeName,
    required this.txPowerDbm,
    required this.maxTxPower,
    required this.latitude,
    required this.longitude,
    required this.advType,
  });

  final Uint8List publicKey;
  final RadioParams radioParams;
  final String nodeName;
  final int txPowerDbm;
  final int maxTxPower;
  final double latitude;
  final double longitude;
  final int advType;

  static ParsedSelfInfo? parse(Uint8List frame) {
    if (frame.isEmpty || frame[0] != respCodeSelfInfo) return null;
    try {
      final r = BufferReader(frame);
      r.skipBytes(2);
      final tx = r.readInt8();
      final maxTx = r.readInt8();
      final pubkey = r.readBytes(pubKeySize);
      final lat = r.readInt32Le() / 1e6;
      final lon = r.readInt32Le() / 1e6;
      r.skipBytes(3); // multi_acks, advert_loc_policy, telemetry
      r.skipBytes(1); // manual_add_contacts
      final freq = r.readUInt32Le();
      final bw = r.readUInt32Le();
      final sf = r.readByte();
      final cr = r.readByte();
      final name = r.readCString();
      return ParsedSelfInfo(
        publicKey: pubkey,
        radioParams: RadioParams(
          // SELF_INFO reports frequency in kHz; normalise to Hz.
          frequencyHz: freq * 1000,
          bandwidthHz: bw,
          spreadingFactor: sf,
          codingRate: cr,
          txPowerDbm: tx,
        ),
        nodeName: name,
        txPowerDbm: tx,
        maxTxPower: maxTx,
        latitude: lat,
        longitude: lon,
        advType: frame.length > 1 ? frame[1] : advTypeChat,
      );
    } catch (_) {
      return null;
    }
  }
}

/// A raw frame received from the device's `PUSH_CODE_LOG_RX_DATA`.
class RawRxFrame {
  const RawRxFrame({required this.snr, required this.rssi, required this.raw});

  final double snr;
  final int rssi;
  final Uint8List raw;

  /// Parse `[0x88][snr*4][rssi][raw...]`.
  static RawRxFrame? parse(Uint8List frame) {
    if (frame.length < 4 || frame[0] != pushCodeLogRxData) return null;
    final snrByte = frame[1] >= 0x80 ? frame[1] - 0x100 : frame[1];
    final rssiByte = frame[2] >= 0x80 ? frame[2] - 0x100 : frame[2];
    return RawRxFrame(
      snr: snrByte / 4.0,
      rssi: rssiByte,
      raw: Uint8List.fromList(frame.sublist(3)),
    );
  }
}
