import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// Sink the [CompanionBridge] uses to emit asynchronous push frames to the
/// connected client. The server registers itself when a client connects.
abstract class CompanionPushSink {
  /// A message is queued; client should call `CMD_SYNC_NEXT_MESSAGE`.
  void pushMsgWaiting();

  /// A sent message was acknowledged (4-byte ACK CRC).
  void pushSendConfirmed(int ackCrc);

  /// An advert from a known contact was seen (full pubkey).
  void pushAdvert(Uint8List pubkey);

  /// A new advert was received; [contactFrame] is a full `RESP_CODE_CONTACT`
  /// style frame body (without the leading code byte).
  void pushNewAdvert(Uint8List contactFrame);

  /// A contact's routing path changed (full pubkey).
  void pushPathUpdated(Uint8List pubkey);

  /// Repeater telemetry response: 6-byte pubkey prefix + raw LPP payload.
  void pushTelemetryResponse(Uint8List pubkeyPrefix6, Uint8List data);

  /// Binary (status/ACL/region/etc.) response: the request [tag] plus the raw
  /// response payload. Emitted as `PUSH_CODE_BINARY_RESPONSE`.
  void pushBinaryResponse(int tag, Uint8List data);

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

/// Logic backing the companion server: contacts, channels, messaging, adverts,
/// and radio configuration. The server dispatches commands here; the bridge
/// emits client pushes through the [CompanionPushSink].
///
/// Default implementations are conservative no-ops so partial implementations
/// (and tests) only override what they need.
class CompanionBridge {
  CompanionPushSink? pushSink;

  /// Attach the push sink when a client connects; pass `null` on disconnect.
  void setPushSink(CompanionPushSink? sink) {
    pushSink = sink;
  }

  NodePrefs getSelfInfo() => NodePrefs();

  Uint8List getPublicKey() =>
      throw UnsupportedError('getPublicKey not implemented');

  DeviceInfo getDeviceInfo() => const DeviceInfo();

  BatteryReading getBatteryAndStorage() =>
      const BatteryReading(millivolts: 0, storageUsedKb: 0, storageTotalKb: 0);

  int getTime() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  bool setTime(int seconds) => true;

  List<Contact> getContacts({int since = 0}) => const [];

  Contact? getContactByKey(Uint8List pubkey) => null;

  Contact? getContactByKeyPrefix(Uint8List prefix) => null;

  bool addUpdateContact(Contact contact) => false;

  bool removeContact(Uint8List pubkey) => false;

  bool resetPath(Uint8List pubkey) => false;

  Channel? getChannel(int index) => null;

  int get maxChannels => 8;

  bool setChannel(int index, String name, Uint8List secret) => false;

  Future<SentResult> sendTextMessage(
    Uint8List pubkey,
    String text, {
    int txtType = txtTypePlain,
    int attempt = 0,
    bool waitForAck = false,
  }) async =>
      const SentResult.failure();

  Future<bool> sendChannelMessage(int channelIndex, String text) async => false;

  /// Send a binary group-data packet on [channelIndex]. When [path] is given the
  /// packet is routed directly instead of flooded.
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) async =>
      false;

  Future<bool> advertise({bool flood = true}) async => false;

  void setAdvertName(String name) {}

  void setAdvertLatLon(double lat, double lon) {}

  void setRadioParams(int freqHz, int bwHz, int sf, int cr) {}

  void setTxPower(int dbm) {}

  /// Current path-hash mode reported to the client in `DEVICE_INFO`.
  int getPathHashMode() => getDeviceInfo().pathHashMode;

  /// Set the path-hash mode (`CMD_SET_PATH_HASH_MODE`, fw v10+).
  void setPathHashMode(int mode) {}

  /// Current device radio tuning parameters (`CMD_GET_TUNING_PARAMS`).
  Future<TuningParams> getTuningParams() async =>
      const TuningParams(rxDelayBaseMs: 0, airtimeFactorMs: 0);

