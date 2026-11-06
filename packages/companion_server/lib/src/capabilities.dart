import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'mesh_stats.dart';

/// Capability interfaces for [CompanionBridge].
///
/// The bridge implements all of them; a test or alternate host can implement
/// only the slice it exercises. The server still accepts the full composite
/// because a protocol client can reach every command.

abstract interface class ContactHost {
  List<Contact> getContacts({int since = 0});

  /// Total persistent contacts, independent of the `since` filter. Stock
  /// firmware reports this total in `PACKET_CONTACT_START`.
  int get contactCount;
  Contact? getContactByKey(Uint8List pubkey);
  Contact? getPersistentContactByKey(Uint8List pubkey);
  Contact? getContactByKeyPrefix(Uint8List prefix);
  Future<void> addUpdateContact(Contact contact, {bool hasGps = true});
  Future<void> removeContact(Uint8List pubkey);
  Future<void> resetPath(Uint8List pubkey);
  Future<Uint8List?> exportContact(Uint8List? pubkey);
  Future<bool> importContact(Uint8List data);
  Future<bool> shareContact(Uint8List pubkey);
  AdvertPath? getAdvertPath(Uint8List prefix);
}

abstract interface class MessageHost {
  Future<SentResult> sendTextMessage(
    Uint8List pubkey,
    String text, {
    int txtType = txtTypePlain,
    int attempt = 0,
    int? timestamp,
  });
  Future<bool> sendChannelMessage(
    int channelIndex,
    String text, {
    int? timestamp,
  });
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  });
  Future<bool> advertise({bool flood = false});
  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data);
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data);
  Future<SentResult> sendTelemetryRequest(
    Uint8List pubkey, {
    bool wantBase = true,
    bool wantLocation = true,
    bool wantEnvironment = true,
  });
  Future<SentResult> sendTracePathRaw(
    int tag,
    int authCode,
    int flags,
    Uint8List pathBytes,
  );
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey);
  Future<SentResult> sendLogin(Uint8List pubkey, String password);
  Future<SentResult> sendStatusReq(Uint8List pubkey);
  bool logout(Uint8List pubkey);
  bool hasConnection(Uint8List pubkey);
  Future<bool> sendRawData(
    Uint8List payload,
    Uint8List path,
    int pathLenByte,
  );
  Future<bool> sendRawPacket(Packet packet, int priority);
  Future<bool> sendControlData(Uint8List data);
  Future<QueuedMessage?> syncNextMessage();
}

abstract interface class RadioConfigHost {
  Future<void> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  });
  Future<void> setTxPower(int dbm);
  int getPathHashMode();
  Future<void> setPathHashMode(int mode);
  Future<TuningParams> getTuningParams();
  Future<void> setTuningParams(int rxDelayBaseMs, int airtimeFactorMs);
  Future<Uint8List> getAllowedRepeatFreq();
  Future<void> setAdvertName(String name);
  Future<void> setAdvertLatLon(double lat, double lon);
  int getAutoAddConfig();
  int getAutoAddMaxHops();
  Future<void> setAutoAddConfig(int flags, int? maxHops);
  Future<void> setOtherParams({
    required int manualAddContacts,
    int? telemetryModes,
    int? advertLocPolicy,
    int? multiAcks,
  });
  void setFloodScopeKey(Uint8List? key);
  void setFloodUnscoped();
  Future<void> setDefaultFloodScope(String name, Uint8List? key);
  (String, Uint8List?) getDefaultFloodScope();
  int get maxChannels;
  Channel? getChannel(int index);
  Future<void> setChannel(int index, String name, Uint8List secret);
}

abstract interface class IdentityHost {
  Uint8List getPublicKey();
  Future<Uint8List> exportPrivateKey();
  Future<void> importPrivateKey(Uint8List expandedKey);
  Future<Uint8List> sign(Uint8List message);
}

abstract interface class CompanionCliHost {
  Future<String?> runCliCommand(String command);
  Future<String> runCliCommandBytes(Uint8List payload);
  Map<String, String> getCustomVars();
  Future<void> setCustomVar(String name, String value);
}

abstract interface class StatsHost {
  Future<BatteryReading> getBatteryAndStorage();
  Future<MeshStats> getStats(int statsType);
  int getTime();
  bool setTime(int seconds);
  Future<Uint8List> getSelfTelemetry();
}

abstract interface class LifecycleHost {
  NodePrefs getSelfInfo();
  DeviceInfo getDeviceInfo();
  Future<void> reboot();
  int get lifecycleGeneration;
}
