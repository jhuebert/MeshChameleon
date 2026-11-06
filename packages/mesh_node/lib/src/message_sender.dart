import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'ack_tracker.dart';
import 'contact_table.dart';
import 'packet_deduper.dart';
import 'packet_transport.dart';
import 'request_tracker.dart';
import 'runtime_guard.dart';
import 'virtual_clock.dart';

/// Shared state for outbound companion operations.
class MessageSenderDeps {
  const MessageSenderDeps({
    required this.identity,
    required this.prefs,
    required this.clock,
    required this.channels,
    required this.contacts,
    required this.requests,
    required this.acks,
    required this.transport,
    required this.deduper,
    required this.ackTimeout,
    required this.guard,
    required this.ensureNotBlockedPeer,
    required this.transmit,
  });

  final LocalIdentity Function() identity;
  final NodePrefs prefs;
  final VirtualClock clock;
  final Map<int, Channel> channels;
  final ContactTable contacts;
  final RequestTracker requests;
  final AckTracker acks;
  final PacketTransport transport;
  final PacketDeduper deduper;
  final Duration ackTimeout;
  final RuntimeGuard guard;

  bool isBlocked() => guard.blocked;

  int identityGeneration() => guard.generation;

  bool isCurrent(int generation) => guard.isCurrent(generation);

  final void Function(Uint8List pubkey) ensureNotBlockedPeer;
  final Future<void> Function(
    Packet packet, {
    required bool flood,
    bool scoped,
    bool preservePath,
    int priority,
    int? identityGeneration,
  }) transmit;
}

/// Outbound text, channel, raw, and request transmissions.
///
/// Packet construction and validation live here; the node keeps the durable
/// queue, contact lookup policy, and identity lifecycle.
class MessageSender {
  MessageSender(this.deps);

  final MessageSenderDeps deps;

  LocalIdentity get identity => deps.identity();
  NodePrefs get prefs => deps.prefs;
  VirtualClock get clock => deps.clock;
  Map<int, Channel> get channels => deps.channels;
  ContactTable get contacts => deps.contacts;
  RequestTracker get requests => deps.requests;
  AckTracker get acks => deps.acks;
  PacketTransport get transport => deps.transport;
  PacketDeduper get deduper => deps.deduper;

  Future<SentResult> sendTextMessage(
    Uint8List pubkey,
    String text, {
    int txtType = txtTypePlain,
    int attempt = 0,
    int? timestamp,
  }) async {
    if (deps.isBlocked()) return const SentResult.failure();
    deps.ensureNotBlockedPeer(pubkey);
    final generation = deps.identityGeneration();
    final contact = contacts.findByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final textLength = utf8.encode(text).length;
    if (textLength > maxTextLength ||
        (attempt > 3 && textLength > maxTextLength - 2)) {
      return const SentResult.failure();
    }
    final isCli = txtType == txtTypeCliData || txtType == txtTypeCliCommand;
    // Stock firmware uses the app-supplied timestamp for normal messages so the
    // client's precomputed ACK hash matches. CLI sends use the node RTC.
    final messageTimestamp = isCli
        ? requests.nextTimestamp()
        : (timestamp ?? requests.nextTimestamp());
    requests.noteTimestamp(messageTimestamp);
    final (packet, ackCrc) = await PacketBuilder.createTextMessage(
      contact: contact,
      identity: identity,
      message: text,
      attempt: attempt,
      txtType: txtType,
      timestamp: messageTimestamp,
    );
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    final flood = !contact.hasDirectRoute;
    final timeoutMs =
        transport.sendTimeoutMillisFor(packet, flood: flood, scoped: true) ??
            deps.ackTimeout.inMilliseconds;
    // CLI data/commands are not acknowledged; don't track a pending ACK.
    final isCommand = isCli;
    PendingAck? pending;
    if (!isCommand) {
      // Register before transmit: a synchronous local mirror can deliver the
      // ACK before the RF round-trip completes.
      pending = acks.register(
        ackCrc,
        contact.publicKey,
        Duration(milliseconds: timeoutMs),
      );
    }
    try {
      await deps.transmit(
        packet,
        flood: flood,
        scoped: true,
        identityGeneration: generation,
      );
    } on CompanionOperationError catch (e) {
      if (pending != null) acks.cancel(pending);
      if (e.code == errCodeTableFull) return const SentResult.failure();
      rethrow;
    } catch (_) {
      if (pending != null) acks.cancel(pending);
      rethrow;
    }
    if (!deps.isCurrent(generation)) {
      if (pending != null) acks.cancel(pending);
      return const SentResult.failure();
    }
    if (isCommand) {
      return SentResult(
        success: true,
        isFlood: flood,
        expectedAck: 0,
        timeoutMs: timeoutMs,
      );
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: ackCrc,
      timeoutMs: timeoutMs,
    );
  }

