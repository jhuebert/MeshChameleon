import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'bridge.dart';
import 'command_spec.dart';
import 'metrics.dart';
import 'push_codec.dart';

/// Services the command dispatcher needs from the server.
///
/// This keeps command handlers free of socket, timer, and generation
/// bookkeeping while still letting them emit replies through the server's
/// single frame path.
abstract interface class CompanionCommandHost {
  CompanionBridge get bridge;
  CompanionMetrics get metrics;
  int get appTargetVer;
  int get maxSignDataLen;

  /// Send a command reply through the current client generation.
  void sendFrame(Uint8List payload);

  void sendOk();

  void sendErr(int code);

  void sendDisabled();

  void log(String message);
}

/// Routes companion commands through a declarative table and owns the
/// command-scoped ephemeral state (the signing buffer).
class CompanionCommandDispatcher {
  CompanionCommandDispatcher(this.host);

  final CompanionCommandHost host;
  final List<int> _signBuffer = <int>[];

  /// The command table, keyed by command code. Exposed so diagnostics and
  /// table-driven tests can enumerate the protocol surface.
  late final Map<int, CommandSpec> commands =
      Map<int, CommandSpec>.unmodifiable(_buildCommandTable());

  /// Drop per-client state (a partial `SIGN_START`/`SIGN_DATA` buffer).
  void resetClientState() => _signBuffer.clear();

  /// Clear a partial signing buffer after an app-only reset or lifecycle
  /// change.
  void clearSigningBuffer() => _signBuffer.clear();

  /// Execute one framed command payload (the command byte plus arguments).
  Future<void> handle(Uint8List payload) async {
    if (payload.isEmpty) {
      host.sendErr(errCodeIllegalArg);
      return;
    }
    final cmd = payload[0];
    final data = Uint8List.sublistView(payload, 1);
    host.log('cmd 0x${cmd.toRadixString(16)} len=${payload.length}');
    final spec = commands[cmd];
    if (spec == null) {
      host.metrics.unsupportedCommandReceived();
      host.log('unsupported cmd 0x${cmd.toRadixString(16)}');
      host.sendErr(errCodeUnsupportedCmd);
      return;
    }
    if (data.length < spec.minDataLength) {
      host.sendErr(errCodeIllegalArg);
      return;
    }
    try {
      await spec.handler(data);
    } on CompanionOperationError catch (e) {
      _sendOperationError(e);
    } on FormatException catch (e) {
      host.log('cmd 0x${cmd.toRadixString(16)} invalid input: $e');
      host.sendErr(errCodeIllegalArg);
    } on ArgumentError catch (e) {
      host.log('cmd 0x${cmd.toRadixString(16)} invalid input: $e');
      host.sendErr(errCodeIllegalArg);
    } catch (e) {
      // A handler bug is not the client's bad input. Surface a bad-state reply
      // and make the regression visible in diagnostics instead of masking it
      // as ILLEGAL_ARG.
      host.metrics.internalError();
      host.log('cmd 0x${cmd.toRadixString(16)} internal error: $e');
      host.sendErr(errCodeBadState);
    }
  }

  void _sendOperationError(CompanionOperationError e) {
    if (e.message != null) {
      host.log('physical operation failed: ${e.message}');
    }
    if (e.uncertain) {
      host.log('physical operation outcome is uncertain; no automatic retry');
    }
    if (e.disabled) {
      host.sendDisabled();
    } else {
      host.sendErr(e.code);
    }
  }

  // -------------------------------------------------------------------------
  // Command table
  // -------------------------------------------------------------------------

