import 'dart:convert';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'mesh_stats.dart';

/// A failed bridge operation carrying a companion-protocol error response.
///
/// [disabled] means the server must answer with the one-byte DISABLED response
/// instead of `[1, code]`. [uncertain] means a physical write may have reached
/// the radio and must not be retried automatically.
class CompanionOperationError implements Exception {
  const CompanionOperationError(
    this.code, {
    this.message,
    this.disabled = false,
    this.uncertain = false,
  });

  final int code;
  final String? message;
  final bool disabled;
  final bool uncertain;

  @override
  String toString() => 'CompanionOperationError(code=$code'
      '${disabled ? ', disabled' : ''}'
      '${uncertain ? ', uncertain' : ''}'
      '${message == null ? '' : ', $message'})';
}

/// Sink the [CompanionBridge] uses to emit asynchronous push frames to the
/// connected client. The server registers itself when a client connects.
abstract class CompanionPushSink {
  /// A message is queued; client should call `CMD_SYNC_NEXT_MESSAGE`.
  void pushMsgWaiting();

  /// A sent message was acknowledged (4-byte ACK CRC).
  void pushSendConfirmed(int ackCrc, {int tripTimeMs = 0});

  /// An advert from a known contact was seen (full pubkey).
  void pushAdvert(Uint8List pubkey);

  /// A new advert was received; [contactFrame] is a full `RESP_CODE_CONTACT`
  /// style frame body (without the leading code byte).
  void pushNewAdvert(Uint8List contactFrame);

  /// A contact was evicted by overwrite-on-full (full pubkey).
  void pushContactDeleted(Uint8List pubkey);

  /// Persistent contact capacity/quota prevented auto-add.
  void pushContactsFull();

  /// A contact's routing path changed (full pubkey).
  void pushPathUpdated(Uint8List pubkey);

  /// Repeater telemetry response: 6-byte pubkey prefix + raw LPP payload.
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data);

  /// Binary (status/ACL/region/etc.) response: the request [tag] plus the raw
  /// response payload. Emitted as `PUSH_CODE_BINARY_RESPONSE`.
  void pushBinaryResponse(int tag, Uint8List data);

  /// A raw over-air packet was received, matching `PUSH_CODE_LOG_RX_DATA`.
  void pushRawRxData(double snr, int rssi, Uint8List raw);

  /// A direct raw-custom payload was received, matching `PUSH_CODE_RAW_DATA`.
  void pushRawData(double snr, int rssi, Uint8List payload);

  /// A raw control-data packet was received.
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data);

  /// Path-discovery result: 6-byte pubkey prefix plus the outbound and inbound
  /// paths (each with its encoded path-length byte).
  void pushPathDiscoveryResponse(
    Uint8List pubkeyPrefix6,
    int outPathLen,
    Uint8List outPath,
    int inPathLen,
    Uint8List inPath,
  );

  /// Login succeeded. When [legacy] is true the response was the legacy "OK"
  /// form (no permissions/tag); otherwise [permissions], [serverTag], [acl] and
  /// [firmwareVer] carry the server's reply.
  void pushLoginSuccess(
    Uint8List pubkeyPrefix6, {
    bool legacy = false,
    int permissions = 0,
    int serverTag = 0,
    int acl = 0,
    int firmwareVer = 0,
  });

  /// Login failed.
  void pushLoginFail(Uint8List pubkeyPrefix6);

  /// Status response: 6-byte pubkey prefix + raw status payload.
  void pushStatusResponse(Uint8List pubkeyPrefix6, Uint8List data);

  /// Trace result (`PUSH_CODE_TRACE_DATA`). [pathLen] is the raw byte length of
  /// the requested path, [flags]'s low two bits give the hash width,
  /// [pathHashes] is the requested path, [pathSnrs] the per-hop SNRs, and
  /// [finalSnrByte] the scaled SNR of the returning frame.
  void pushTraceData(
    int pathLen,
    int flags,
    int tag,
    int authCode,
    Uint8List pathHashes,
    Uint8List pathSnrs,
    int finalSnrByte,
  );
}

/// Convenience base for a host or test that does not observe every push.
///
/// New push methods only need a no-op here; implementations override the
/// pushes they actually consume.
class NoopCompanionPushSink implements CompanionPushSink {
  const NoopCompanionPushSink();

  @override
  void pushMsgWaiting() {}

