import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

class FailingSinkBridge extends TestBridge {
  FailingSinkBridge(super.identity);

  bool failSetPushSink = true;

  @override
  void setPushSink(CompanionPushSink? sink) {
    if (failSetPushSink) throw StateError('push sink unavailable');
    super.setPushSink(sink);
  }
}

class TestBridge extends CompanionBridge {
  TestBridge(this.identity);

  LocalIdentity identity;
  final contacts = <Contact>[];
  final channels = <int, Channel>{};

  int? sentChannelDataIndex;
  int? sentChannelDataType;
  Uint8List? sentChannelDataPayload;
  Uint8List? sentChannelDataPath;
  int? sentChannelDataPathLen;
  bool channelDataResult = true;

  @override
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) async {
    sentChannelDataIndex = channelIndex;
    sentChannelDataType = dataType;
    sentChannelDataPayload = payload;
    sentChannelDataPath = path == null ? null : Uint8List.fromList(path);
    sentChannelDataPathLen = pathLenEncoded;
    return channelDataResult;
  }

  bool channelMessageResult = true;
  int? sentChannelIndex;
  String? sentChannelText;
  int? sentChannelTimestamp;

  @override
  Future<bool> sendChannelMessage(
    int channelIndex,
    String text, {
    int? timestamp,
  }) async {
    sentChannelIndex = channelIndex;
    sentChannelText = text;
    sentChannelTimestamp = timestamp;
    return channelMessageResult;
  }

  @override
  Uint8List getPublicKey() => identity.publicKey;

  NodePrefs selfInfo = NodePrefs(
    nodeName: 'TestProxy',
    frequencyHz: 915000000,
    bandwidthHz: 250000,
    spreadingFactor: 10,
    codingRate: 5,
  );

  @override
  NodePrefs getSelfInfo() => selfInfo;

  int autoAddConfig = 0;
  int autoAddMaxHops = 0;

  @override
  int getAutoAddConfig() => autoAddConfig;

  @override
  int getAutoAddMaxHops() => autoAddMaxHops;

  @override
  Future<void> setAutoAddConfig(int flags, int? maxHops) async {
    if (autoAddError != null) throw autoAddError!;
    autoAddConfig = flags & 0xFF;
    if (maxHops != null) autoAddMaxHops = maxHops.clamp(0, 64);
  }

  CompanionOperationError? autoAddError;

  @override
  Future<void> setOtherParams({
    required int manualAddContacts,
    int? telemetryModes,
    int? advertLocPolicy,
    int? multiAcks,
  }) async {
    if (otherParamsError != null) throw otherParamsError!;
    selfInfo.manualAddContacts = manualAddContacts & 0xFF;
    if (telemetryModes != null) {
      final raw = telemetryModes & 0xFF;
      selfInfo
        ..telemetryModeBase = raw & 0x03
        ..telemetryModeLocation = (raw >> 2) & 0x03
        ..telemetryModeEnvironment = (raw >> 4) & 0x03;
    }
    if (advertLocPolicy != null) {
      selfInfo.advertLocPolicy = advertLocPolicy & 0xFF;
    }
    if (multiAcks != null) selfInfo.multiAcks = multiAcks & 0xFF;
  }

  CompanionOperationError? otherParamsError;

  @override
  Future<void> setAdvertName(String name) async {
    if (advertNameError != null) throw advertNameError!;
    selfInfo.nodeName = name;
  }

  CompanionOperationError? advertNameError;

  @override
  Future<void> setAdvertLatLon(double lat, double lon) async {
    if (advertLatLonError != null) throw advertLatLonError!;
    selfInfo
      ..latitude = lat
      ..longitude = lon;
  }

  CompanionOperationError? advertLatLonError;

  DeviceInfo deviceInfo = const DeviceInfo(maxContacts: 1000, maxChannels: 8);

  @override
  DeviceInfo getDeviceInfo() => deviceInfo;

  BatteryReading batteryReading = const BatteryReading(
      millivolts: 3900, storageUsedKb: 5, storageTotalKb: 100);
  int batteryReads = 0;

  @override
  Future<BatteryReading> getBatteryAndStorage() async {
    batteryReads++;
    return batteryReading;
  }

  Uint8List? selfTelemetryOverride;

  @override
  Future<Uint8List> getSelfTelemetry() async =>
      selfTelemetryOverride ??
      encodeSelfVoltageTelemetry(batteryReading.millivolts);

  int statsReads = 0;

  @override
  Future<MeshStats> getStats(int statsType) async {
    statsReads++;
    final battery = await getBatteryAndStorage();
    if (statsType == statsTypeCore) {
      return MeshStats(
        batteryMv: battery.millivolts,
        uptimeSecs: 7,
        errors: 0,
        queueLen: 0,
      );
    }
    if (statsType == statsTypeRadio) {
      return const MeshStats(
        noiseFloor: -110,
        lastRssi: -70,
        lastSnrScaled: 24,
        txAirSecs: 1,
        rxAirSecs: 2,
      );
    }
    return const MeshStats();
  }

  int currentTime = 100;

  @override
  int getTime() => currentTime;

  @override
  bool setTime(int seconds) {
    if (seconds < currentTime) return false;
    currentTime = seconds;
    return true;
  }

  bool? advertisedFlood;
  Completer<void>? advertiseGate;
  Completer<void>? advertiseEntered;
  bool advertised = false;
  bool advertiseResult = true;

  @override
  Future<bool> advertise({bool flood = false}) async {
    advertisedFlood = flood;
    advertiseEntered?.complete();
    if (advertiseGate != null) await advertiseGate!.future;
    advertised = true;
    return advertiseResult;
  }

  /// Reply text for `CMD_RUN_CLI_COMMAND`; null models a pre-v14 device.
  String? cliReply;
  CompanionOperationError? cliError;
  Object? cliGenericError;

  @override
  Future<String?> runCliCommand(String command) async {
    if (cliGenericError != null) throw cliGenericError!;
    if (cliError != null) throw cliError!;
    return cliReply;
  }

  /// CLI execution that changes the runtime lifecycle (for reset/reboot guards).
  int cliLifecycleBump = 0;
  int lifecycleGenerationValue = 0;

  @override
  int get lifecycleGeneration => lifecycleGenerationValue;

  @override
  Future<String> runCliCommandBytes(Uint8List payload) {
    if (cliLifecycleBump > 0) {
      lifecycleGenerationValue += cliLifecycleBump;
      cliLifecycleBump = 0;
    }
    return super.runCliCommandBytes(payload);
  }

  final customVars = <String, String>{};
  final supportedCustomKeys = <String>{};
  CompanionOperationError? customVarError;

  @override
  Map<String, String> getCustomVars() => customVars;

  @override
  Future<void> setCustomVar(String name, String value) async {
    if (customVarError != null) throw customVarError!;
    if (!supportedCustomKeys.contains(name) ||
        name.isEmpty ||
        name.contains(':') ||
        value.contains(':')) {
      throw const CompanionOperationError(errCodeIllegalArg);
    }
    customVars[name] = value;
  }

  @override
  List<Contact> getContacts({int since = 0}) {
    if (contactsError != null) throw contactsError!;
    return contacts.where((c) => c.lastmod > since).toList();
  }

  @override
  int get contactCount => contacts.length;

  Object? contactsError;

  CompanionOperationError? addContactError;
  Contact? addedContact;
  bool? addedContactHasGps;

  @override
  Future<void> addUpdateContact(Contact contact, {bool hasGps = true}) async {
    if (addContactError != null) throw addContactError!;
    addedContact = contact;
    addedContactHasGps = hasGps;
    contacts
      ..removeWhere((c) => c.publicKeyHex == contact.publicKeyHex)
      ..add(contact);
  }

  CompanionOperationError? removeContactError;
  Uint8List? removedContact;

  @override
  Future<void> removeContact(Uint8List pubkey) async {
    if (removeContactError != null) throw removeContactError!;
    removedContact = pubkey;
    contacts.removeWhere((c) => c.publicKeyHex == bytesToHex(pubkey));
  }

  CompanionOperationError? resetPathError;
  Uint8List? resetPathFor;

  @override
  Future<void> resetPath(Uint8List pubkey) async {
    if (resetPathError != null) throw resetPathError!;
    resetPathFor = pubkey;
  }

  @override
  Contact? getContactByKey(Uint8List pubkey) {
    for (final c in contacts) {
      if (c.publicKeyHex == bytesToHex(pubkey)) return c;
    }
    return null;
  }

  @override
  Contact? getContactByKeyPrefix(Uint8List prefix) {
    final hex = bytesToHex(prefix);
    for (final c in contacts) {
      if (bytesToHex(c.publicKey.sublist(0, prefix.length)) == hex) return c;
    }
    return null;
  }

  @override
  Channel? getChannel(int index) => channels[index];

  @override
  int get maxChannels => maxChannelsValue;

  int maxChannelsValue = 8;

  CompanionOperationError? setChannelError;

  @override
  Future<void> setChannel(int index, String name, Uint8List secret) async {
    if (setChannelError != null) throw setChannelError!;
    channels[index] = Channel(name: name, secret: secret);
  }

  int? radioFreqHz;
  int? radioBandwidthHz;
  int? radioSf;
  int? radioCr;
  bool? radioClientRepeat;
  Completer<void>? radioAck;
  CompanionOperationError? radioError;

  @override
  Future<void> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  }) async {
    radioFreqHz = freqHz;
    radioBandwidthHz = bwHz;
    radioSf = sf;
    radioCr = cr;
    radioClientRepeat = clientRepeat;
    if (radioError != null) throw radioError!;
    if (radioAck != null) await radioAck!.future;
  }

  int? txPower;
  Completer<void>? txAck;
  CompanionOperationError? txError;

  @override
  Future<void> setTxPower(int dbm) async {
    txPower = dbm;
    if (txError != null) throw txError!;
    if (txAck != null) await txAck!.future;
  }

  Completer<void>? tuningAck;
  CompanionOperationError? tuningError;

  @override
  Future<void> setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) async {
    if (tuningError != null) throw tuningError!;
    if (tuningAck != null) await tuningAck!.future;
    tuning = TuningParams(
      rxDelayBaseMs: rxDelayBaseMs,
      airtimeFactorMs: airtimeFactorMs,
    );
  }

  int pathHash = 0;
  TuningParams tuning =
      const TuningParams(rxDelayBaseMs: 0, airtimeFactorMs: 0);

  @override
  int getPathHashMode() => pathHash;

  @override
  Future<void> setPathHashMode(int mode) async => pathHash = mode;

  CompanionOperationError? tuningGetError;

  @override
  Future<TuningParams> getTuningParams() async {
    if (tuningGetError != null) throw tuningGetError!;
    return tuning;
  }

  @override
  Future<SentResult> sendTelemetryRequest(Uint8List pubkey,
          {bool wantBase = true,
          bool wantLocation = true,
          bool wantEnvironment = true}) async =>
      telemetryResult;

  SentResult telemetryResult = const SentResult(
      success: true, isFlood: false, expectedAck: 0x99, timeoutMs: 10000);

  @override
  Future<SentResult> sendTracePathRaw(
          int tag, int authCode, int flags, Uint8List pathBytes) async =>
      SentResult(
        success: traceResult,
        isFlood: false,
        expectedAck: tag,
        timeoutMs: 1000,
      );

  bool traceResult = true;

  Uint8List? sentTextPubkey;
  String? sentText;
  int? sentTextAttempt;
  int? sentTextTimestamp;
  int? sentTextType;
  SentResult? sentTextResult;

  @override
  Future<SentResult> sendTextMessage(Uint8List pubkey, String text,
      {int txtType = txtTypePlain, int attempt = 0, int? timestamp}) async {
    sentTextPubkey = pubkey;
    sentText = text;
    sentTextAttempt = attempt;
    sentTextTimestamp = timestamp;
    sentTextType = txtType;
    return sentTextResult ??
        const SentResult(success: true, expectedAck: 0x1234, timeoutMs: 5000);
  }

  @override
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async =>
      pathDiscoveryResult;

  SentResult pathDiscoveryResult = const SentResult(
      success: true, isFlood: true, expectedAck: 0, timeoutMs: 5000);

  QueuedMessage? nextMessage;
  CompanionOperationError? syncNextError;

  @override
  Future<QueuedMessage?> syncNextMessage() async {
    if (syncNextError != null) throw syncNextError!;
    final msg = nextMessage;
    nextMessage = null;
    return msg;
  }

  @override
  Future<Uint8List> sign(Uint8List message) {
    lastSignedMessage = Uint8List.fromList(message);
    if (signError != null) throw signError!;
    return identity.sign(message);
  }

  Uint8List? lastSignedMessage;
  Object? signError;

  int identityImports = 0;
  Object? identitySaveError;
  Uint8List? exportKeyOverride;
  CompanionOperationError? exportKeyError;

  @override
  Future<Uint8List> exportPrivateKey() async {
    if (exportKeyError != null) throw exportKeyError!;
    return exportKeyOverride ?? identity.meshcore64;
  }

  @override
  Future<void> importPrivateKey(Uint8List expandedKey) async {
    if (expandedKey.length != 64 ||
        !await LocalIdentity.validateMeshcore64(expandedKey)) {
      throw const CompanionOperationError(errCodeIllegalArg);
    }
    if (identitySaveError != null) {
      throw const CompanionOperationError(errCodeFileIoError);
    }
    identity = await LocalIdentity.fromMeshcore64(expandedKey);
    identityImports++;
  }

  bool connection = false;
  int logoutCount = 0;

  @override
  bool hasConnection(Uint8List pubkey) => connection;

  @override
  bool logout(Uint8List pubkey) {
    logoutCount++;
    return connection;
  }

  SentResult loginResult = const SentResult(
      success: true, isFlood: false, expectedAck: 0x7777, timeoutMs: 15000);
  String? loginPassword;

  @override
  Future<SentResult> sendLogin(Uint8List pubkey, String password) async {
    loginPassword = password;
    return loginResult;
  }

  SentResult statusResult = const SentResult(
      success: true, isFlood: true, expectedAck: 0x8888, timeoutMs: 15000);

  @override
  Future<SentResult> sendStatusReq(Uint8List pubkey) async => statusResult;

  Uint8List? floodScopeKey;
  bool floodUnscoped = false;
  String defaultScopeName = '';
  Uint8List? defaultScopeKey;
  int reboots = 0;

  @override
  void setFloodScopeKey(Uint8List? key) {
    floodScopeKey = key;
    floodUnscoped = false;
  }

  @override
  void setFloodUnscoped() => floodUnscoped = true;

  @override
  Future<void> setDefaultFloodScope(String name, Uint8List? key) async {
    if (defaultFloodScopeError != null) throw defaultFloodScopeError!;
    defaultScopeName = name;
    defaultScopeKey = key;
  }

  CompanionOperationError? defaultFloodScopeError;

  @override
  (String, Uint8List?) getDefaultFloodScope() =>
      (defaultScopeName, defaultScopeKey);

  @override
  Future<void> reboot() async => reboots++;

  Uint8List? anonPubkey;
  Uint8List? anonData;

  @override
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) async {
    anonPubkey = pubkey;
    anonData = data;
    return anonResult;
  }

  SentResult anonResult = const SentResult(
      success: true, isFlood: false, expectedAck: 0x4242, timeoutMs: 10000);

  Uint8List? binPubkey;
  Uint8List? binData;

  @override
  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) async {
    binPubkey = pubkey;
    binData = data;
    return binaryResult;
  }

  SentResult binaryResult = const SentResult(
      success: true, isFlood: false, expectedAck: 0x5151, timeoutMs: 10000);

  Uint8List? contactBlob;
  Uint8List? exportedFor;
  Uint8List? importedData;
  Uint8List? sharedPubkey;

  @override
  Future<Uint8List?> exportContact(Uint8List? pubkey) async {
    exportedFor = pubkey;
    return contactBlob;
  }

  @override
  Future<bool> importContact(Uint8List data) async {
    importedData = data;
    return importContactResult;
  }

  bool importContactResult = true;

  @override
  Future<bool> shareContact(Uint8List pubkey) async {
    sharedPubkey = pubkey;
    return shareContactResult;
  }

  bool shareContactResult = true;

  Uint8List allowedRepeatFreq = Uint8List(0);
  CompanionOperationError? allowedRepeatFreqError;

  @override
  Future<Uint8List> getAllowedRepeatFreq() async {
    if (allowedRepeatFreqError != null) throw allowedRepeatFreqError!;
    return allowedRepeatFreq;
  }

  Uint8List? rawPayload;
  Uint8List? rawPath;
  int? rawPathLenByte;

  @override
  Future<bool> sendRawData(
      Uint8List payload, Uint8List path, int pathLenByte) async {
    rawPayload = payload;
    rawPath = path;
    rawPathLenByte = pathLenByte;
    return rawDataResult;
  }

  bool rawDataResult = true;

  Packet? rawPacket;
  int? rawPriority;
  bool rawPacketResult = true;

  @override
  Future<bool> sendRawPacket(Packet packet, int priority) async {
    rawPacket = packet;
    rawPriority = priority;
    return rawPacketResult;
  }

  Uint8List? controlData;
  bool controlDataResult = true;

  @override
  Future<bool> sendControlData(Uint8List data) async {
    controlData = data;
    return controlDataResult;
  }

  final advertPaths = <String, AdvertPath>{};

  @override
  AdvertPath? getAdvertPath(Uint8List prefix) =>
      advertPaths[bytesToHex(prefix)];
}