  /// Set the device radio tuning parameters (`CMD_SET_TUNING_PARAMS`).
  void setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) {}

  /// Run a CLI command on the device (`CMD_RUN_CLI_COMMAND`, fw v14+).
  Future<void> runCliCommand(String command) async {}

  /// The allowed repeat-frequency ranges (`CMD_GET_ALLOWED_REPEAT_FREQ`): raw
  /// `[lower(4)][upper(4)]...` bytes (empty when unrestricted/unknown).
  Future<Uint8List> getAllowedRepeatFreq() async => Uint8List(0);

  Map<String, String> getCustomVars() => const {};

  bool setCustomVar(String name, String value) => false;

  int getAutoAddConfig() => 0;

  void setAutoAddConfig(int flags) {}

  void setOtherParams(
    int manualAdd,
    int telemetryModes,
    int advertLocPolicy,
    int multiAcks,
  ) {}

  /// The raw advert packet blob for [pubkey], or a freshly built self advert
  /// when [pubkey] is null (`CMD_EXPORT_CONTACT`). Backs the `meshcore://` URI.
  Future<Uint8List?> exportContact(Uint8List? pubkey) async => null;

  /// Import a raw advert packet blob (`CMD_IMPORT_CONTACT`) as if received.
  Future<bool> importContact(Uint8List data) async => false;

  /// Re-transmit a contact's saved advert zero-hop (`CMD_SHARE_CONTACT`).
  Future<bool> shareContact(Uint8List pubkey) async => false;

  /// Send a raw custom packet (`CMD_SEND_RAW_DATA`) directly along [path]
  /// (already-decoded path bytes plus their encoded length byte).
  Future<bool> sendRawData(Uint8List payload, Uint8List path, int pathLenByte) async =>
      false;

  QueuedMessage? syncNextMessage() => null;

  Map<String, Object?> getStats(int statsType) => const {};

  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) async =>
      const SentResult.failure();

  /// Send an anonymous request (`CMD_SEND_ANON_REQ`) to [pubkey] carrying
  /// [data] (`[anon_req_type][reply_path_len][reply_path...]`). The response is
  /// delivered via [CompanionPushSink.pushBinaryResponse].
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) async =>
      const SentResult.failure();

  Future<SentResult> sendTelemetryRequest(
    Uint8List pubkey, {
    bool wantBase = true,
    bool wantLocation = true,
    bool wantEnvironment = true,
  }) async =>
      const SentResult.failure();

  Future<bool> sendTracePathRaw(
    int tag,
    int authCode,
    int flags,
    Uint8List pathBytes,
  ) async =>
      false;

  /// Send a flooded path-discovery request (a telemetry request) to [pubkey].
  /// A matching response is delivered via
  /// [CompanionPushSink.pushPathDiscoveryResponse].
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async =>
      const SentResult.failure();

  /// Log in to a repeater/room server with [password]. The result is delivered
  /// via [CompanionPushSink.pushLoginSuccess]/[pushLoginFail].
  Future<SentResult> sendLogin(Uint8List pubkey, String password) async =>
      const SentResult.failure();

  /// Request the status of a repeater/room server. The response is delivered
  /// via [CompanionPushSink.pushStatusResponse].
  Future<SentResult> sendStatusReq(Uint8List pubkey) async =>
      const SentResult.failure();

  /// Tear down any login/keep-alive session with [pubkey].
  bool logout(Uint8List pubkey) => false;

  /// Whether an active login/keep-alive session exists with [pubkey]
  /// (`CMD_HAS_CONNECTION`).
  bool hasConnection(Uint8List pubkey) => false;

  /// `CMD_SET_FLOOD_SCOPE_KEY` verb 0: set (or clear, with `null`) the flood
  /// scope override used for sends.
  void setFloodScopeKey(Uint8List? key) {}

  /// `CMD_SET_FLOOD_SCOPE_KEY` verb 1 (fw v12+): force unscoped flooding until
  /// the next scope set.
  void setFloodUnscoped() {}

  /// `CMD_SET_DEFAULT_FLOOD_SCOPE`: store the default region scope name and its
  /// 16-byte key (both cleared when [key] is null).
  void setDefaultFloodScope(String name, Uint8List? key) {}

  /// The stored default flood scope: a (name, 16-byte key) pair, or `('', null)`
  /// when unset. Backs `CMD_GET_DEFAULT_FLOOD_SCOPE`.
  (String, Uint8List?) getDefaultFloodScope() => ('', null);

  /// `CMD_REBOOT`: restart the node engine (best-effort; ephemeral state only).
  void reboot() {}

  /// Send a raw control-data packet zero-hop.
  Future<bool> sendControlData(Uint8List data) async => false;

  AdvertPath? getAdvertPath(Uint8List prefix) => null;

  Future<Uint8List> sign(Uint8List message) =>
      throw UnsupportedError('sign not implemented');
}
