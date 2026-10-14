import 'dart:async';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'node_store.dart';

class _PendingAck {
  _PendingAck(this.crc, this.contactPubkey, this.timer);
  final int crc;
  final Uint8List contactPubkey;
  final Timer timer;
}

/// Maximum number of inbound messages held for the client before the oldest
/// is dropped. Matches openHop's `DEFAULT_OFFLINE_QUEUE_SIZE`.
const int defaultOfflineQueueSize = 512;

/// The reimplemented MeshCore companion node.
///
/// Holds the proxy identity and all node state, drives the app-facing
/// [CompanionBridge] surface, and uses a [RadioLink] purely as a raw radio:
/// outbound packets go through `sendRawPacket`, and every received frame
/// arrives via the raw RX listener.
class MeshNode extends CompanionBridge {
  MeshNode({
    required this.identity,
    required this.link,
    NodePrefs? prefs,
    DeviceInfo? deviceInfo,
    this.store,
    this.ackTimeout = const Duration(seconds: 10),
    this.maxQueueSize = defaultOfflineQueueSize,
  })  : prefs = prefs ?? NodePrefs(),
        deviceInfo_ = deviceInfo ?? const DeviceInfo() {
    channels[0] = _defaultChannel();
  }

  final LocalIdentity identity;
  final RadioLink link;
  final NodePrefs prefs;
  final DeviceInfo deviceInfo_;
  final Duration ackTimeout;

  /// Optional persistence backend. When set, [load] restores the last saved
  /// state and every mutation is written back with [NodeStore.save].
  final NodeStore? store;

  /// Maximum number of queued inbound messages; oldest are dropped on overflow.
  final int maxQueueSize;

  final List<Contact> contacts = [];
  final Map<int, Channel> channels = {};
  final List<QueuedMessage> _messageQueue = [];
  final List<_PendingAck> _pendingAcks = [];
  final Map<String, AdvertPath> _advertPaths = {};

  static Channel _defaultChannel() => Channel(
        name: 'public',
        secret: Uint8List.fromList(LocalIdentity.defaultPublicChannelSecret),
      );

  /// Restore persisted state from [store], if one is configured. Call before
  /// [start] so the node comes up with the previously known contacts,
  /// channels, queue, and preferences.
  Future<void> load() async {
    final state = await store?.load();
    if (state == null) return;
    prefs.copyFrom(state.prefs);
    contacts
      ..clear()
      ..addAll(state.contacts);
    channels
      ..clear()
      ..addAll(state.channels);
    channels.putIfAbsent(0, _defaultChannel);
    _messageQueue
      ..clear()
      ..addAll(state.queue);
    _advertPaths
      ..clear()
      ..addAll(state.advertPaths);
  }

  BatteryReading _battery =
      const BatteryReading(millivolts: 0, storageUsedKb: 0, storageTotalKb: 0);

  final Map<String, int> _packetStats = {
    'recv': 0,
    'sent': 0,
    'flood_tx': 0,
    'direct_tx': 0,
    'flood_rx': 0,
    'direct_rx': 0,
    'recv_errors': 0,
  };

  int get _selfHash => identity.publicKey[0];

  /// Attach the raw RX listener. Call once the device link is connected.
  void start() {
    link.setRawRxListener(_onRawFrame);
    unawaited(_readBattery());
  }

  void stop() {
    link.setRawRxListener(null);
    for (final ack in _pendingAcks) {
      ack.timer.cancel();
    }
    _pendingAcks.clear();
  }

  Future<void> _readBattery() async {
    final b = await link.battery();
    if (b != null) _battery = b;
  }

  // -------------------------------------------------------------------------
  // CompanionBridge: identity / info
  // -------------------------------------------------------------------------

  @override
  Uint8List getPublicKey() => identity.publicKey;

  @override
  NodePrefs getSelfInfo() => prefs;

  @override
  DeviceInfo getDeviceInfo() => deviceInfo_;