  @override
  void pushSendConfirmed(int ackCrc, {int tripTimeMs = 0}) {}

  @override
  void pushAdvert(Uint8List pubkey) {}

  @override
  void pushNewAdvert(Uint8List contactFrame) {}

  @override
  void pushContactDeleted(Uint8List pubkey) {}

  @override
  void pushContactsFull() {}

  @override
  void pushPathUpdated(Uint8List pubkey) {}

  @override
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data) {}

  @override
  void pushBinaryResponse(int tag, Uint8List data) {}

  @override
  void pushRawRxData(double snr, int rssi, Uint8List raw) {}

  @override
  void pushRawData(double snr, int rssi, Uint8List payload) {}

  @override
  void pushControlData(double snr, int rssi, int pathLen, Uint8List data) {}

  @override
  void pushPathDiscoveryResponse(
    Uint8List pubkeyPrefix6,
    int outPathLen,
    Uint8List outPath,
    int inPathLen,
    Uint8List inPath,
  ) {}

  @override
  void pushLoginSuccess(
    Uint8List pubkeyPrefix6, {
    bool legacy = false,
    int permissions = 0,
    int serverTag = 0,
    int acl = 0,
    int firmwareVer = 0,
  }) {}

  @override
  void pushLoginFail(Uint8List pubkeyPrefix6) {}

  @override
  void pushStatusResponse(Uint8List pubkeyPrefix6, Uint8List data) {}

  @override
  void pushTraceData(
    int pathLen,
    int flags,
    int tag,
    int authCode,
    Uint8List pathHashes,
    Uint8List pathSnrs,
    int finalSnrByte,
  ) {}
}

/// Logic backing the companion server: contacts, channels, messaging, adverts,
/// and radio configuration. The server dispatches commands here; the bridge
/// emits client pushes through the [CompanionPushSink].
///
/// Only pure local state (an empty contact list, wall-clock time, default
/// preferences) has a working default. Every hardware, identity, persistence,
/// or send operation throws [CompanionOperationError] with
/// [errCodeUnsupportedCmd] unless a host overrides it, so a partial host fails
/// loudly instead of answering `OK` for work it never did.
class CompanionBridge {
  CompanionPushSink? pushSink;

  /// Attach the push sink when a client connects; pass `null` on disconnect.
  void setPushSink(CompanionPushSink? sink) {
    pushSink = sink;
  }

  NodePrefs getSelfInfo() => NodePrefs();

  Uint8List getPublicKey() => _unsupported('getPublicKey');

  /// Export the active virtual 64-byte expanded identity.
  Future<Uint8List> exportPrivateKey() async =>
      _unsupported('exportPrivateKey');

  /// Validate and replace the active virtual identity from a complete 64-byte
  /// expanded key. Implementations must store before switching.
  Future<void> importPrivateKey(Uint8List expandedKey) async =>
      _unsupported('importPrivateKey');

  DeviceInfo getDeviceInfo() => const DeviceInfo();

  Future<BatteryReading> getBatteryAndStorage() async =>
      _unsupported('getBatteryAndStorage');

  int getTime() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool setTime(int seconds) => _unsupported('setTime');

  List<Contact> getContacts({int since = 0}) => const [];

  Contact? getContactByKey(Uint8List pubkey) => null;

  /// Persistent-contact lookup for client listing/export commands; transient
  /// anonymous slots are intentionally excluded.
  Contact? getPersistentContactByKey(Uint8List pubkey) =>
      getContactByKey(pubkey);

  Contact? getContactByKeyPrefix(Uint8List prefix) => null;

  Future<void> addUpdateContact(Contact contact, {bool hasGps = true}) async =>
      _unsupported('addUpdateContact');

  Future<void> removeContact(Uint8List pubkey) async =>
      _unsupported('removeContact');

  Future<void> resetPath(Uint8List pubkey) async => _unsupported('resetPath');

  Channel? getChannel(int index) => null;

  int get maxChannels => 8;

  Future<void> setChannel(int index, String name, Uint8List secret) async =>
      _unsupported('setChannel');

  Future<SentResult> sendTextMessage(
    Uint8List pubkey,
    String text, {
    int txtType = txtTypePlain,
    int attempt = 0,
    int? timestamp,
  }) async =>
      _unsupported('sendTextMessage');

  Future<bool> sendChannelMessage(int channelIndex, String text) async =>
      _unsupported('sendChannelMessage');