  Map<int, CommandSpec> _buildCommandTable() => {
        cmdDeviceQuery: CommandSpec(0, _cmdDeviceQuery),
        cmdAppStart: CommandSpec(0, _cmdAppStart),
        cmdGetDeviceTime: CommandSpec(0, (_) => _cmdGetDeviceTime()),
        cmdSetDeviceTime: CommandSpec(4, _cmdSetDeviceTime),
        cmdGetBattAndStorage: CommandSpec(0, (_) => _cmdBattery()),
        cmdGetCustomVars: CommandSpec(0, (_) => _cmdCustomVars()),
        cmdSetCustomVar: CommandSpec(3, _cmdSetCustomVar),
        cmdGetAutoAddConfig: CommandSpec(0, (_) => _cmdGetAutoAddConfig()),
        cmdSetAutoAddConfig: CommandSpec(1, _cmdSetAutoAddConfig),
        cmdSetOtherParams: CommandSpec(1, _cmdSetOtherParams),
        cmdSetRadioParams: CommandSpec(10, _cmdSetRadioParams),
        cmdSetRadioTxPower: CommandSpec(1, _cmdSetTxPower),
        // These commands are intentionally disabled for the proxy: never change
        // physical device settings/state or PIN/reset.
        cmdSetDevicePin: CommandSpec(0, (_) => host.sendDisabled()),
        cmdFactoryReset: CommandSpec(0, (_) => host.sendDisabled()),
        // Virtual identity import/export never touches the physical identity.
        cmdExportPrivateKey: CommandSpec(0, (_) => _cmdExportPrivateKey()),
        cmdImportPrivateKey: CommandSpec(64, _cmdImportPrivateKey),
        cmdGetTuningParams: CommandSpec(0, (_) => _cmdGetTuningParams()),
        cmdSetTuningParams: CommandSpec(8, _cmdSetTuningParams),
        cmdSetPathHashMode: CommandSpec(2, _cmdSetPathHashMode),
        cmdRunCliCommand: CommandSpec(0, _cmdRunCliCommand),
        cmdGetContacts: CommandSpec(0, _cmdGetContacts),
        cmdGetContactByKey: CommandSpec(pubKeySize, _cmdGetContactByKey),
        cmdAddUpdateContact: CommandSpec(36, _cmdAddUpdateContact),
        cmdRemoveContact: CommandSpec(pubKeySize, _cmdRemoveContact),
        cmdResetPath: CommandSpec(pubKeySize, _cmdResetPath),
        cmdGetChannel: CommandSpec(0, _cmdGetChannel),
        cmdSetChannel: CommandSpec(34, _cmdSetChannel),
        cmdSendSelfAdvert: CommandSpec(0, _cmdSendSelfAdvert),
        cmdSetAdvertName: CommandSpec(1, _cmdSetAdvertName),
        cmdSetAdvertLatLon: CommandSpec(8, _cmdSetAdvertLatLon),
        cmdSendTxtMsg: CommandSpec(12, _cmdSendTxt),
        cmdSendChannelTxtMsg: CommandSpec(6, _cmdSendChannelTxt),
        cmdSendChannelData: CommandSpec(4, _cmdSendChannelData),
        cmdSendControlData: CommandSpec(1, _cmdSendControlData),
        cmdSyncNextMessage: CommandSpec(0, (_) => _cmdSyncNextMessage()),
        cmdSignStart: CommandSpec(0, (_) => _cmdSignStart()),
        cmdSignData: CommandSpec(1, _cmdSignData),
        cmdSignFinish: CommandSpec(0, (_) => _cmdSignFinish()),
        cmdGetStats: CommandSpec(0, _cmdGetStats),
        cmdGetAllowedRepeatFreq:
            CommandSpec(0, (_) => _cmdGetAllowedRepeatFreq()),
        cmdGetAdvertPath: CommandSpec(1 + pubKeySize, _cmdGetAdvertPath),
        cmdExportContact: CommandSpec(0, _cmdExportContact),
        cmdImportContact: CommandSpec(1, _cmdImportContact),
        cmdShareContact: CommandSpec(pubKeySize, _cmdShareContact),
        cmdSendBinaryReq: CommandSpec(pubKeySize + 1, _cmdSendBinaryReq),
        cmdSendAnonReq: CommandSpec(pubKeySize + 1, _cmdSendAnonReq),
        cmdSendTelemetryReq: CommandSpec(3, _cmdSendTelemetryReq),
        cmdSendTracePath: CommandSpec(10, _cmdSendTracePath),
        cmdSendPathDiscoveryReq:
            CommandSpec(1 + pubKeySize, _cmdSendPathDiscoveryReq),
        cmdSendLogin: CommandSpec(pubKeySize, _cmdSendLogin),
        cmdSendStatusReq: CommandSpec(pubKeySize, _cmdSendStatusReq),
        cmdSendRawData: CommandSpec(1, _cmdSendRawData),
        cmdSendRawPacket: CommandSpec(3, _cmdSendRawPacket),
        cmdLogout: CommandSpec(pubKeySize, _cmdLogout),
        cmdHasConnection: CommandSpec(pubKeySize, _cmdHasConnection),
        cmdSetFloodScope: CommandSpec(1, _cmdSetFloodScope),
        cmdSetDefaultFloodScope: CommandSpec(0, _cmdSetDefaultFloodScope),
        cmdGetDefaultFloodScope:
            CommandSpec(0, (_) => _cmdGetDefaultFloodScope()),
        cmdReboot: CommandSpec(0, _cmdReboot),
      };

  // -------------------------------------------------------------------------
  // Handshake / info
  // -------------------------------------------------------------------------

  void _cmdDeviceQuery(Uint8List data) {
    if (data.isNotEmpty) {
      host.metrics.appTargetVersionReceived(data[0]);
    }
    final info = host.bridge.getDeviceInfo();
    final w = BufferWriter()
      ..writeByte(respCodeDeviceInfo)
      ..writeByte(info.firmwareVerCode)
      ..writeByte((info.maxContacts ~/ 2).clamp(0, 255))
      ..writeByte(info.maxChannels.clamp(0, 255))
      ..writeUInt32Le(info.blePin);
    w.writeCString(info.buildDate, 12);
    w.writeCString(info.manufacturer, 40);
    w.writeCString(info.version, 20);
    w.writeByte(info.clientRepeat & 0xFF);
    w.writeByte(host.bridge.getPathHashMode() & 0xFF);
    host.sendFrame(w.toBytes());
  }

