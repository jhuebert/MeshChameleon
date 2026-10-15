import 'dart:async';
import 'dart:convert';
import 'dart:math';
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

/// A login keep-alive session with a repeater/room server.
class _Connection {
  _Connection(this.pubkey, this.interval);

  final Uint8List pubkey;
  Duration interval;
  Timer? timer;

  /// Epoch seconds of the last activity; the session is dropped once this is
  /// older than 2.5x [interval].
  int lastActivity = DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// The ACK hash we expect from the next keep-alive request.
  int? expectedAck;

  void stop() {
    timer?.cancel();
    timer = null;
    expectedAck = null;
  }
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

  /// Pending path-discovery requests: tag -> target public key. A matching
  /// `PAYLOAD_TYPE_RESPONSE` extra in a returned-path packet is pushed to the
  /// client via `PUSH_CODE_PATH_DISCOVERY_RESPONSE`.
  final Map<int, Uint8List> _pendingDiscovery = {};

  /// Pending login/status requests, matched by the sender's 4-byte pubkey
  /// prefix (the firmware's legacy matching scheme).
  Uint8List? _pendingLogin;
  Uint8List? _pendingStatus;

  /// Pending telemetry requests, matched by the reflected request tag. The
  /// response (when it arrives) is pushed via
  /// `PUSH_CODE_TELEMETRY_RESPONSE`.
  final Map<int, Uint8List> _pendingTelemetry = {};

  /// Pending binary/anon requests, matched by the reflected request tag. The
  /// response (when it arrives) is pushed via `PUSH_CODE_BINARY_RESPONSE`.
  final Map<int, Uint8List> _pendingBinary = {};

  /// Active login keep-alive sessions, keyed by server public key hex.
  final Map<String, _Connection> _connections = {};

  /// `CMD_SET_FLOOD_SCOPE_KEY` override (null = use the default scope) and the
  /// "force unscoped" flag. Both are cleared by [reboot].
  Uint8List? _floodScopeOverride;
  bool _floodUnscoped = false;

  /// Recently seen packet hashes (hex -> epoch seconds). Used to suppress
  /// duplicate queued messages (retransmits, repeated reception) while still
  /// ACKing direct duplicates. Mirrors `Mesh.cpp`'s `hasSeen` table and
  /// openHop's `_check_dedup` (300s TTL, 1000 entries). Dart's Map preserves
  /// insertion order, so the oldest entry is `keys.first`.
  final Map<String, int> _seenPackets = {};
  static const int _seenPacketTtlSecs = 300;
  static const int _seenPacketMax = 1000;

  /// Returns `true` if [packetHash] was already seen within the TTL window.
  bool _isDuplicate(Uint8List packetHash) {
    final key = bytesToHex(packetHash);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (_seenPackets.containsKey(key)) {
      _seenPackets.remove(key);
      _seenPackets[key] = now; // refresh recency
      return true;
    }
    _seenPackets[key] = now;
    _seenPackets.removeWhere((_, ts) => now - ts > _seenPacketTtlSecs);
    while (_seenPackets.length > _seenPacketMax) {
      _seenPackets.remove(_seenPackets.keys.first);
    }
    return false;
  }

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

  /// Wall-clock time of the last [start], used for the uptime stat.
  int _startedAtMillis = DateTime.now().millisecondsSinceEpoch;

  /// Most recent received-frame radio metrics, reported in the radio stats.
  int _lastRxRssi = 0;
  int _lastRxSnrScaled = 0;

  /// Accumulated on-air time (microseconds) for the radio stats counters.
  int _txAirMicros = 0;
  int _rxAirMicros = 0;

  /// Estimated airtime of an [bytes]-byte frame under the current radio
  /// settings, or 0 when the parameters are not usable.
  int _airtimeMicrosFor(int bytes) {
    final cr = prefs.codingRate <= 4 ? prefs.codingRate + 4 : prefs.codingRate;
    if (prefs.spreadingFactor < 5 ||
        prefs.spreadingFactor > 12 ||
        prefs.bandwidthHz <= 0 ||
        cr < 5 ||
        cr > 8) {
      return 0;
    }
    return loraTimeOnAirMicros(
      payloadBytes: bytes,
      spreadingFactor: prefs.spreadingFactor,
      bandwidthHz: prefs.bandwidthHz,
      codingRate: cr,
    );
  }

  int get _selfHash => identity.publicKey[0];

  /// Attach the raw RX listener. Call once the device link is connected.
  void start() {
    _startedAtMillis = DateTime.now().millisecondsSinceEpoch;
    link.setRawRxListener(_onRawFrame);
    unawaited(_readBattery());
  }