  /// Send a binary group-data packet on [channelIndex]. When [path] is given the
  /// packet is routed directly instead of flooded.
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) async =>
      _unsupported('sendChannelData');

  Future<bool> advertise({bool flood = false}) async =>
      _unsupported('advertise');

  Future<void> setAdvertName(String name) async =>
      _unsupported('setAdvertName');

  Future<void> setAdvertLatLon(double lat, double lon) async =>
      _unsupported('setAdvertLatLon');

  Future<void> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  }) async =>
      _unsupported('setRadioParams');

  Future<void> setTxPower(int dbm) async => _unsupported('setTxPower');

  /// Current path-hash mode reported to the client in `DEVICE_INFO`.
  int getPathHashMode() => getDeviceInfo().pathHashMode;

  /// Set the virtual path-hash mode (`CMD_SET_PATH_HASH_MODE`).
  Future<void> setPathHashMode(int mode) async =>
      _unsupported('setPathHashMode');

  /// Current device radio tuning parameters (`CMD_GET_TUNING_PARAMS`).
  Future<TuningParams> getTuningParams() async =>
      _unsupported('getTuningParams');

  /// Set the physical radio tuning parameters (`CMD_SET_TUNING_PARAMS`).
  Future<void> setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) async =>
      _unsupported('setTuningParams');

  /// Run a CLI command on the device, returning its reply text (fw v14+).
  /// Returns null when unsupported (device firmware < v14).
  Future<String?> runCliCommand(String command) async => null;

  /// Strict binary CLI entry point. Implementations that support the full
  /// allowlist override this to preserve raw-byte validation.
  Future<String> runCliCommandBytes(Uint8List payload) async {
    var bytes = payload;
    if (bytes.isNotEmpty && bytes.last == 0) {
      bytes = bytes.sublist(0, bytes.length - 1);
    }
    if (bytes.any((b) => b < 0x20 || b == 0x7F)) {
      return 'Error: illegal argument';
    }
    try {
      final text = await runCliCommand(
        utf8.decode(bytes, allowMalformed: false),
      );
      return text ?? 'Unknown command';
    } on FormatException {
      return 'Error: illegal argument';
    }
  }

  /// The allowed repeat-frequency ranges (`CMD_GET_ALLOWED_REPEAT_FREQ`): raw
  /// `[lower(4)][upper(4)]...` bytes (empty when unrestricted/unknown).
  Future<Uint8List> getAllowedRepeatFreq() async => Uint8List(0);

  Map<String, String> getCustomVars() => const {};

  Future<void> setCustomVar(String name, String value) async {
    throw const CompanionOperationError(errCodeIllegalArg);
  }

  int getAutoAddConfig() => 0;

  int getAutoAddMaxHops() => 0;

  Future<void> setAutoAddConfig(int flags, int? maxHops) async =>
      _unsupported('setAutoAddConfig');

  Future<void> setOtherParams({
    required int manualAddContacts,
    int? telemetryModes,
    int? advertLocPolicy,
    int? multiAcks,
  }) async =>
      _unsupported('setOtherParams');

  /// The raw advert packet blob for [pubkey], or a freshly built self advert
  /// when [pubkey] is null (`CMD_EXPORT_CONTACT`). Backs the `meshcore://` URI.
  Future<Uint8List?> exportContact(Uint8List? pubkey) async => null;

  /// Import a raw advert packet blob (`CMD_IMPORT_CONTACT`) as if received.
  Future<bool> importContact(Uint8List data) async =>
      _unsupported('importContact');

  /// Re-transmit a contact's saved advert zero-hop (`CMD_SHARE_CONTACT`).
  Future<bool> shareContact(Uint8List pubkey) async =>
      _unsupported('shareContact');

  /// Send a raw custom packet (`CMD_SEND_RAW_DATA`) directly along [path]
  /// (already-decoded path bytes plus their encoded length byte).
  Future<bool> sendRawData(
          Uint8List payload, Uint8List path, int pathLenByte) async =>
      _unsupported('sendRawData');

  /// Transmit an already-formed packet verbatim (`CMD_SEND_RAW_PACKET`).
  /// [priority] is accepted for protocol compatibility; the transport ignores it.
  Future<bool> sendRawPacket(Packet packet, int priority) async =>
      _unsupported('sendRawPacket');

  Future<QueuedMessage?> syncNextMessage() async => null;

  Future<MeshStats> getStats(int statsType) async => _unsupported('getStats');

  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) async =>
      _unsupported('sendBinaryReq');

  /// Send an anonymous request (`CMD_SEND_ANON_REQ`) to [pubkey] carrying
  /// [data] (`[anon_req_type][reply_path_len][reply_path...]`). The response is
  /// delivered via [CompanionPushSink.pushBinaryResponse].
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) async =>
      _unsupported('sendAnonReq');

  Future<SentResult> sendTelemetryRequest(
    Uint8List pubkey, {
    bool wantBase = true,
    bool wantLocation = true,
    bool wantEnvironment = true,
  }) async =>
      _unsupported('sendTelemetryRequest');

  Future<bool> sendTracePathRaw(
    int tag,
    int authCode,
    int flags,
    Uint8List pathBytes,
  ) async =>
      _unsupported('sendTracePathRaw');

  /// Send a flooded path-discovery request (a telemetry request) to [pubkey].
  /// A matching response is delivered via
  /// [CompanionPushSink.pushPathDiscoveryResponse].
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async =>
      _unsupported('sendPathDiscoveryReq');

  /// Log in to a repeater/room server with [password]. The result is delivered
  /// via [CompanionPushSink.pushLoginSuccess]/[pushLoginFail].
  Future<SentResult> sendLogin(Uint8List pubkey, String password) async =>
      _unsupported('sendLogin');

  /// Request the status of a repeater/room server. The response is delivered
  /// via [CompanionPushSink.pushStatusResponse].
  Future<SentResult> sendStatusReq(Uint8List pubkey) async =>
      _unsupported('sendStatusReq');

  /// Tear down any login/keep-alive session with [pubkey].
  bool logout(Uint8List pubkey) => false;

  /// Whether an active login/keep-alive session exists with [pubkey]
  /// (`CMD_HAS_CONNECTION`).
  bool hasConnection(Uint8List pubkey) => false;

  /// `CMD_SET_FLOOD_SCOPE_KEY` verb 0: set (or clear, with `null`) the flood
  /// scope override used for sends.
  void setFloodScopeKey(Uint8List? key) => _unsupported('setFloodScopeKey');

  /// `CMD_SET_FLOOD_SCOPE_KEY` verb 1 (fw v12+): force unscoped flooding until
  /// the next scope set.
  void setFloodUnscoped() => _unsupported('setFloodUnscoped');

  /// `CMD_SET_DEFAULT_FLOOD_SCOPE`: store the default region scope name and its
  /// 16-byte key (both cleared when [key] is null).
  Future<void> setDefaultFloodScope(String name, Uint8List? key) async =>
      _unsupported('setDefaultFloodScope');

  /// The stored default flood scope: a (name, 16-byte key) pair, or `('', null)`
  /// when unset. Backs `CMD_GET_DEFAULT_FLOOD_SCOPE`.
  (String, Uint8List?) getDefaultFloodScope() => ('', null);

  /// `CMD_REBOOT`: dispatch the physical reboot and clear ephemeral virtual
  /// operations. Does not wait for a firmware reply.
  Future<void> reboot() async => _unsupported('reboot');

  /// Bumped after a successful reboot/shutdown lifecycle action so the server
  /// can clear per-client ephemeral state (for example signing buffers).
  int get lifecycleGeneration => 0;

  /// Send a raw control-data packet zero-hop.
  Future<bool> sendControlData(Uint8List data) async =>
      _unsupported('sendControlData');

  AdvertPath? getAdvertPath(Uint8List prefix) => null;

  Future<Uint8List> sign(Uint8List message) => _unsupported('sign');
}

Never _unsupported(String operation) => throw CompanionOperationError(
      errCodeUnsupportedCmd,
      message: '$operation not implemented',
    );

/// The CLI text for a failed bridge operation.
///
/// Shared by the CLI runtime and the server's `CMD_RUN_CLI_COMMAND` handler so
/// both surfaces describe the same failure the same way.
String companionOperationErrorText(CompanionOperationError error) {
  if (error.disabled) return 'Error: disabled';
  return switch (error.code) {
    errCodeFileIoError || errCodeTableFull => 'Error: storage failure',
    errCodeBadState => 'Error: device unavailable',
    errCodeIllegalArg => 'Error: illegal argument',
    _ => 'Error: unsupported',
  };
}