  void _cmdAppStart(Uint8List data) {
    if (data.isNotEmpty) {
      host.metrics.appTargetVersionReceived(data[0]);
    }
    final prefs = host.bridge.getSelfInfo();
    final pubkey = host.bridge.getPublicKey();
    final w = BufferWriter()
      ..writeByte(respCodeSelfInfo)
      ..writeByte(prefs.advType)
      ..writeByte(prefs.txPowerDbm)
      ..writeByte(prefs.maxTxPower)
      ..writeBytes(pubkey)
      ..writeInt32Le((prefs.latitude * 1e6).round())
      ..writeInt32Le((prefs.longitude * 1e6).round())
      ..writeByte(prefs.multiAcks)
      ..writeByte(prefs.advertLocPolicy)
      ..writeByte(prefs.telemetryModes)
      ..writeByte(prefs.manualAddContacts)
      ..writeUInt32Le(prefs.frequencyHz ~/ 1000) // kHz, as the firmware reports
      ..writeUInt32Le(prefs.bandwidthHz)
      ..writeByte(prefs.spreadingFactor)
      ..writeByte(prefs.codingRate)
      ..writeString(prefs.nodeName);
    host.sendFrame(w.toBytes());
  }

  void _cmdGetDeviceTime() {
    host.sendFrame(encodeCurrTime(host.bridge.getTime()));
  }

  void _cmdSetDeviceTime(Uint8List data) {
    final reader = BufferReader(data);
    final secs = reader.readUInt32Le();
    host.bridge.setTime(secs) ? host.sendOk() : host.sendErr(errCodeIllegalArg);
  }

  Future<void> _cmdBattery() async {
    final b = await host.bridge.getBatteryAndStorage();
    final w = BufferWriter()
      ..writeByte(respCodeBattAndStorage)
      ..writeUInt16Le(b.millivolts)
      ..writeUInt32Le(b.storageUsedKb)
      ..writeUInt32Le(b.storageTotalKb);
    host.sendFrame(w.toBytes());
  }

  void _cmdCustomVars() {
    final vars = host.bridge.getCustomVars();
    final csv = vars.entries.map((e) => '${e.key}:${e.value}').join(',');
    final bytes = csv.length > 140 ? csv.substring(0, 140) : csv;
    final w = BufferWriter()
      ..writeByte(respCodeCustomVars)
      ..writeString(bytes);
    host.sendFrame(w.toBytes());
  }

  Future<void> _cmdSetCustomVar(Uint8List data) async {
    String text;
    try {
      text = utf8.decode(data);
    } on FormatException {
      return host.sendErr(errCodeIllegalArg);
    }
    final sep = text.indexOf(':');
    if (sep < 1) return host.sendErr(errCodeIllegalArg);
    await host.bridge
        .setCustomVar(text.substring(0, sep), text.substring(sep + 1));
    host.sendOk();
  }

  void _cmdGetAutoAddConfig() {
    host.sendFrame(Uint8List.fromList([
      respCodeAutoAddConfig,
      host.bridge.getAutoAddConfig() & 0xFF,
      host.bridge.getAutoAddMaxHops() & 0xFF,
    ]));
  }

  Future<void> _cmdSetAutoAddConfig(Uint8List data) async {
    final maxHops = data.length >= 2 ? data[1].clamp(0, 64) : null;
    await host.bridge.setAutoAddConfig(data[0], maxHops);
    host.sendOk();
  }

  Future<void> _cmdSetOtherParams(Uint8List data) async {
    await host.bridge.setOtherParams(
      manualAddContacts: data[0],
      telemetryModes: data.length >= 2 ? data[1] : null,
      advertLocPolicy: data.length >= 3 ? data[2] : null,
      multiAcks: data.length >= 4 ? data[3] : null,
    );
    host.sendOk();
  }

  // -------------------------------------------------------------------------
  // Radio
  // -------------------------------------------------------------------------

  Future<void> _cmdSetRadioParams(Uint8List data) async {
    final reader = BufferReader(data);
    final freq = reader.readUInt32Le();
    final bw = reader.readUInt32Le();
    final sf = reader.readByte();
    final cr = reader.readByte();
    // Matches the firmware: frequency is in kHz, bandwidth in Hz.
    if (freq < 150000 || freq > 2500000) return host.sendErr(errCodeIllegalArg);
    if (bw < 7000 || bw > 500000) return host.sendErr(errCodeIllegalArg);
    if (sf < 5 || sf > 12 || cr < 5 || cr > 8) {
      return host.sendErr(errCodeIllegalArg);
    }
    bool? clientRepeat;
    if (data.length >= 11) {
      final repeat = data[10];
      if (repeat > 1) return host.sendErr(errCodeIllegalArg);
      clientRepeat = repeat == 1;
    }
    await host.bridge.setRadioParams(
      freq * 1000,
      bw,
      sf,
      cr,
      clientRepeat: clientRepeat,
    );
    host.sendOk();
  }