  Future<bool> sendChannelMessage(
    int channelIndex,
    String text, {
    int? timestamp,
  }) async {
    if (deps.isBlocked()) return false;
    final generation = deps.identityGeneration();
    final channel = channels[channelIndex];
    if (channel == null) return false;
    final packet = PacketBuilder.createGroupText(
      channel: channel,
      message: text,
      senderName: prefs.nodeName,
      timestamp: timestamp ?? requests.nextTimestamp(),
      maxContentLength: maxGroupTextContentOverCompanion,
    );
    deduper.noteSentGroup(packet.calculatePacketHash());
    await deps.transmit(
      packet,
      flood: true,
      scoped: true,
      identityGeneration: generation,
    );
    return deps.isCurrent(generation);
  }

  Future<bool> sendChannelData(
    int channelIndex,
    int dataType,
    Uint8List payload, {
    List<int>? path,
    int? pathLenEncoded,
  }) async {
    if (deps.isBlocked()) return false;
    final generation = deps.identityGeneration();
    final channel = channels[channelIndex];
    if (channel == null) return false;
    final pathLen = pathLenEncoded ?? 0xFF;
    final pathBytes = path ?? const <int>[];
    final flood = pathLen == 0xFF;
    if (flood) {
      if (pathBytes.isNotEmpty) return false;
    } else {
      if (!PathUtils.isValidPathLen(pathLen)) return false;
      if (pathBytes.length != PathUtils.getByteLength(pathLen)) return false;
    }
    if (dataType == dataTypeReserved) return false;
    if (payload.length > maxGroupDataLength) return false;
    if (payload.length > maxGroupDataLengthForCompanionPath(pathBytes.length)) {
      return false;
    }
    // The whole SEND_CHANNEL_DATA payload must fit the companion frame, in
    // addition to the 165-byte radio-side group-data limit.
    final commandLength = 5 + (flood ? 0 : pathBytes.length) + payload.length;
    if (commandLength > maxCompanionPayloadSize) return false;
    final packet = PacketBuilder.createGroupData(
      channel: channel,
      dataType: dataType,
      data: payload,
      path: pathBytes,
      pathLenEncoded: pathLen,
    );
    await deps.transmit(
      packet,
      flood: flood,
      scoped: true,
      identityGeneration: generation,
    );
    return deps.isCurrent(generation);
  }

  Future<bool> sendControlData(Uint8List data) async {
    if (deps.isBlocked()) return false;
    await deps.transmit(
      PacketBuilder.createControlData(data),
      flood: false,
      identityGeneration: deps.identityGeneration(),
    );
    return !deps.isBlocked();
  }

  int _requestTimeout(Packet packet, bool flood, {required int fallback}) =>
      deps.transport.sendTimeoutMillisFor(packet, flood: flood, scoped: true) ??
      fallback;