  void stop() {
    link.setRawRxListener(null);
    for (final ack in _pendingAcks) {
      ack.timer.cancel();
    }
    _pendingAcks.clear();
    for (final conn in _connections.values) {
      conn.stop();
    }
    _connections.clear();
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
    final idx =
        contacts.indexWhere((c) => c.publicKeyHex == contact.publicKeyHex);
    if (idx >= 0) {
      contacts[idx] = contact;
    } else {
      final max = deviceInfo_.maxContacts;
      final capped = max > 0 && contacts.length >= max;
      if (capped) {
        final overwrite = _oldestOverwritableContactIndex();
        if (overwrite < 0) return false; // table full, overwrite disabled
        contacts[overwrite] = contact;
      } else {
        contacts.add(contact);
      }
    }
    _persist();
    return true;
  }

  /// Index of the oldest non-favourite contact, or -1 when overwrite-on-full is
  /// disabled (`AUTO_ADD_OVERWRITE_OLDEST`) or every contact is a favourite.
  int _oldestOverwritableContactIndex() {
    if ((prefs.autoaddConfig & autoAddOverwriteOldest) == 0) return -1;
    var oldestIdx = -1;
    var oldestLastmod = 0x7FFFFFFF;
    for (var i = 0; i < contacts.length; i++) {
      final isFavourite = (contacts[i].flags & 0x01) != 0;
      if (!isFavourite && contacts[i].lastmod < oldestLastmod) {
        oldestLastmod = contacts[i].lastmod;
        oldestIdx = i;
      }
    }
    return oldestIdx;
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
    await _transmit(packet, flood: flood, scoped: true);
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
    await _transmit(packet, flood: flood, scoped: true);
    // CLI data/commands are not acknowledged; don't track a pending ACK.
    final isCommand =
        txtType == txtTypeCliData || txtType == txtTypeCliCommand;
    if (isCommand) {
      return SentResult(
        success: true,
        isFlood: flood,
        expectedAck: 0,
        timeoutMs: waitForAck ? ackTimeout.inMilliseconds : 5000,
      );
    }
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
    await _transmit(packet, flood: true, scoped: true);
    return true;
  }