  Future<void> _cmdSetTxPower(Uint8List data) async {
    final power = data[0] >= 0x80 ? data[0] - 0x100 : data[0];
    await host.bridge.setTxPower(power);
    host.sendOk();
  }

  Future<void> _cmdGetTuningParams() async {
    final params = await host.bridge.getTuningParams();
    final w = BufferWriter()
      ..writeByte(respCodeTuningParams)
      ..writeUInt32Le(params.rxDelayBaseMs)
      ..writeUInt32Le(params.airtimeFactorMs);
    host.sendFrame(w.toBytes());
  }

  Future<void> _cmdSetTuningParams(Uint8List data) async {
    final r = BufferReader(data);
    final rx = r.readUInt32Le();
    final af = r.readUInt32Le();
    await host.bridge.setTuningParams(rx, af);
    host.sendOk();
  }

  Future<void> _cmdSetPathHashMode(Uint8List data) async {
    // [cmd][reserved=0][mode]
    if (data[0] != 0) return host.sendErr(errCodeIllegalArg);
    final mode = data[1];
    if (!isValidPathHashMode(mode)) return host.sendErr(errCodeIllegalArg);
    await host.bridge.setPathHashMode(mode);
    host.sendOk();
  }

  Future<void> _cmdRunCliCommand(Uint8List data) async {
    final lifecycleBefore = host.bridge.lifecycleGeneration;
    String text;
    try {
      text = await host.bridge.runCliCommandBytes(data);
    } on CompanionOperationError catch (e) {
      text = companionOperationErrorText(e);
    } catch (_) {
      text = 'Error: illegal argument';
    }
    if (host.bridge.lifecycleGeneration != lifecycleBefore) {
      _signBuffer.clear();
    }
    host.sendFrame(Uint8List.fromList([
      respCodeCliReply,
      ..._boundedCliReply(utf8.encode(text)),
    ]));
  }