  @override
  BatteryReading getBatteryAndStorage() => _battery;

  @override
  Future<Uint8List> sign(Uint8List message) => identity.sign(message);

  // -------------------------------------------------------------------------
  // Contacts
  // -------------------------------------------------------------------------

  @override
  List<Contact> getContacts({int since = 0}) =>
      contacts.where((c) => c.lastmod > since).toList();

  @override
  Contact? getContactByKey(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    for (final c in contacts) {
      if (c.publicKeyHex == hex) return c;
    }
    return null;
  }

  @override
  Contact? getContactByKeyPrefix(Uint8List prefix) {
    for (final c in contacts) {
      if (c.publicKey.length >= prefix.length &&
          _bytesEqual(c.publicKey.sublist(0, prefix.length), prefix)) {
        return c;
      }
    }
    return null;
  }

  @override
  bool addUpdateContact(Contact contact) {
    final idx = contacts.indexWhere((c) => c.publicKeyHex == contact.publicKeyHex);
    if (idx >= 0) {
      contacts[idx] = contact;
    } else {
      contacts.add(contact);
    }
    _persist();
    return true;
  }

  @override
  bool removeContact(Uint8List pubkey) {
    final hex = bytesToHex(pubkey);
    final before = contacts.length;
    contacts.removeWhere((c) => c.publicKeyHex == hex);
    if (contacts.length == before) return false;
    _persist();
    return true;
  }

  @override
  bool resetPath(Uint8List pubkey) {
    final c = getContactByKey(pubkey);
    if (c == null) return false;
    c.outPath = Uint8List(0);
    c.outPathLen = -1;
    _persist();
    return true;
  }

  // -------------------------------------------------------------------------
  // Channels
  // -------------------------------------------------------------------------

  @override
  Channel? getChannel(int index) => channels[index];

  @override
  int get maxChannels => deviceInfo_.maxChannels;

  @override
  bool setChannel(int index, String name, Uint8List secret) {
    channels[index] = Channel(name: name, secret: Uint8List.fromList(secret));
    _persist();
    return true;
  }

  int _channelHash(Uint8List secret) {
    final key16 = Uint8List(16);
    key16.setRange(0, secret.length.clamp(0, 16), secret);
    return CryptoUtils.sha256(key16)[0];
  }

  // -------------------------------------------------------------------------
  // Adverts
  // -------------------------------------------------------------------------

  @override
  Future<bool> advertise({bool flood = true}) async {
    final packet = await PacketBuilder.createAdvert(
      identity: identity,
      name: prefs.nodeName,
      lat: prefs.latitude,
      lon: prefs.longitude,
      flags: prefs.advType,
      flood: flood,
    );
    await _transmit(packet, flood: flood);
    return true;
  }

  @override
  void setAdvertName(String name) {
    prefs.nodeName = name;
    _persist();
  }

  @override
  void setAdvertLatLon(double lat, double lon) {
    prefs.latitude = lat;
    prefs.longitude = lon;
    _persist();
  }

  // -------------------------------------------------------------------------
  // Messaging
  // -------------------------------------------------------------------------