  @override
  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) async {
    final channel = channels[channelIndex];
    if (channel == null) return false;
    final pathLen = pathLenEncoded ?? 0xFF;
    final pathBytes = path ?? const <int>[];
    final packet = PacketBuilder.createGroupData(
      channel: channel,
      dataType: dataType,
      data: payload,
      path: pathBytes,
      pathLenEncoded: pathLen,
    );
    final flood = pathLen == 0xFF || pathBytes.isEmpty;
    await _transmit(packet, flood: flood, scoped: true);
    return true;
  }

  @override
  Future<bool> sendControlData(Uint8List data) async {
    await _transmit(PacketBuilder.createControlData(data), flood: false);
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
    final tag = _nextRequestTag();
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: data.isEmpty ? 0 : data[0],
      data: data.length > 1 ? data.sublist(1) : const [],
      timestamp: tag,
    );
    final flood = !(contact.outPath.isNotEmpty && contact.outPathLen > 0);
    await _transmit(packet, flood: flood);
    _pendingBinary[tag] = Uint8List.fromList(pubkey);
    return SentResult(
        success: true, isFlood: flood, expectedAck: tag, timeoutMs: 10000);
  }

  @override
  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) async {
    // Like the firmware, ensure a contact exists (a zero-hop one if unknown) so
    // the response can be decrypted and matched.
    final contact = getContactByKey(pubkey) ?? _ensureAnonContact(pubkey);
    final tag = _nextRequestTag();
    final flood = !(contact.outPath.isNotEmpty && contact.outPathLen > 0);
    final packet = await PacketBuilder.createAnonRequest(
      contact: contact,
      identity: identity,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    await _transmit(packet, flood: flood);
    _pendingBinary[tag] = Uint8List.fromList(pubkey);
    return SentResult(
        success: true, isFlood: flood, expectedAck: tag, timeoutMs: 10000);
  }

  /// Monotonic-enough request tag that doesn't collide with an in-flight request.
  int _nextRequestTag() {
    var tag = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    while (_pendingBinary.containsKey(tag) ||
        _pendingTelemetry.containsKey(tag) ||
        _pendingDiscovery.containsKey(tag)) {
      tag++;
    }
    return tag;
  }

  /// Register a zero-hop contact for [pubkey] if one doesn't exist yet.
  Contact _ensureAnonContact(Uint8List pubkey) {
    final contact = Contact(
      publicKey: Uint8List.fromList(pubkey),
      advType: advTypeNone,
      lastmod: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
    addUpdateContact(contact);
    return getContactByKey(pubkey) ?? contact;
  }

  @override
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async {
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    var tag = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    while (_pendingDiscovery.containsKey(tag)) {
      tag++;
    }
    final rng = Random.secure();
    // req_data = [type][inverse base-telemetry permission mask][3 reserved][4 random]
    final reqData = Uint8List.fromList([
      (~telemPermBase) & 0xFF,
      0,
      0,
      0,
      ...List<int>.generate(4, (_) => rng.nextInt(256)),
    ]);
    // Path discovery is a flooded telemetry request (firmware forces flood).
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetTelemetryData,
      data: reqData,
      timestamp: tag,
      flood: true,
    );
    await _transmit(packet, flood: true);
    _pendingDiscovery[tag] = Uint8List.fromList(pubkey);
    return SentResult(
      success: true,
      isFlood: true,
      expectedAck: tag,
      timeoutMs: 15000,
    );
  }

  @override
  Future<SentResult> sendTelemetryRequest(
    Uint8List pubkey, {
    bool wantBase = true,
    bool wantLocation = true,
    bool wantEnvironment = true,
  }) async {
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    var tag = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    while (_pendingTelemetry.containsKey(tag) ||
        _pendingDiscovery.containsKey(tag)) {
      tag++;
    }
    // The first payload byte is an inverse permissions mask: set the bits for
    // the telemetry classes we do *not* want.
    var inverse = 0;
    if (!wantBase) inverse |= telemPermBase;
    if (!wantLocation) inverse |= telemPermLocation;
    if (!wantEnvironment) inverse |= telemPermEnvironment;
    final flood = !(contact.outPath.isNotEmpty && contact.outPathLen > 0);
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetTelemetryData,
      data: [inverse & 0xFF],
      timestamp: tag,
      flood: flood,
    );
    await _transmit(packet, flood: flood);
    _pendingTelemetry[tag] = Uint8List.fromList(pubkey);
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: 10000,
    );
  }

  @override
  Future<bool> sendTracePathRaw(
    int tag,
    int authCode,
    int flags,
    Uint8List pathBytes,
  ) async {
    final packet = PacketBuilder.createTrace(
      tag: tag,
      authCode: authCode,
      flags: flags,
      path: pathBytes,
    );
    await _transmit(packet, flood: false);
    return true;
  }

  @override
  Future<SentResult> sendLogin(Uint8List pubkey, String password) async {
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    var tag = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    while (_pendingDiscovery.containsKey(tag)) {
      tag++;
    }
    final pw = utf8.encode(password);
    final pwTrimmed = pw.length > 15 ? pw.sublist(0, 15) : pw;
    // Room servers take a sync cursor before the password.
    final List<int> data = contact.advType == advTypeRoom
        ? [
            ...(BufferWriter()..writeUInt32Le(contact.syncSince)).toBytes(),
            ...pwTrimmed,
          ]
        : pwTrimmed;
    final flood = !(contact.outPath.isNotEmpty && contact.outPathLen > 0);
    final packet = await PacketBuilder.createAnonRequest(
      contact: contact,
      identity: identity,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    await _transmit(packet, flood: flood);
    _pendingLogin = Uint8List.fromList(pubkey.sublist(0, 4));
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: 15000,
    );
  }

  @override
  Future<SentResult> sendStatusReq(Uint8List pubkey) async {
    final contact = getContactByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    var tag = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    while (_pendingDiscovery.containsKey(tag)) {
      tag++;
    }
    final rng = Random.secure();
    final data = Uint8List.fromList([
      0, 0, 0, 0,
      ...List<int>.generate(4, (_) => rng.nextInt(256)),
    ]);
    final flood = !(contact.outPath.isNotEmpty && contact.outPathLen > 0);
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetStatus,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    await _transmit(packet, flood: flood);
    _pendingStatus = Uint8List.fromList(pubkey.sublist(0, 4));
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: 15000,
    );
  }

  @override
  bool logout(Uint8List pubkey) {
    final prefix = Uint8List.fromList(pubkey.sublist(0, 4));
    if (_pendingLogin != null && _bytesEqual(_pendingLogin!, prefix)) {
      _pendingLogin = null;
    }
    if (_pendingStatus != null && _bytesEqual(_pendingStatus!, prefix)) {
      _pendingStatus = null;
    }
    _stopKeepAlive(pubkey);
    return true;
  }

  @override
  bool hasConnection(Uint8List pubkey) =>
      _connections.containsKey(bytesToHex(pubkey));

  // -------------------------------------------------------------------------
  // Flood scope
  // -------------------------------------------------------------------------

  /// The scope key used for scoped floods: the override (unless unscoped) or
  /// the stored default scope. Zero/absent keys mean unset.
  Uint8List? _effectiveFloodScope() {
    if (_floodUnscoped) return null;
    final override = _floodScopeOverride;
    if (override != null && !_isZeroKey(override)) return override;
    final def = prefs.defaultScopeKey;
    if (def != null && def.length == 16 && !_isZeroKey(def)) return def;
    return null;
  }

  static bool _isZeroKey(Uint8List key) {
    for (final b in key) {
      if (b != 0) return false;
    }
    return true;
  }

  @override
  void setFloodScopeKey(Uint8List? key) {
    _floodScopeOverride = key == null ? null : Uint8List.fromList(key);
    _floodUnscoped = false;
  }

  @override
  void setFloodUnscoped() => _floodUnscoped = true;

  @override
  void setDefaultFloodScope(String name, Uint8List? key) {
    prefs.defaultScopeName = name;
    prefs.defaultScopeKey = key == null ? null : Uint8List.fromList(key);
    _persist();
  }

  @override
  (String, Uint8List?) getDefaultFloodScope() =>
      (prefs.defaultScopeName, prefs.defaultScopeKey);

  @override
  void reboot() {
    // A soft restart of the node engine: drop ephemeral runtime state while
    // keeping persisted prefs, contacts, channels and the queued messages.
    for (final ack in _pendingAcks) {
      ack.timer.cancel();
    }
    _pendingAcks.clear();
    _pendingDiscovery.clear();
    _pendingTelemetry.clear();
    _pendingBinary.clear();
    _pendingLogin = null;
    _pendingStatus = null;
    for (final conn in _connections.values) {
      conn.stop();
    }
    _connections.clear();
    _seenPackets.clear();
    _floodScopeOverride = null;
    _floodUnscoped = false;
  }

  void _startKeepAlive(Uint8List pubkey, int keepAliveSecs) {
    if (keepAliveSecs <= 0) return;
    final key = bytesToHex(pubkey);
    final conn = _connections.putIfAbsent(
      key,
      () => _Connection(
          Uint8List.fromList(pubkey), Duration(seconds: keepAliveSecs)),
    );
    conn.interval = Duration(seconds: keepAliveSecs);
    conn.lastActivity = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    conn.timer?.cancel();
    conn.timer =
        Timer.periodic(conn.interval, (_) => unawaited(_sendKeepAlive(conn)));
  }

  void _stopKeepAlive(Uint8List pubkey) {
    _connections.remove(bytesToHex(pubkey))?.stop();
  }

  /// Diagnostic/test hook: send a keep-alive request now for every active
  /// connection without waiting for the interval timer.
  Future<void> sendKeepAlivesNow() async {
    for (final conn in _connections.values.toList()) {
      await _sendKeepAlive(conn);
    }
  }

  void _markConnectionActive(Uint8List pubkey) {
    final conn = _connections[bytesToHex(pubkey)];
    if (conn != null) {
      conn.lastActivity = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }
  }

  Future<void> _sendKeepAlive(_Connection conn) async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final expire = conn.lastActivity + (conn.interval.inSeconds * 5 ~/ 2);
    if (now >= expire) {
      _connections.remove(bytesToHex(conn.pubkey));
      conn.stop();
      return;
    }
    final contact = getContactByKey(conn.pubkey);
    if (contact == null) {
      _connections.remove(bytesToHex(conn.pubkey));
      conn.stop();
      return;
    }
    // Keep-alive is only usable once we know the direct path to the server.
    if (contact.outPath.isEmpty || contact.outPathLen <= 0) return;

    const syncSince = 0;
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeKeepAlive,
      data: (BufferWriter()..writeUInt32Le(syncSince)).toBytes(),
      timestamp: now,
      flood: false,
    );
    final digest = CryptoUtils.sha256([
      ...(BufferWriter()
            ..writeUInt32Le(now)
            ..writeByte(reqTypeKeepAlive)
            ..writeUInt32Le(syncSince))
          .toBytes(),
      ...identity.publicKey,
    ]);
    conn.expectedAck =
        digest[0] | (digest[1] << 8) | (digest[2] << 16) | (digest[3] << 24);
    await _transmit(packet, flood: false);
  }

  @override
  AdvertPath? getAdvertPath(Uint8List prefix) =>
      _advertPaths[bytesToHex(prefix)];

  @override
  @override
  Future<Uint8List?> exportContact(Uint8List? pubkey) async {
    if (pubkey == null) {
      // Export SELF: a freshly built advert packet blob (the `meshcore://` URI).
      final packet = await PacketBuilder.createAdvert(
        identity: identity,
        name: prefs.nodeName,
        lat: prefs.latitude,
        lon: prefs.longitude,
        flags: prefs.advType,
        flood: true,
      );
      return packet.writeTo();
    }
    return getContactByKey(pubkey)?.rawAdvert;
  }

  @override
  Future<bool> importContact(Uint8List data) async {
    final packet = Packet.readFrom(data);
    if (packet == null || packet.payloadType != payloadTypeAdvert) return false;
    // Simulate receiving it flood-mode (the firmware loops it back as received).
    packet.header = (packet.header & ~phRouteMask) | routeTypeFlood;
    await _onAdvert(packet);
    return true;
  }

  @override
  Future<bool> shareContact(Uint8List pubkey) async {
    final blob = getContactByKey(pubkey)?.rawAdvert;
    if (blob == null) return false;
    final packet = Packet.readFrom(blob);
    if (packet == null) return false;
    // Zero-hop: direct route with an empty path (firmware sendZeroHop).
    packet.header = (packet.header & ~phRouteMask) | routeTypeDirect;
    packet.setPath(const []);
    await _transmit(packet, flood: false);
    return true;
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
    // Path-hash mode is a device capability reported in DEVICE_INFO.
    prefs.pathHashMode = deviceInfo_.pathHashMode;
    _persist();
  }

  @override
  int getPathHashMode() => prefs.pathHashMode;

  @override
  void setPathHashMode(int mode) {
    final clamped = mode.clamp(0, 3);
    prefs.pathHashMode = clamped;
    _persist();
    // Path-hash mode is a firmware v10+ feature; older devices ignore it.
    if (deviceInfo_.firmwareVerCode >= 10) {
      unawaited(link.setPathHashMode(clamped));
    }
  }

  @override
  Future<TuningParams> getTuningParams() async {
    try {
      final params = await link.tuningParams();
      prefs.rxDelayBaseMs = params.rxDelayBaseMs;
      prefs.airtimeFactorMs = params.airtimeFactorMs;
      _persist();
      return params;
    } catch (_) {
      // Fall back to the last known values if the device link is unavailable.
      return TuningParams(
        rxDelayBaseMs: prefs.rxDelayBaseMs,
        airtimeFactorMs: prefs.airtimeFactorMs,
      );
    }
  }

  @override
  void setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) {
    prefs.rxDelayBaseMs = rxDelayBaseMs;
    prefs.airtimeFactorMs = airtimeFactorMs;
    _persist();
    unawaited(link.setTuningParams(TuningParams(
      rxDelayBaseMs: rxDelayBaseMs,
      airtimeFactorMs: airtimeFactorMs,
    )));
  }

  @override
  Future<void> runCliCommand(String command) async {
    // CLI commands are a firmware v14+ feature.
    if (deviceInfo_.firmwareVerCode < 14) return;
    await link.runCliCommand(command);
  }

  @override
  Future<Uint8List> getAllowedRepeatFreq() => link.getAllowedRepeatFreq();

  /// Device housekeeping: zero the device's autonomous advert intervals so the
  /// stock firmware never advertises under its own identity while proxied.
  /// A no-op on firmware older than v14.
  Future<void> zeroAdvertIntervals() async {
    if (deviceInfo_.firmwareVerCode < 14) return;
    await link.runCliCommand('adv_int 0');
    await link.runCliCommand('f_adv_int 0');
  }

  @override
  Map<String, Object?> getStats(int statsType) {
    switch (statsType) {
      case statsTypeCore:
        final uptime = (DateTime.now().millisecondsSinceEpoch - _startedAtMillis)
            .clamp(0, 0xFFFFFFFF) ~/
            1000;
        return {
          'battery_mv': _battery.millivolts,
          'uptime_secs': uptime,
          'errors': _packetStats['recv_errors'] ?? 0,
          'queue_len': _messageQueue.length,
        };
      case statsTypeRadio:
        return {
          'noise_floor': 0,
          'last_rssi': _lastRxRssi,
          'last_snr_scaled': _lastRxSnrScaled,
          'tx_air_secs': _txAirMicros ~/ 1000000,
          'rx_air_secs': _rxAirMicros ~/ 1000000,
        };
      default:
        return Map<String, Object?>.from(_packetStats);
    }
  }

  // -------------------------------------------------------------------------
  // RX path
  // -------------------------------------------------------------------------

  Future<void> _transmit(Packet packet,
      {required bool flood, bool scoped = false}) async {
    if (scoped && flood) {
      final scope = _effectiveFloodScope();
      if (scope != null) packet.applyFloodScope(scope);
    }
    _packetStats['sent'] = (_packetStats['sent'] ?? 0) + 1;
    _packetStats[flood ? 'flood_tx' : 'direct_tx'] =
        (_packetStats[flood ? 'flood_tx' : 'direct_tx'] ?? 0) + 1;
    final bytes = packet.writeTo();
    _txAirMicros += _airtimeMicrosFor(bytes.length);
    await link.sendRawPacket(bytes);
  }

  Future<void> _onRawFrame(double snr, int rssi, Uint8List raw) async {
    _rxAirMicros += _airtimeMicrosFor(raw.length);
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
    _lastRxRssi = rssi;
    _lastRxSnrScaled = (snr * 4).round();

    switch (packet.payloadType) {
      case payloadTypeAdvert:
        await _onAdvert(packet);
      case payloadTypeTxtMsg:
        await _onDirectText(packet);
      case payloadTypeGrpTxt:
        _onGroupText(packet);
      case payloadTypeGrpData:
        _onGroupData(packet);
      case payloadTypeControl:
        _onControlData(packet);
      case payloadTypeTrace:
        _onTrace(packet);
      case payloadTypeAck:
        _onAck(packet);
      case payloadTypeMultipart:
        _onMultipart(packet);
      case payloadTypePath:
        await _onPathReturn(packet);
      case payloadTypeResponse:
        await _onResponse(packet);
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
    contact.rawAdvert = packet.writeTo();

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
    final txtType = (flagsByte >> 2) & 0x3F;

    // Signed messages carry a 4-byte sender prefix before the text.
    final String text;
    final Uint8List ackBytes;
    if (txtType == txtTypeSigned) {
      if (plaintext.length < 9) return;
      r.skipBytes(4); // sender prefix (informational)
      text = r.readCString();
      // Track the room-server sync cursor (highest signed timestamp seen).
      if (ts > sender.syncSince) {
        sender.syncSince = ts;
        _persist();
      }
      final textLen = utf8.encode(text).length;
      final end = (9 + textLen).clamp(0, plaintext.length);
      // The firmware ACKs signed messages with
      // sha256(plaintext up to the text end | self pubkey).
      ackBytes = Uint8List.fromList(
          CryptoUtils.sha256(
                  [...plaintext.sublist(0, end), ...identity.publicKey])
              .sublist(0, 4));
    } else {
      text = r.readCString();
      ackBytes = PacketBuilder.ackHash(
        timestamp: ts,
        flagsByte: flagsByte,
        text: utf8.encode(text),
        senderPubkey: sender.publicKey,
      );
    }

    // Only plain and signed messages are acknowledged; CLI data/commands are
    // not. A flooded direct message is acknowledged with an encrypted
    // path-return (which also teaches the sender the route back); a routed one
    // with a discrete ACK packet.
    final expectsAck = txtType == txtTypePlain || txtType == txtTypeSigned;
    if (expectsAck) {
      if (packet.isRouteFlood) {
        await _transmit(
          PacketBuilder.createPathReturn(
            destHashByte: sender.publicKey[0],
            srcHashByte: identity.publicKey[0],
            secret: secret,
            path: packet.path,
            pathLenEncoded: packet.pathLenByte,
            extraType: payloadTypeAck,
            extra: ackBytes,
          ),
          flood: true,
        );
      } else {
        // With multi_acks enabled, precede the plain ACK with a multipart ACK
        // (the firmware sends one redundant MultiAck, then the ACK).
        if (prefs.multiAcks > 0) {
          await _transmit(
            PacketBuilder.createMultiAck(ackBytes, 1),
            flood: false,
          );
        }
        await _transmit(PacketBuilder.createAckPacket(ackBytes), flood: false);
      }
    }

    // Duplicate reception of the same packet is ACKed again (for reliability)
    // but not queued twice.
    if (_isDuplicate(packet.calculatePacketHash())) return;
    _enqueueMessage(QueuedMessage(
      senderKey: sender.publicKey,
      txtType: txtType,
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
    if (_isDuplicate(packet.calculatePacketHash())) return;
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

  void _onGroupData(Packet packet) {
    if (packet.payload.length < 4) return;
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
    if (plaintext.length < 3) return;
    final dataType = plaintext[0] | (plaintext[1] << 8);
    final dataLen = plaintext[2];
    if (dataType == dataTypeReserved || plaintext.length < 3 + dataLen) return;
    if (_isDuplicate(packet.calculatePacketHash())) return;
    _enqueueMessage(QueuedMessage(
      senderKey: Uint8List(32),
      isChannel: true,
      channelIdx: channelIdx ?? 0,
      pathLen: packet.isRouteFlood ? packet.pathLenByte : 0xFF,
      snr: packet.snr,
      rssi: packet.rssi,
      channelDataType: dataType,
      channelDataPayload: Uint8List.fromList(plaintext.sublist(3, 3 + dataLen)),
    ));
  }

  void _onControlData(Packet packet) {
    if (packet.payload.isEmpty) return;
    if (_isDuplicate(packet.calculatePacketHash())) return;
    pushSink?.pushControlData(
      packet.snr,
      packet.rssi,
      packet.pathLenByte,
      packet.payload,
    );
  }

  /// Handle a returned trace packet (`PAYLOAD_TYPE_TRACE`, route direct). The
  /// payload is `tag(4) + auth(4) + flags(1) + requested path hashes`; the
  /// routing path holds one accumulated SNR byte per hop. The proxy does not
  /// forward traces, so it only reports the result once the requested path has
  /// been fully consumed (the trace has returned to us).
  void _onTrace(Packet packet) {
    if (!packet.isRouteDirect) return;
    final payload = packet.payload;
    if (payload.length < 9) return;
    final r = BufferReader(payload);
    final tag = r.readUInt32Le();
    final authCode = r.readUInt32Le();
    final flags = r.readByte();
    final pathSz = flags & 0x03;
    final pathHashes = Uint8List.fromList(payload.sublist(9));
    final pathLen = pathHashes.length;

    final hopCount = packet.path.length;
    if ((hopCount << pathSz) < pathLen) return; // not the terminus

    final snrCount = pathLen >> pathSz;
    final pathSnrs = Uint8List.fromList(
      packet.path.sublist(0, snrCount.clamp(0, packet.path.length)),
    );
    final finalSnrByte = (packet.snr * 4).round().clamp(-128, 127) & 0xFF;
    pushSink?.pushTraceData(
      pathLen,
      flags,
      tag,
      authCode,
      pathHashes,
      pathSnrs,
      finalSnrByte,
    );
  }

  void _onAck(Packet packet) {
    if (packet.payload.length < 4) return;
    final crc = packet.payload[0] |
        (packet.payload[1] << 8) |
        (packet.payload[2] << 16) |
        (packet.payload[3] << 24);
    // Keep-alive ACKs are matched separately and not surfaced to the client.
    for (final conn in _connections.values) {
      if (conn.expectedAck != null && conn.expectedAck == (crc & 0xFFFFFFFF)) {
        conn.expectedAck = null;
        conn.lastActivity = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        return;
      }
    }
    _confirmAck(crc);
  }

  /// Handle a `PAYLOAD_TYPE_MULTIPART` packet. Only multipart ACKs are used by
  /// the firmware: the first byte is `remaining << 4 | PAYLOAD_TYPE_ACK` and the
  /// rest is the 4-byte ACK hash of an ordinary ACK.
  void _onMultipart(Packet packet) {
    if (packet.payload.length < 5) return;
    final innerType = packet.payload[0] & 0x0F;
    if (innerType != payloadTypeAck) return;
    final ackPacket = Packet()
      ..header = packet.header
      ..pathLenByte = packet.pathLenByte
      ..path = packet.path
      ..payload = Uint8List.fromList(packet.payload.sublist(1));
    _onAck(ackPacket);
  }

  void _confirmAck(int crc) {
    final idx = _pendingAcks.indexWhere((a) => a.crc == (crc & 0xFFFFFFFF));
    if (idx < 0) return;
    _pendingAcks.removeAt(idx).timer.cancel();
    pushSink?.pushSendConfirmed(crc & 0xFFFFFFFF);
  }

  /// Handle a returned-path packet (payload type `0x08`). The encrypted inner
  /// payload is `path_len | path | extra_type | extra`. When the extra is an
  /// ACK hash we confirm the pending send; the path is the route back to the
  /// sender, so we cache it for future direct sends.
  Future<void> _onPathReturn(Packet packet) async {
    final payload = packet.payload;
    if (payload.length < 2) return;
    if (payload[0] != _selfHash) return; // not addressed to us
    final srcHash = payload[1];
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
        payload.sublist(2),
      );
    } catch (_) {
      return;
    }
    if (plaintext.isEmpty) return;
    final pathLenEncoded = plaintext[0];
    final pathByteLen = PathUtils.getByteLength(pathLenEncoded);
    final extraStart = 1 + pathByteLen;
    if (plaintext.length <= extraStart) return;
    final extraType = plaintext[extraStart];
    final extra = plaintext.sublist(extraStart + 1);

    if (pathByteLen > 0 && PathUtils.isValidPathLen(pathLenEncoded)) {
      sender.outPath = Uint8List.fromList(plaintext.sublist(1, extraStart));
      sender.outPathLen = pathLenEncoded;
      sender.lastmod = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      addUpdateContact(sender);
      pushSink?.pushPathUpdated(sender.publicKey);
    }

    if (extraType == payloadTypeAck && extra.length >= 4) {
      final crc =
          extra[0] | (extra[1] << 8) | (extra[2] << 16) | (extra[3] << 24);
      _confirmAck(crc);
    } else if (extraType == payloadTypeResponse) {
      _dispatchResponse(
        sender.publicKey,
        extra,
        outPath: Uint8List.fromList(plaintext.sublist(1, extraStart)),
        outPathLen: pathLenEncoded,
        inPath: packet.path,
        inPathLen: packet.pathLenByte,
      );
    }
  }

  /// Handle a `PAYLOAD_TYPE_RESPONSE` datagram (a response to a request sent as
  /// a direct datagram rather than a returned-path packet).
  Future<void> _onResponse(Packet packet) async {
    final payload = packet.payload;
    if (payload.length < 2) return;
    if (payload[0] != _selfHash) return;
    final srcHash = payload[1];
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
        payload.sublist(2),
      );
    } catch (_) {
      return;
    }
    _dispatchResponse(sender.publicKey, plaintext);
  }

  /// Route a request response (login/status/path-discovery) to the matching
  /// pending request. Returned-path responses also carry the learned paths.
  void _dispatchResponse(
    Uint8List senderPubkey,
    Uint8List data, {
    Uint8List? outPath,
    int? outPathLen,
    Uint8List? inPath,
    int? inPathLen,
  }) {
    if (data.length < 4) return;
    final tag = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
    final prefix4 = Uint8List.fromList(senderPubkey.sublist(0, 4));
    _markConnectionActive(senderPubkey);

    if (outPath != null &&
        outPathLen != null &&
        inPath != null &&
        inPathLen != null &&
        _pendingDiscovery.remove(tag) != null) {
      pushSink?.pushPathDiscoveryResponse(
        Uint8List.fromList(senderPubkey.sublist(0, 6)),
        outPathLen,
        outPath,
        inPathLen,
        inPath,
      );
      return;
    }

    if (_pendingTelemetry.remove(tag) != null && data.length > 4) {
      pushSink?.pushTelemetryResponse(
        Uint8List.fromList(senderPubkey.sublist(0, 6)),
        Uint8List.fromList(data.sublist(4)),
      );
      return;
    }

    if (_pendingBinary.remove(tag) != null) {
      pushSink?.pushBinaryResponse(
        tag,
        Uint8List.fromList(data.length > 4 ? data.sublist(4) : const []),
      );
      return;
    }

    if (_pendingLogin != null && _bytesEqual(_pendingLogin!, prefix4)) {
      _pendingLogin = null;
      _handleLoginResponse(senderPubkey, data);
      return;
    }

    if (_pendingStatus != null && _bytesEqual(_pendingStatus!, prefix4)) {
      _pendingStatus = null;
      if (data.length > 4) {
        pushSink?.pushStatusResponse(
          Uint8List.fromList(senderPubkey.sublist(0, 6)),
          Uint8List.fromList(data.sublist(4)),
        );
      }
    }
  }

  void _handleLoginResponse(Uint8List senderPubkey, Uint8List data) {
    final prefix6 = Uint8List.fromList(senderPubkey.sublist(0, 6));
    // Legacy repeater login replies with the literal "OK".
    if (data.length >= 6 && data[4] == 0x4F && data[5] == 0x4B) {
      pushSink?.pushLoginSuccess(prefix6, legacy: true);
      return;
    }
    if (data.length > 4 && data[4] == respServerLoginOk) {
      final tag =
          data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
      final keepAliveSecs = data.length > 5 ? data[5] * 16 : 0;
      if (keepAliveSecs > 0) _startKeepAlive(senderPubkey, keepAliveSecs);
      pushSink?.pushLoginSuccess(
        prefix6,
        permissions: data.length > 6 ? data[6] : 0,
        serverTag: tag,
        acl: data.length > 7 ? data[7] : 0,
        firmwareVer: data.length > 12 ? data[12] : 0,
      );
      return;
    }
    pushSink?.pushLoginFail(prefix6);
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