  Future<SentResult> sendBinaryReq(Uint8List pubkey, Uint8List data) async {
    if (deps.isBlocked()) return const SentResult.failure();
    deps.ensureNotBlockedPeer(pubkey);
    final generation = deps.identityGeneration();
    final contact = contacts.findByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = requests.nextTag();
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: data.isEmpty ? 0 : data[0],
      data: data.length > 1 ? data.sublist(1) : const [],
      timestamp: tag,
    );
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    final flood = !contact.hasDirectRoute;
    requests.registerBinary(tag, pubkey);
    try {
      await deps.transmit(
        packet,
        flood: flood,
        scoped: true,
        identityGeneration: generation,
      );
    } catch (_) {
      requests.removeBinary(tag);
      rethrow;
    }
    if (!deps.isCurrent(generation)) {
      requests.removeBinary(tag);
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: _requestTimeout(packet, flood, fallback: 10000),
    );
  }

  Future<SentResult> sendAnonReq(Uint8List pubkey, Uint8List data) async {
    if (deps.isBlocked()) return const SentResult.failure();
    deps.ensureNotBlockedPeer(pubkey);
    final generation = deps.identityGeneration();
    // Like the firmware, ensure a contact exists (a zero-hop one if unknown) so
    // the response can be decrypted and matched.
    var contact = contacts.findByKey(pubkey);
    contact ??= contacts.ensureAnon(pubkey);
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    final tag = requests.nextTag();
    final flood = !contact.hasDirectRoute;
    final packet = await PacketBuilder.createAnonRequest(
      contact: contact,
      identity: identity,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    requests.registerBinary(tag, pubkey);
    try {
      await deps.transmit(
        packet,
        flood: flood,
        scoped: true,
        identityGeneration: generation,
      );
    } catch (_) {
      requests.removeBinary(tag);
      rethrow;
    }
    if (!deps.isCurrent(generation)) {
      requests.removeBinary(tag);
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: _requestTimeout(packet, flood, fallback: 10000),
    );
  }

  /// Register a transient zero-hop contact for [pubkey] if one doesn't exist.
  ///
  /// The eight anonymous slots are separate from the persistent contact table:
  /// they never consume its capacity, appear in listings/info, or get persisted.
  Future<SentResult> sendPathDiscoveryReq(Uint8List pubkey) async {
    if (deps.isBlocked()) return const SentResult.failure();
    deps.ensureNotBlockedPeer(pubkey);
    final generation = deps.identityGeneration();
    final contact = contacts.findByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = requests.nextTag();
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
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    requests.registerDiscovery(tag, pubkey);
    try {
      await deps.transmit(
        packet,
        flood: true,
        scoped: true,
        identityGeneration: generation,
      );
    } catch (_) {
      requests.removeDiscovery(tag);
      rethrow;
    }
    if (!deps.isCurrent(generation)) {
      requests.removeDiscovery(tag);
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: true,
      expectedAck: tag,
      timeoutMs: _requestTimeout(packet, true, fallback: 15000),
    );
  }

  Future<SentResult> sendTelemetryRequest(
    Uint8List pubkey, {
    bool wantBase = true,
    bool wantLocation = true,
    bool wantEnvironment = true,
  }) async {
    if (deps.isBlocked()) return const SentResult.failure();
    deps.ensureNotBlockedPeer(pubkey);
    final generation = deps.identityGeneration();
    final contact = contacts.findByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = requests.nextTag();
    // The first payload byte is an inverse permissions mask: set the bits for
    // the telemetry classes we do *not* want.
    var inverse = 0;
    if (!wantBase) inverse |= telemPermBase;
    if (!wantLocation) inverse |= telemPermLocation;
    if (!wantEnvironment) inverse |= telemPermEnvironment;
    final flood = !contact.hasDirectRoute;
    final rng = Random.secure();
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetTelemetryData,
      data: [
        inverse & 0xFF,
        0,
        0,
        0,
        ...List<int>.generate(4, (_) => rng.nextInt(256)),
      ],
      timestamp: tag,
      flood: flood,
    );
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    requests.registerTelemetry(tag, pubkey);
    try {
      await deps.transmit(
        packet,
        flood: flood,
        scoped: true,
        identityGeneration: generation,
      );
    } catch (_) {
      requests.removeTelemetry(tag);
      rethrow;
    }
    if (!deps.isCurrent(generation)) {
      requests.removeTelemetry(tag);
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: _requestTimeout(packet, flood, fallback: 10000),
    );
  }

  Future<SentResult> sendTracePathRaw(
    int tag,
    int authCode,
    int flags,
    Uint8List pathBytes,
  ) async {
    if (deps.isBlocked()) return const SentResult.failure();
    final generation = deps.identityGeneration();
    final packet = PacketBuilder.createTrace(
      tag: tag,
      authCode: authCode,
      flags: flags,
      path: pathBytes,
    );
    await deps.transmit(packet, flood: false, identityGeneration: generation);
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    final pathSz = flags & 0x03;
    final hashCount = pathBytes.length >> pathSz;
    final airtimeMs = deps.transport.airtimeMicrosFor(packet.rawLength) ~/ 1000;
    return SentResult(
      success: true,
      isFlood: false,
      expectedAck: tag,
      timeoutMs: 500 + ((airtimeMs * 6 + 250) * (hashCount + 1)),
    );
  }

  Future<bool> sendRawData(
    Uint8List payload,
    Uint8List path,
    int pathLenByte,
  ) async {
    if (deps.isBlocked()) return false;
    final generation = deps.identityGeneration();
    final packet = PacketBuilder.createRawCustom(
      payload,
      path: path,
      encodedPathLen: pathLenByte,
    );
    await deps.transmit(packet, flood: false, identityGeneration: generation);
    return deps.isCurrent(generation);
  }

  Future<bool> sendRawPacket(Packet packet, int priority) async {
    if (deps.isBlocked()) return false;
    final generation = deps.identityGeneration();
    // Transmitted verbatim; route type and path come from the packet itself.
    // Unlike semantic sends, stock does not mark raw client packets as seen
    // (`CMD_SEND_RAW_PACKET` calls `Dispatcher::sendPacket` directly), so skip
    // the node-level dedup marking and let a repeater echo be processed.
    await deps.transport.transmit(
      packet,
      flood: packet.isRouteFlood,
      preservePath: true,
      priority: priority,
      identityGeneration: generation,
    );
    return deps.isCurrent(generation);
  }

  Future<SentResult> sendLogin(Uint8List pubkey, String password) async {
    if (deps.isBlocked()) return const SentResult.failure();
    deps.ensureNotBlockedPeer(pubkey);
    final generation = deps.identityGeneration();
    final contact = contacts.findByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = requests.nextTag();
    final pw = utf8.encode(password);
    final pwTrimmed = pw.length > 15 ? pw.sublist(0, 15) : pw;
    // Room servers take a sync cursor before the password.
    final List<int> data = contact.advType == advTypeRoom
        ? [
            ...(BufferWriter()..writeUInt32Le(contact.syncSince)).toBytes(),
            ...pwTrimmed,
          ]
        : pwTrimmed;
    final flood = !contact.hasDirectRoute;
    final packet = await PacketBuilder.createAnonRequest(
      contact: contact,
      identity: identity,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    requests.setPendingLogin(Uint8List.fromList(pubkey.sublist(0, keyPrefix4)));
    try {
      await deps.transmit(
        packet,
        flood: flood,
        scoped: true,
        identityGeneration: generation,
      );
    } catch (_) {
      requests.clearPendingLogin();
      rethrow;
    }
    if (!deps.isCurrent(generation)) {
      requests.clearPendingLogin();
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: _requestTimeout(packet, flood, fallback: 15000),
    );
  }

  Future<SentResult> sendStatusReq(Uint8List pubkey) async {
    if (deps.isBlocked()) return const SentResult.failure();
    deps.ensureNotBlockedPeer(pubkey);
    final generation = deps.identityGeneration();
    final contact = contacts.findByKey(pubkey);
    if (contact == null) return const SentResult.failure();
    final tag = requests.nextTag();
    final rng = Random.secure();
    final data = Uint8List.fromList([
      0,
      0,
      0,
      0,
      ...List<int>.generate(4, (_) => rng.nextInt(256)),
    ]);
    final flood = !contact.hasDirectRoute;
    final packet = await PacketBuilder.createProtocolRequest(
      contact: contact,
      identity: identity,
      protocolCode: reqTypeGetStatus,
      data: data,
      timestamp: tag,
      flood: flood,
    );
    if (!deps.isCurrent(generation)) return const SentResult.failure();
    requests
        .setPendingStatus(Uint8List.fromList(pubkey.sublist(0, keyPrefix4)));
    try {
      await deps.transmit(
        packet,
        flood: flood,
        scoped: true,
        identityGeneration: generation,
      );
    } catch (_) {
      requests.clearPendingStatus();
      rethrow;
    }
    if (!deps.isCurrent(generation)) {
      requests.clearPendingStatus();
      return const SentResult.failure();
    }
    return SentResult(
      success: true,
      isFlood: flood,
      expectedAck: tag,
      timeoutMs: _requestTimeout(packet, flood, fallback: 15000),
    );
  }
}