  @override
  Future<SentResult> sendTextMessage(
    Uint8List pubkey,
    String text, {
    int txtType = txtTypePlain,
    int attempt = 0,
    bool waitForAck = false,
  }) async {
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final (packet, ackCrc) = await PacketBuilder.createTextMessage(
      contact: contact,
      identity: identity,
      message: text,
      attempt: attempt,
      txtType: txtType,
    );
    final flood = !(contact.outPath.isNotEmpty && contact.outPathLen > 0);
    await _transmit(packet, flood: flood);
    final timer = Timer(ackTimeout, () {
      _pendingAcks.removeWhere((a) => a.crc == ackCrc);
    });
    _pendingAcks.add(_PendingAck(ackCrc, contact.publicKey, timer));
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: ackCrc,
      timeoutMs: waitForAck ? ackTimeout.inMilliseconds : 5000,
    );
  }

  @override
  Future<bool> sendChannelMessage(int channelIndex, String text) async {
    final channel = channels[channelIndex];
    if (channel == null) return false;
    final packet = PacketBuilder.createGroupText(
      channel: channel,
      message: text,
      senderName: prefs.nodeName,
    );
    await _transmit(packet, flood: true);
    return true;
  }

  @override
  QueuedMessage? syncNextMessage() {
    if (_messageQueue.isEmpty) return null;
    final msg = _messageQueue.removeAt(0);
    _persist();
    return msg;
  }

  @override
  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) async {
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: data.isEmpty ? 0 : data[0],
      data: data.length > 1 ? data.sublist(1) : const [],
    );
    final flood = !(contact.outPath.isNotEmpty && contact.outPathLen > 0);
    await _transmit(packet, flood: flood);
    return SentResult(
        success: true, isFlood: flood, expectedAck: 0, timeoutMs: 10000);
  }

  @override
  AdvertPath? getAdvertPath(Uint8List prefix) =>
      _advertPaths[bytesToHex(prefix)];

  @override
  Uint8List? exportContact(Uint8List? pubkey) {
    final contact = pubkey == null ? null : getContactByKey(pubkey);
    if (contact == null) return null;
    return Uint8List.fromList([
      ...contact.publicKey,
      ...(BufferWriter()..writeCString(contact.name, 32)).toBytes(),
      ...(BufferWriter()..writeInt32Le((contact.gpsLat * 1e6).round())).toBytes(),
      ...(BufferWriter()..writeInt32Le((contact.gpsLon * 1e6).round())).toBytes(),
    ]);
  }

  // -------------------------------------------------------------------------
  // Radio configuration (pass-through)
  // -------------------------------------------------------------------------

  @override
  void setRadioParams(int freqHz, int bwHz, int sf, int cr) {
    prefs.frequencyHz = freqHz;
    prefs.bandwidthHz = bwHz;
    prefs.spreadingFactor = sf;
    prefs.codingRate = cr;
    _persist();
    unawaited(
      link.setRadioParams(RadioParams(
        frequencyHz: freqHz,
        bandwidthHz: bwHz,
        spreadingFactor: sf,
        codingRate: cr,
        txPowerDbm: prefs.txPowerDbm,
      )),
    );
  }

  @override
  void setTxPower(int dbm) {
    prefs.txPowerDbm = dbm;
    _persist();
    unawaited(link.setTxPower(dbm));
  }

  /// Adopt the connected device's actual radio parameters as the node's own
  /// without re-configuring the device (used once at connect time).
  void syncRadioParams(RadioParams params) {
    prefs.frequencyHz = params.frequencyHz;
    prefs.bandwidthHz = params.bandwidthHz;
    prefs.spreadingFactor = params.spreadingFactor;
    prefs.codingRate = params.codingRate;
    prefs.txPowerDbm = params.txPowerDbm;
    _persist();
  }

  @override
  Map<String, Object?> getStats(int statsType) {
    switch (statsType) {
      case statsTypeCore:
        return {
          'battery_mv': _battery.millivolts,
          'uptime_secs': 0,
          'errors': _packetStats['recv_errors'] ?? 0,
          'queue_len': _messageQueue.length,
        };
      case statsTypeRadio:
        return {
          'noise_floor': 0,
          'last_rssi': 0,
          'last_snr_scaled': 0,
          'tx_air_secs': 0,
          'rx_air_secs': 0,
        };
      default:
        return Map<String, Object?>.from(_packetStats);
    }
  }

  // -------------------------------------------------------------------------
  // RX path
  // -------------------------------------------------------------------------

  Future<void> _transmit(Packet packet, {required bool flood}) async {
    _packetStats['sent'] = (_packetStats['sent'] ?? 0) + 1;
    _packetStats[flood ? 'flood_tx' : 'direct_tx'] =
        (_packetStats[flood ? 'flood_tx' : 'direct_tx'] ?? 0) + 1;
    await link.sendRawPacket(packet.writeTo());
  }

  Future<void> _onRawFrame(double snr, int rssi, Uint8List raw) async {
    final packet = Packet.readFrom(raw);
    if (packet == null) {
      _packetStats['recv_errors'] = (_packetStats['recv_errors'] ?? 0) + 1;
      return;
    }
    _packetStats['recv'] = (_packetStats['recv'] ?? 0) + 1;
    _packetStats[packet.isRouteFlood ? 'flood_rx' : 'direct_rx'] =
        (_packetStats[packet.isRouteFlood ? 'flood_rx' : 'direct_rx'] ?? 0) + 1;
    packet.snr = snr;
    packet.rssi = rssi;

    switch (packet.payloadType) {
      case payloadTypeAdvert:
        await _onAdvert(packet);
      case payloadTypeTxtMsg:
        await _onDirectText(packet);
      case payloadTypeGrpTxt:
        _onGroupText(packet);
      case payloadTypeAck:
        _onAck(packet);
      default:
        break;
    }
  }

  Future<void> _onAdvert(Packet packet) async {
    if (!await PacketBuilder.verifyAdvert(packet.payload)) return;
    final pubkey = Uint8List.fromList(packet.payload.sublist(0, pubKeySize));
    if (_bytesEqual(pubkey, identity.publicKey)) return;
    final ts = BufferReader(packet.payload.sublist(pubKeySize)).readUInt32Le();
    final appdata =
        packet.payload.sublist(pubKeySize + timestampSize + signatureSize);
    final decoded = PacketBuilder.decodeAdvertData(appdata);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final existing = getContactByKey(pubkey);
    final contact = existing ?? Contact(publicKey: pubkey);
    contact.name = decoded.name;
    contact.advType = decoded.flags & 0x0F;
    contact.flags = decoded.flags;
    contact.gpsLat = decoded.lat;
    contact.gpsLon = decoded.lon;
    contact.lastAdvertTimestamp = ts;
    contact.lastmod = now;
    contact.outPath = packet.path;
    contact.outPathLen = packet.path.isEmpty ? -1 : packet.pathLenByte;

    _advertPaths[bytesToHex(pubkey.sublist(0, 7))] = AdvertPath(
      publicKeyPrefix: pubkey.sublist(0, 7),
      name: decoded.name,
      pathLen: packet.pathLenByte,
      path: packet.path,
      recvTimestamp: now,
    );
    // Persists both the contact and the advert path in one snapshot.
    addUpdateContact(contact);

    if (existing == null) {
      pushSink?.pushNewAdvert(_contactFrameBody(contact));
    } else {
      pushSink?.pushAdvert(pubkey);
      pushSink?.pushPathUpdated(pubkey);
    }
  }

  Future<void> _onDirectText(Packet packet) async {
    if (packet.payload.length < 2) return;
    if (packet.payload[0] != _selfHash) return; // not addressed to us
    final srcHash = packet.payload[1];
    Contact? sender;
    for (final c in contacts) {
      if (c.publicKey[0] == srcHash) {
        sender = c;
        break;
      }
    }
    if (sender == null) return;

    final secret = await identity.sharedSecret(sender.publicKey);
    late Uint8List plaintext;
    try {
      plaintext = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        packet.payload.sublist(2),
      );
    } catch (_) {
      return;
    }
    if (plaintext.length < 5) return;
    final r = BufferReader(plaintext);
    final ts = r.readUInt32Le();
    final flagsByte = r.readByte();
    final text = r.readCString();
    final attempt = flagsByte & 0x03;

    // ACK the sender and queue the message for the client.
    final ack = PacketBuilder.createAck(
      senderPubkey: sender.publicKey,
      timestamp: ts,
      attempt: attempt,
      text: Uint8List.fromList(text.codeUnits),
    );
    await _transmit(ack, flood: false);

    _enqueueMessage(QueuedMessage(
      senderKey: sender.publicKey,
      txtType: (flagsByte >> 2) & 0x3F,
      timestamp: ts,
      text: text,
      snr: packet.snr,
      rssi: packet.rssi,
    ));
  }

  void _onGroupText(Packet packet) {
    if (packet.payload.length < 3) return;
    final channelHash = packet.payload[0];
    Channel? channel;
    int? channelIdx;
    channels.forEach((idx, ch) {
      if (_channelHash(ch.secret) == channelHash) {
        channel = ch;
        channelIdx = idx;
      }
    });
    if (channel == null) return;
    final ch = channel!;
    final secret = Uint8List(32);
    secret.setRange(0, ch.secret.length.clamp(0, 32), ch.secret);
    late Uint8List plaintext;
    try {
      plaintext = CryptoUtils.macThenDecrypt(
        secret.sublist(0, 16),
        secret,
        packet.payload.sublist(1),
      );
    } catch (_) {
      return;
    }
    if (plaintext.length < 5) return;
    final r = BufferReader(plaintext);
    final ts = r.readUInt32Le();
    r.skipBytes(1); // flags
    final text = r.readCString();
    _enqueueMessage(QueuedMessage(
      senderKey: Uint8List(32),
      timestamp: ts,
      text: text,
      isChannel: true,
      channelIdx: channelIdx ?? 0,
      snr: packet.snr,
      rssi: packet.rssi,
    ));
  }

  void _onAck(Packet packet) {
    if (packet.payload.length < 4) return;
    final crc = packet.payload[0] |
        (packet.payload[1] << 8) |
        (packet.payload[2] << 16) |
        (packet.payload[3] << 24);
    final idx = _pendingAcks.indexWhere((a) => a.crc == (crc & 0xFFFFFFFF));
    if (idx < 0) return;
    _pendingAcks.removeAt(idx).timer.cancel();
    pushSink?.pushSendConfirmed(crc & 0xFFFFFFFF);
  }

  // -------------------------------------------------------------------------
  // Persistence
  // -------------------------------------------------------------------------

  void _enqueueMessage(QueuedMessage message) {
    _messageQueue.add(message);
    while (_messageQueue.length > maxQueueSize) {
      _messageQueue.removeAt(0); // drop oldest on overflow
    }
    pushSink?.pushMsgWaiting();
    _persist();
  }

  void _persist() {
    final s = store;
    if (s == null) return;
    unawaited(s.save(NodeState(
      prefs: NodePrefs()..copyFrom(prefs),
      contacts: contacts.map((c) => c.clone()).toList(),
      channels: {
        for (final e in channels.entries)
          e.key: Channel(
            name: e.value.name,
            secret: Uint8List.fromList(e.value.secret),
          ),
      },
      queue: List<QueuedMessage>.of(_messageQueue),
      advertPaths: Map<String, AdvertPath>.of(_advertPaths),
    )));
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  Uint8List _contactFrameBody(Contact c) {
    final pathLen = c.outPathLen < 0 ? 0xFF : c.outPathLen.clamp(0, 255);
    final w = BufferWriter()
      ..writeBytes(c.publicKey)
      ..writeByte(c.advType)
      ..writeByte(c.flags)
      ..writeByte(pathLen);
    w.writeBytesPadded(c.outPath, maxPathSize);
    w.writeCString(c.name, maxNameSize);
    w.writeUInt32Le(c.lastAdvertTimestamp);
    w.writeInt32Le((c.gpsLat * 1e6).round());
    w.writeInt32Le((c.gpsLon * 1e6).round());
    w.writeUInt32Le(c.lastmod);
    return w.toBytes();
  }

  static bool _bytesEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