  List<int> _boundedCliReply(List<int> bytes) {
    if (bytes.length <= maxCompanionPayloadSize - 1) return bytes;
    var end = maxCompanionPayloadSize - 1 - 3;
    while (end > 0 && end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return [...bytes.sublist(0, end), ...utf8.encode('...')];
  }

  // -------------------------------------------------------------------------
  // Contacts
  // -------------------------------------------------------------------------

  void _cmdGetContacts(Uint8List data) {
    final since = data.length >= 4 ? BufferReader(data).readUInt32Le() : 0;
    final contacts = host.bridge.getContacts(since: since);
    final start = BufferWriter()
      ..writeByte(respCodeContactsStart)
      ..writeUInt32Le(contacts.length);
    host.sendFrame(start.toBytes());
    var mostRecent = 0;
    for (final c in contacts) {
      host.sendFrame(_contactFrame(c));
      if (c.lastmod > mostRecent) mostRecent = c.lastmod;
    }
    final end = BufferWriter()
      ..writeByte(respCodeEndOfContacts)
      ..writeUInt32Le(mostRecent);
    host.sendFrame(end.toBytes());
  }

  Uint8List _contactFrame(Contact c) =>
      Uint8List.fromList([respCodeContact, ...c.toCompanionFrameBody()]);

  void _cmdGetContactByKey(Uint8List data) {
    final c =
        host.bridge.getPersistentContactByKey(data.sublist(0, pubKeySize));
    if (c == null) return host.sendErr(errCodeNotFound);
    host.sendFrame(_contactFrame(c));
  }

  Future<void> _cmdAddUpdateContact(Uint8List data) async {
    final record = decodeCompanionContactRecord(
      data,
      defaultLastmod: host.bridge.getTime(),
    );
    if (record == null) return host.sendErr(errCodeIllegalArg);
    await host.bridge.addUpdateContact(record.contact, hasGps: record.hasGps);
    host.sendOk();
  }

  Future<void> _cmdRemoveContact(Uint8List data) async {
    await host.bridge.removeContact(data.sublist(0, pubKeySize));
    host.sendOk();
  }

  Future<void> _cmdResetPath(Uint8List data) async {
    await host.bridge.resetPath(data.sublist(0, pubKeySize));
    host.sendOk();
  }

  // -------------------------------------------------------------------------
  // Channels
  // -------------------------------------------------------------------------

  void _cmdGetChannel(Uint8List data) {
    final fullList = data.isEmpty;
    final max = host.bridge.maxChannels;
    if (fullList) {
      for (var i = 0; i < max; i++) {
        host.sendFrame(_channelFrame(i, host.bridge.getChannel(i)));
      }
      if (max == 0) host.sendFrame(_channelFrame(0, null));
      return;
    }
    final idx = data[0];
    if (idx >= max) return host.sendErr(errCodeNotFound);
    host.sendFrame(_channelFrame(idx, host.bridge.getChannel(idx)));
  }

  Uint8List _channelFrame(int idx, Channel? ch) {
    final w = BufferWriter()
      ..writeByte(respCodeChannelInfo)
      ..writeByte(idx);
    w.writeCString(ch?.name ?? '', maxNameSize);
    final secret = Uint8List(16);
    if (ch != null) {
      final s = ch.secret;
      secret.setRange(0, s.length.clamp(0, 16), s);
    }
    w.writeBytes(secret);
    return w.toBytes();
  }

  Future<void> _cmdSetChannel(Uint8List data) async {
    final idx = data[0];
    final nameRaw = data.sublist(1, 33);
    final name = String.fromCharCodes(nameRaw.takeWhile((b) => b != 0)).trim();
    Uint8List secret;
    if (data.length >= 65) {
      secret = data.sublist(33, 65);
    } else if (data.length >= 49) {
      secret = data.sublist(33, 49);
    } else {
      return host.sendErr(errCodeIllegalArg);
    }
    await host.bridge.setChannel(idx, name, Uint8List.fromList(secret));
    host.sendOk();
  }

  // -------------------------------------------------------------------------
  // Advert
  // -------------------------------------------------------------------------

  Future<void> _cmdSendSelfAdvert(Uint8List data) async {
    // Pinned firmware: only an explicit byte 1 selects flood; absent/0 is
    // zero-hop.
    final flood = data.isNotEmpty && data[0] == 1;
    final ok = await host.bridge.advertise(flood: flood);
    ok ? host.sendOk() : host.sendErr(errCodeBadState);
  }

  Future<void> _cmdSetAdvertName(Uint8List data) async {
    final name = decodeAdvertNameBytes(data);
    if (name == null) return host.sendErr(errCodeIllegalArg);
    await host.bridge.setAdvertName(name);
    host.sendOk();
  }

  Future<void> _cmdSetAdvertLatLon(Uint8List data) async {
    final r = BufferReader(data);
    final latMicros = r.readInt32Le();
    final lonMicros = r.readInt32Le();
    if (!isValidAdvertCoordinateMicros(latMicros, lonMicros)) {
      return host.sendErr(errCodeIllegalArg);
    }
    await host.bridge.setAdvertLatLon(
      latMicros / 1e6,
      lonMicros / 1e6,
    );
    host.sendOk();
  }

  // -------------------------------------------------------------------------
  // Messaging
  // -------------------------------------------------------------------------

  Future<void> _cmdSendTxt(Uint8List data) async {
    final r = BufferReader(data);
    final txtType = r.readByte();
    final attempt = r.readByte();
    final timestamp = r.readUInt32Le();
    final prefix = r.readBytes(keyPrefix6);
    final text = r.readCString();
    final contact = host.bridge.getContactByKeyPrefix(prefix);
    if (contact == null) return host.sendErr(errCodeNotFound);
    final result = await host.bridge.sendTextMessage(
      contact.publicKey,
      text,
      txtType: txtType,
      // The firmware uses the app's timestamp and attempt verbatim; the ACK
      // hash the client precomputes is derived from these exact bytes.
      attempt: attempt,
      timestamp: timestamp,
    );
    if (!result.success) return host.sendErr(errCodeBadState);
    host.sendFrame(encodeSent(result, defaultTimeoutMs: 5000));
  }

  Future<void> _cmdSendChannelTxt(Uint8List data) async {
    final r = BufferReader(data);
    final txtType = r.readByte();
    final channelIdx = r.readByte();
    r.skipBytes(4); // timestamp
    final text = r.readCString();
    if (txtType != txtTypePlain) {
      return host.sendErr(errCodeUnsupportedCmd);
    }
    if (host.bridge.getChannel(channelIdx) == null) {
      return host.sendErr(errCodeNotFound);
    }
    host.sendOk();
    final ok = await host.bridge.sendChannelMessage(channelIdx, text);
    if (!ok) host.log('channel message send failed for channel $channelIdx');
  }

  Future<void> _cmdSendChannelData(Uint8List data) async {
    // [channel_idx][path_len][path?][data_type u16 LE][payload...]
    final r = BufferReader(data);
    final channelIdx = r.readByte();
    final pathLen = r.readByte();
    if (pathLen != 0xFF && !PathUtils.isValidPathLen(pathLen)) {
      return host.sendErr(errCodeIllegalArg);
    }
    var pathBytes = const <int>[];
    if (pathLen != 0xFF) {
      final byteLen = PathUtils.getByteLength(pathLen);
      if (r.remaining < byteLen + 2) return host.sendErr(errCodeIllegalArg);
      pathBytes = r.readBytes(byteLen);
    }
    if (r.remaining < 2) return host.sendErr(errCodeIllegalArg);
    final dataType = r.readUInt16Le();
    final payload = r.readRemainingBytes();
    if (dataType == dataTypeReserved) return host.sendErr(errCodeIllegalArg);
    // The radio-side group-data limit is 165; the 167-byte channel-data limit
    // applies only to CHANNEL_DATA_RECV pushes. The whole command must also fit
    // the 176-byte companion payload, so a long path reduces the data budget.
    if (payload.length > maxGroupDataLength ||
        payload.length > maxGroupDataLengthForCompanionPath(pathBytes.length)) {
      return host.sendErr(errCodeIllegalArg);
    }
    final commandLength = 5 + pathBytes.length + payload.length;
    if (commandLength > maxCompanionPayloadSize) {
      return host.sendErr(errCodeIllegalArg);
    }
    if (host.bridge.getChannel(channelIdx) == null) {
      return host.sendErr(errCodeNotFound);
    }
    final ok = await host.bridge.sendChannelData(
      channelIdx,
      dataType,
      Uint8List.fromList(payload),
      path: pathBytes,
      pathLenEncoded: pathLen,
    );
    ok ? host.sendOk() : host.sendErr(errCodeTableFull);
  }

  Future<void> _cmdSendControlData(Uint8List data) async {
    // The first control byte must set the 0x80 bit (control-data marker).
    if ((data[0] & 0x80) == 0) {
      return host.sendErr(errCodeIllegalArg);
    }
    final ok = await host.bridge.sendControlData(data);
    ok ? host.sendOk() : host.sendErr(errCodeTableFull);
  }

  Future<void> _cmdSyncNextMessage() async {
    final msg = await host.bridge.syncNextMessage();
    if (msg == null) {
      host.sendFrame(Uint8List.fromList([respCodeNoMoreMessages]));
      return;
    }
    host.sendFrame(encodeMessageFrame(msg, appTargetVer: host.appTargetVer));
  }

  // -------------------------------------------------------------------------
  // Signing
  // -------------------------------------------------------------------------

  void _cmdSignStart() {
    _signBuffer.clear();
    final w = BufferWriter()
      ..writeByte(respCodeSignStart)
      ..writeByte(0)
      ..writeUInt32Le(host.maxSignDataLen);
    host.sendFrame(w.toBytes());
  }

  void _cmdSignData(Uint8List data) {
    if (_signBuffer.length + data.length > host.maxSignDataLen) {
      return host.sendErr(errCodeTableFull);
    }
    _signBuffer.addAll(data);
    host.sendOk();
  }

  Future<void> _cmdSignFinish() async {
    try {
      final signature = await host.bridge.sign(Uint8List.fromList(_signBuffer));
      _signBuffer.clear();
      host.sendFrame(
          Uint8List.fromList([respCodeSignature, ...signature.take(64)]));
    } catch (_) {
      host.sendErr(errCodeBadState);
    }
  }

  // -------------------------------------------------------------------------
  // Stats / advert path / export
  // -------------------------------------------------------------------------

  Future<void> _cmdExportPrivateKey() async {
    final key = await host.bridge.exportPrivateKey();
    if (key.length != 64) {
      host.log('identity export returned an invalid length');
      return host.sendErr(errCodeBadState);
    }
    host.sendFrame(Uint8List.fromList([respCodePrivateKey, ...key]));
  }

  Future<void> _cmdImportPrivateKey(Uint8List data) async {
    // Firmware accepts len>=65 including the command byte and ignores trailing
    // bytes; a short key is never truncated or clamped into validity.
    final key = Uint8List.fromList(data.sublist(0, 64));
    await host.bridge.importPrivateKey(key);
    _signBuffer.clear();
    host.sendOk();
  }

  Future<void> _cmdGetStats(Uint8List data) async {
    final statsType = data.isEmpty ? statsTypePackets : data[0];
    if (statsType != statsTypeCore &&
        statsType != statsTypeRadio &&
        statsType != statsTypePackets) {
      return host.sendErr(errCodeIllegalArg);
    }
    final stats = await host.bridge.getStats(statsType);
    final w = BufferWriter()
      ..writeByte(respCodeStats)
      ..writeByte(statsType);
    switch (statsType) {
      case statsTypeCore:
        w
          ..writeUInt16Le(stats.batteryMv)
          ..writeUInt32Le(stats.uptimeSecs)
          ..writeUInt16Le(stats.errors)
          ..writeByte(stats.queueLen.clamp(0, 255));
      case statsTypeRadio:
        w
          ..writeUInt16Le(stats.noiseFloor)
          ..writeByte(stats.lastRssi & 0xFF)
          ..writeByte(stats.lastSnrScaled & 0xFF)
          ..writeUInt32Le(stats.txAirSecs)
          ..writeUInt32Le(stats.rxAirSecs);
      default:
        w
          ..writeUInt32Le(stats.recv)
          ..writeUInt32Le(stats.sent)
          ..writeUInt32Le(stats.floodTx)
          ..writeUInt32Le(stats.directTx)
          ..writeUInt32Le(stats.floodRx)
          ..writeUInt32Le(stats.directRx)
          ..writeUInt32Le(stats.recvErrors);
    }
    host.sendFrame(w.toBytes());
  }

  void _cmdGetAdvertPath(Uint8List data) {
    final pubkey = data.sublist(1, 1 + pubKeySize);
    final found =
        host.bridge.getAdvertPath(pubkey.sublist(0, advertPathPrefix7));
    if (found == null) return host.sendErr(errCodeNotFound);
    final pathByteLen = PathUtils.getByteLength(found.pathLen);
    final w = BufferWriter()
      ..writeByte(respCodeAdvertPath)
      ..writeUInt32Le(found.recvTimestamp)
      ..writeByte(found.pathLen)
      ..writeBytes(found.path.take(pathByteLen).toList());
    host.sendFrame(w.toBytes());
  }

  Future<void> _cmdExportContact(Uint8List data) async {
    final pubkey =
        data.length >= pubKeySize ? data.sublist(0, pubKeySize) : null;
    final raw = await host.bridge.exportContact(pubkey);
    if (raw == null) return host.sendErr(errCodeNotFound);
    host.sendFrame(Uint8List.fromList([respCodeExportContact, ...raw]));
  }

  Future<void> _cmdImportContact(Uint8List data) async {
    final ok = await host.bridge.importContact(Uint8List.fromList(data));
    ok ? host.sendOk() : host.sendErr(errCodeIllegalArg);
  }

  Future<void> _cmdShareContact(Uint8List data) async {
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final ok = await host.bridge.shareContact(pubkey);
    ok ? host.sendOk() : host.sendErr(errCodeNotFound);
  }

  Future<void> _cmdSendBinaryReq(Uint8List data) async {
    final pubkey = data.sublist(0, pubKeySize);
    final reqData = data.sublist(pubKeySize);
    final result = await host.bridge.sendBinaryReq(pubkey, reqData);
    if (!result.success) return host.sendErr(errCodeNotFound);
    _sendSent(result);
  }

  Future<void> _cmdSendAnonReq(Uint8List data) async {
    // [pubkey(32)][anon_req_data...]
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final reqData = Uint8List.fromList(data.sublist(pubKeySize));
    final result = await host.bridge.sendAnonReq(pubkey, reqData);
    if (!result.success) return host.sendErr(errCodeNotFound);
    _sendSent(result);
  }

  Future<void> _cmdSendTelemetryReq(Uint8List data) async {
    // 'self' telemetry: the firmware accepts a 4-byte frame (command + 3 zero
    // bytes) and answers with the local node's own LPP telemetry. `data` here
    // excludes the command byte, so that is a 3-byte payload.
    if (data.length == 3) {
      final batt = await host.bridge.getBatteryAndStorage();
      final lpp = encodeSelfVoltageTelemetry(batt.millivolts);
      host.sendFrame(Uint8List.fromList([
        pushCodeTelemetryResponse,
        0,
        ...host.bridge.getPublicKey().sublist(0, keyPrefix6),
        ...lpp,
      ]));
      return;
    }
    if (data.length < 3 + pubKeySize) return host.sendErr(errCodeIllegalArg);
    final pubkey = Uint8List.fromList(data.sublist(3, 3 + pubKeySize));
    final result = await host.bridge.sendTelemetryRequest(pubkey);
    if (!result.success) return host.sendErr(errCodeNotFound);
    // The telemetry payload itself arrives later via PUSH_CODE_TELEMETRY_RESPONSE.
    _sendSent(result);
  }

  Future<void> _cmdSendRawData(Uint8List data) async {
    // [path_len][path bytes][payload (>=4)] — flood is not supported.
    final pathLenByte = data[0];
    if (!PathUtils.isValidPathLen(pathLenByte)) {
      return host.sendErr(errCodeUnsupportedCmd);
    }
    final pathBytes = PathUtils.getByteLength(pathLenByte);
    if (data.length < 1 + pathBytes + 4) {
      return host.sendErr(errCodeIllegalArg);
    }
    final path = Uint8List.fromList(data.sublist(1, 1 + pathBytes));
    final payload = Uint8List.fromList(data.sublist(1 + pathBytes));
    final ok = await host.bridge.sendRawData(payload, path, pathLenByte);
    ok ? host.sendOk() : host.sendErr(errCodeTableFull);
  }

  Future<void> _cmdSendRawPacket(Uint8List data) async {
    // [priority][full packet bytes] — transmitted verbatim (route type and path
    // encoded in the packet header).
    final priority = data[0];
    final packet = Packet.readFrom(Uint8List.fromList(data.sublist(1)));
    if (packet == null) return host.sendErr(errCodeIllegalArg);
    final ok = await host.bridge.sendRawPacket(packet, priority);
    ok ? host.sendOk() : host.sendErr(errCodeTableFull);
  }

  Future<void> _cmdSendTracePath(Uint8List data) async {
    final trace = decodeTracePayload(data);
    if (trace == null || !trace.hasValidPath) {
      return host.sendErr(errCodeIllegalArg);
    }
    final ok = await host.bridge
        .sendTracePathRaw(trace.tag, trace.authCode, trace.flags, trace.path);
    if (!ok) return host.sendErr(errCodeTableFull);
    final timeout = 5000 + trace.path.length * 200;
    host.sendFrame(encodeSentValues(
      isFlood: false,
      expectedAck: trace.tag,
      timeoutMs: timeout,
    ));
  }

  Future<void> _cmdSendPathDiscoveryReq(Uint8List data) async {
    // data = [request-index(0)] + pubkey(32); the index must be 0.
    if (data[0] != 0) {
      return host.sendErr(errCodeIllegalArg);
    }
    final pubkey = Uint8List.fromList(data.sublist(1, 1 + pubKeySize));
    final result = await host.bridge.sendPathDiscoveryReq(pubkey);
    if (!result.success) return host.sendErr(errCodeNotFound);
    _sendSent(result);
  }

  Future<void> _cmdSendLogin(Uint8List data) async {
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final password =
        String.fromCharCodes(data.sublist(pubKeySize).takeWhile((b) => b != 0));
    final result = await host.bridge.sendLogin(pubkey, password);
    if (!result.success) return host.sendErr(errCodeNotFound);
    _sendSent(result);
  }

  Future<void> _cmdSendStatusReq(Uint8List data) async {
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    final result = await host.bridge.sendStatusReq(pubkey);
    if (!result.success) return host.sendErr(errCodeNotFound);
    _sendSent(result);
  }

  void _cmdLogout(Uint8List data) {
    host.bridge.logout(Uint8List.fromList(data.sublist(0, pubKeySize)));
    host.sendOk();
  }

  void _cmdHasConnection(Uint8List data) {
    final pubkey = Uint8List.fromList(data.sublist(0, pubKeySize));
    host.bridge.hasConnection(pubkey)
        ? host.sendOk()
        : host.sendErr(errCodeNotFound);
  }

  void _cmdSetFloodScope(Uint8List data) {
    switch (data[0]) {
      case 0: // set (or reset) the send-scope override
        if (data.length >= 1 + 16) {
          host.bridge
              .setFloodScopeKey(Uint8List.fromList(data.sublist(1, 1 + 16)));
        } else {
          host.bridge.setFloodScopeKey(null);
        }
        host.sendOk();
      case 1: // force unscoped flooding (fw v12+)
        host.bridge.setFloodUnscoped();
        host.sendOk();
      default:
        host.sendErr(errCodeIllegalArg);
    }
  }

  Future<void> _cmdSetDefaultFloodScope(Uint8List data) async {
    // [name(31)][key(16)] sets; anything shorter clears the default scope.
    if (data.length >= 31 + 16) {
      final nameBytes = data.sublist(0, 31);
      final end = nameBytes.indexOf(0);
      final name = String.fromCharCodes(
          end >= 0 ? nameBytes.sublist(0, end) : nameBytes);
      if (name.isEmpty || name.length >= 31) {
        return host.sendErr(errCodeIllegalArg);
      }
      await host.bridge.setDefaultFloodScope(
          name, Uint8List.fromList(data.sublist(31, 31 + 16)));
    } else {
      await host.bridge.setDefaultFloodScope('', null);
    }
    host.sendOk();
  }

  Future<void> _cmdGetAllowedRepeatFreq() async {
    final ranges = await host.bridge.getAllowedRepeatFreq();
    host.sendFrame(Uint8List.fromList([respCodeAllowedRepeatFreq, ...ranges]));
  }

  void _cmdGetDefaultFloodScope() {
    final (name, key) = host.bridge.getDefaultFloodScope();
    if (name.isEmpty || key == null) {
      return host.sendFrame(Uint8List.fromList([respCodeDefaultFloodScope]));
    }
    final w = BufferWriter()
      ..writeByte(respCodeDefaultFloodScope)
      ..writeCString(name, 31)
      ..writeBytes(key);
    host.sendFrame(w.toBytes());
  }

  Future<void> _cmdReboot(Uint8List data) async {
    // Exact magic only; extra bytes are not a reboot alias.
    if (data.length != 6 || String.fromCharCodes(data) != 'reboot') {
      return host.sendErr(errCodeIllegalArg);
    }
    await host.bridge.reboot();
    _signBuffer.clear();
    host.sendOk();
  }

  void _sendSent(SentResult result) => host.sendFrame(encodeSent(result));
}
