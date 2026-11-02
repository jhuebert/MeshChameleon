import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'ack_tracker.dart';
import 'advert_path_cache.dart';
import 'battery_service.dart';
import 'cli.dart';
import 'cli_runtime.dart';
import 'connection_sessions.dart';
import 'contact_table.dart';
import 'message_queue.dart';
import 'node_store.dart';
import 'packet_deduper.dart';
import 'packet_transport.dart';
import 'request_tracker.dart';
import 'virtual_clock.dart';

/// Outcome of an advert commit, captured inside the persistence queue.
enum _AdvertOutcome { none, updated, discovered, tableFull, stored }

/// Shared node state consumed by the packet router.
class MeshRxDeps {
  const MeshRxDeps({
    required this.identity,
    required this.prefs,
    required this.clock,
    required this.channels,
    required this.contacts,
    required this.advertPaths,
    required this.queue,
    required this.requests,
    required this.deduper,
    required this.acks,
    required this.sessions,
    required this.transport,
    required this.battery,
    required this.cli,
    required this.pushSink,
    required this.isCurrent,
    required this.isBlocked,
    required this.identityGeneration,
    required this.commit,
    required this.transmit,
    required this.enqueueMessage,
    required this.addUpdateContact,
    required this.forgetContactState,
    required this.persist,
  });

  final LocalIdentity Function() identity;
  final NodePrefs prefs;
  final VirtualClock clock;
  final Map<int, Channel> channels;
  final ContactTable contacts;
  final AdvertPathCache advertPaths;
  final MessageQueue queue;
  final RequestTracker requests;
  final PacketDeduper deduper;
  final AckTracker acks;
  final ConnectionSessions sessions;
  final PacketTransport transport;
  final BatteryService battery;
  final CliRuntime cli;
  final CompanionPushSink? Function() pushSink;
  final bool Function(int generation) isCurrent;
  final bool Function() isBlocked;
  final int Function() identityGeneration;
  final Future<void> Function(
    NodeState? Function(NodeState current) mutate, {
    int? identityGeneration,
  }) commit;
  final Future<void> Function(
    Packet packet, {
    required bool flood,
    bool scoped,
    bool preservePath,
    int priority,
    int? identityGeneration,
  }) transmit;
  final Future<void> Function(
    QueuedMessage message, {
    int? identityGeneration,
  }) enqueueMessage;
  final Future<void> Function(
    Contact contact, {
    bool hasGps,
    int? identityGeneration,
  }) addUpdateContact;
  final void Function(Uint8List pubkey) forgetContactState;
  final void Function() persist;
}

/// Inbound packet router and handlers.
///
/// The router owns only protocol dispatch: durable state lives in the contact,
/// advert-path, queue, request, ACK, and connection collaborators passed in
/// [deps].
class MeshRx {
  MeshRx(this.deps);

  final MeshRxDeps deps;

  LocalIdentity get identity => deps.identity();
  NodePrefs get prefs => deps.prefs;
  VirtualClock get clock => deps.clock;
  Map<int, Channel> get channels => deps.channels;
  ContactTable get contacts => deps.contacts;
  List<Contact> get contactList => deps.contacts.contacts;
  AdvertPathCache get advertPaths => deps.advertPaths;
  MessageQueue get queue => deps.queue;
  RequestTracker get requests => deps.requests;
  PacketDeduper get deduper => deps.deduper;
  AckTracker get acks => deps.acks;
  ConnectionSessions get sessions => deps.sessions;
  PacketTransport get transport => deps.transport;
  BatteryService get battery => deps.battery;
  CliRuntime get cli => deps.cli;
  CompanionPushSink? get pushSink => deps.pushSink();

  /// Admit an advert packet (also used by `CMD_IMPORT_CONTACT`).
  Future<void> handleAdvert(Packet packet, int generation) =>
      _onAdvert(packet, generation);

  /// Process a raw over-air frame.
  Future<void> handleRawFrame(
    double snr,
    int rssi,
    Uint8List raw, {
    bool peerOrigin = false,
  }) async {
    if (deps.isBlocked()) return;
    final generation = deps.identityGeneration();
    if (!peerOrigin) {
      pushSink?.pushRawRxData(snr, rssi, raw);
      transport.addRxAirtime(raw.length);
    }
    final packet = Packet.readFrom(raw);
    if (packet == null) {
      transport.recordMalformedFrame();
      return;
    }
    packet.snr = snr;
    packet.rssi = rssi;
    transport.recordFrame(packet);

    // Trace routes carry accumulated SNR bytes in the path field, not remaining
    // route hashes. The trace handler validates that the requested path is
    // complete before surfacing it.
    if (packet.payloadType == payloadTypeTrace) {
      _onTrace(packet);
      return;
    }

    // Control discovery raw packets preserve this path for diagnostics, but
    // semantic delivery at this endpoint requires a fully consumed direct route.
    // A local mirror copy is already at its final destination even when the
    // original packet still carries a direct path.
    final endpointConsumed =
        peerOrigin || packet.isRouteFlood || packet.pathHashCount == 0;
    if (!endpointConsumed) {
      // Stock endpoints can still observe early ACKs before the route is
      // consumed; everything else remains raw-logged only.
      switch (packet.payloadType) {
        case payloadTypeAck:
          _onAck(packet);
        case payloadTypeMultipart:
          _onMultipart(packet);
        default:
          break;
      }
      return;
    }

    switch (packet.payloadType) {
      case payloadTypeReq:
        await _onRequest(packet, generation);
      case payloadTypeRawCustom:
        _onRawCustom(packet, peerOrigin: peerOrigin);
      case payloadTypeAdvert:
        await _onAdvert(packet, generation);
      case payloadTypeTxtMsg:
        await _onDirectText(packet, generation);
      case payloadTypeGrpTxt:
        await _onGroupText(packet, generation, peerOrigin: peerOrigin);
      case payloadTypeGrpData:
        await _onGroupData(packet, generation);
      case payloadTypeControl:
        _onControlData(packet);
      case payloadTypeTrace:
        _onTrace(packet);
      case payloadTypeAck:
        _onAck(packet);
      case payloadTypeMultipart:
        _onMultipart(packet);
      case payloadTypePath:
        await _onPathReturn(packet, generation);
      case payloadTypeResponse:
        await _onResponse(packet, generation);
      default:
        break;
    }
  }

  Future<void> _onAdvert(Packet packet, int generation) async {
    final advert = PacketBuilder.decodeAdvertPacket(packet.payload);
    if (advert == null || advert.appData.isEmpty) return;
    if (!await advert.verify()) return;
    if (!deps.isCurrent(generation)) return;
    final pubkey = Uint8List.fromList(advert.publicKey);
    if (bytesEqual(pubkey, identity.publicKey)) return;
    final ts = advert.timestamp;
    final appdata = advert.appData;
    final decoded = PacketBuilder.decodeAdvertData(appdata);
    if (!decoded.valid || !decoded.hasName) return;
    final name = validateAdvertName(decoded.name);
    if (name == null) return;
    final now = clock.wallSeconds;
    final type = decoded.flags & 0x0F;

    // A matching anonymous slot is cleared before the normal new/update flow.
    final transientIdx = contacts.transient
        .indexWhere((c) => c.publicKeyHex == bytesToHex(pubkey));
    if (transientIdx >= 0) {
      if (ts <= contacts.transient[transientIdx].lastAdvertTimestamp) return;
      contacts.transient.removeAt(transientIdx);
    }

    final newContact = Contact(
      publicKey: pubkey,
      name: name,
      advType: type,
      flags: 0,
      outPathLen: -1,
      lastAdvertTimestamp: ts,
      lastmod: now,
      gpsLat: decoded.hasLocation ? decoded.lat : 0.0,
      gpsLon: decoded.hasLocation ? decoded.lon : 0.0,
      rawAdvert: _normalizedAdvertBlob(packet),
    );

    _AdvertOutcome outcome = _AdvertOutcome.none;
    Contact? evicted;
    try {
      await deps.commit((current) {
        final pathCache = advertPaths.candidate(
          packet,
          pubkey,
          name,
          now,
          base: current.advertPaths,
        );
        final existingIdx = current.contacts
            .indexWhere((c) => c.publicKeyHex == bytesToHex(pubkey));
        if (existingIdx >= 0) {
          final existing = current.contacts[existingIdx];
          if (ts <= existing.lastAdvertTimestamp) {
            outcome = _AdvertOutcome.none;
            return null;
          }
          final updated = existing.clone()
            ..name = name
            ..advType = type
            ..lastAdvertTimestamp = ts
            ..lastmod = now
            ..rawAdvert = _normalizedAdvertBlob(packet);
          if (decoded.hasLocation) {
            updated
              ..gpsLat = decoded.lat
              ..gpsLon = decoded.lon;
          }
          final candidateContacts = [
            for (final c in current.contacts) c.clone(),
          ];
          candidateContacts[existingIdx] = updated;
          outcome = _AdvertOutcome.updated;
          return current.copyWith(
            contacts: candidateContacts,
            advertPaths: pathCache,
          );
        }

        if (!contacts.shouldAutoAddType(type, current.prefs) ||
            !contacts.hopAllowed(packet.pathHashCount, current.prefs)) {
          // Discovery only: no persistent contact, but remember the path.
          outcome = _AdvertOutcome.discovered;
          return current.copyWith(advertPaths: pathCache);
        }

        final candidateContacts = [
          for (final c in current.contacts) c.clone(),
        ];
        if (candidateContacts.length >= virtualMaxContacts) {
          final overwrite = contacts.oldestOverwritableIndex(
              candidateContacts, current.prefs);
          if (overwrite < 0) {
            outcome = _AdvertOutcome.tableFull;
            return current.copyWith(advertPaths: pathCache);
          }
          evicted = candidateContacts[overwrite].clone();
          candidateContacts[overwrite] = newContact.clone();
        } else {
          candidateContacts.add(newContact.clone());
        }
        outcome = _AdvertOutcome.stored;
        return current.copyWith(
          contacts: candidateContacts,
          advertPaths: pathCache,
        );
      }, identityGeneration: generation);
    } on CompanionOperationError catch (e) {
      if (!deps.isCurrent(generation)) return;
      switch (outcome) {
        case _AdvertOutcome.discovered:
          // Path caching is best-effort; discovery still notifies the client.
          pushSink?.pushNewAdvert(newContact.toCompanionFrameBody());
        case _AdvertOutcome.tableFull:
          pushSink?.pushNewAdvert(newContact.toCompanionFrameBody());
          pushSink?.pushContactsFull();
        case _AdvertOutcome.stored:
          if (e.code == errCodeTableFull) {
            // Virtual quota is a full-table condition for auto-add discovery.
            pushSink?.pushNewAdvert(newContact.toCompanionFrameBody());
            pushSink?.pushContactsFull();
          }
        case _AdvertOutcome.none:
        case _AdvertOutcome.updated:
          break;
      }
      return;
    }
    if (!deps.isCurrent(generation)) return;
    switch (outcome) {
      case _AdvertOutcome.none:
        return;
      case _AdvertOutcome.updated:
        pushSink?.pushAdvert(pubkey);
      case _AdvertOutcome.discovered:
        pushSink?.pushNewAdvert(newContact.toCompanionFrameBody());
      case _AdvertOutcome.tableFull:
        pushSink?.pushNewAdvert(newContact.toCompanionFrameBody());
        pushSink?.pushContactsFull();
      case _AdvertOutcome.stored:
        final evictedContact = evicted;
        if (evictedContact != null) {
          deps.forgetContactState(evictedContact.publicKey);
          pushSink?.pushContactDeleted(evictedContact.publicKey);
        }
        // Pinned BaseChatMesh behavior: a stored new candidate pushes ADVERT
        // (0x80), while NEW_ADVERT (0x8A) is reserved for discovered-only ones.
        pushSink?.pushAdvert(pubkey);
    }
  }

  Future<void> _onDirectText(Packet packet, int generation) async {
    if (packet.payload.length < 2) return;
    if (packet.payload[0] != identity.publicKey[0]) {
      return; // not addressed to us
    }
    final srcHash = packet.payload[1];
    final decrypted = await _decryptFromSource(
      srcHash,
      packet.payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
    if (plaintext.length < 5) return;
    final r = BufferReader(plaintext);
    final ts = r.readUInt32Le();
    final flagsByte = r.readByte();
    final txtType = (flagsByte >> 2) & 0x3F;

    // Signed messages carry a 4-byte sender prefix before the text.
    late String text;
    Uint8List? rawCommand;
    late Uint8List ackBytes;
    if (txtType == txtTypeSigned) {
      if (plaintext.length < 9) return;
      r.skipBytes(4); // sender prefix (informational)
      text = r.readCString();
      // Track the room-server sync cursor (highest signed timestamp seen).
      if (ts > sender.syncSince) {
        sender.syncSince = ts;
        deps.persist();
      }
      final textLen = utf8.encode(text).length;
      final end = (9 + textLen).clamp(0, plaintext.length);
      // The firmware ACKs signed messages with
      // sha256(plaintext up to the text end | self pubkey).
      ackBytes = Uint8List.fromList(CryptoUtils.sha256(
              [...plaintext.sublist(0, end), ...identity.publicKey])
          .sublist(0, keyPrefix4));
    } else {
      if (txtType == txtTypeCliCommand) {
        rawCommand = _readCStringBytes(plaintext, r.position);
      }
      text = r.readCString();
      final textBytes = utf8.encode(text);
      final hash = PacketBuilder.ackHash(
        timestamp: ts,
        flagsByte: flagsByte,
        text: textBytes,
        senderPubkey: sender.publicKey,
      );
      // Plain ACKs append the extended-attempt byte (the byte after the text's
      // NUL) and one random byte; do not truncate them back to four bytes.
      final extendedIndex = 5 + textBytes.length + 1;
      final extendedAttempt =
          extendedIndex < plaintext.length ? plaintext[extendedIndex] : 0;
      ackBytes = Uint8List.fromList([
        ...hash,
        extendedAttempt,
        Random.secure().nextInt(256),
      ]);
    }

    // Only plain and signed messages are acknowledged; CLI data/commands are
    // not. ACKs are scheduled as endpoint transmissions (never forwarded).
    if (!deps.isCurrent(generation)) return;
    final expectsAck = txtType == txtTypePlain || txtType == txtTypeSigned;
    if (expectsAck) {
      _scheduleTextAck(packet, sender,
          await identity.sharedSecret(sender.publicKey), ackBytes);
    }

    // Deduplicate before any remote CLI side effect. Duplicate reception of
    // plain/signed messages is still ACKed above but not queued twice.
    if (deduper.isDuplicate(packet.calculatePacketHash())) return;

    if (txtType == txtTypeCliCommand) {
      if (contacts.isPersistent(sender) && (sender.flags & 0x10) != 0) {
        await _handleRemoteCli(
          sender,
          ts,
          rawCommand ?? Uint8List.fromList(utf8.encode(text)),
          generation,
        );
        return;
      }
      // No 0x10 permission: preserve stock behavior by queueing the command
      // unchanged, with no execution and no automatic reply.
    }

    await deps.enqueueMessage(
      QueuedMessage(
        senderKey: sender.publicKey,
        txtType: txtType,
        timestamp: ts,
        text: text,
        snr: packet.snr,
        rssi: packet.rssi,
      ),
      identityGeneration: generation,
    );
  }

  Uint8List _readCStringBytes(Uint8List data, int start) {
    final out = <int>[];
    for (var i = start; i < data.length; i++) {
      if (data[i] == 0) break;
      out.add(data[i]);
    }
    return Uint8List.fromList(out);
  }

  /// Try every known contact whose first public-key byte matches [srcHash].
  /// Selecting the first hash match would let a 1-byte collision pick the wrong
  /// permission set or prevent decryption of the real sender.
  Future<(Contact, Uint8List)?> _decryptFromSource(
    int srcHash,
    Uint8List ciphertext,
    int generation,
  ) async {
    for (final contact in contacts.all) {
      if (contact.publicKey.isEmpty || contact.publicKey[0] != srcHash) {
        continue;
      }
      final secret = await identity.sharedSecret(contact.publicKey);
      if (!deps.isCurrent(generation)) return null;
      try {
        final plaintext = CryptoUtils.macThenDecrypt(
          secret.sublist(0, 16),
          secret,
          ciphertext,
        );
        if (!deps.isCurrent(generation)) return null;
        return (contact, plaintext);
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  Future<void> _handleRemoteCli(
    Contact sender,
    int requestTimestamp,
    Uint8List commandBytes,
    int generation,
  ) async {
    String reply;
    String? prefix;
    try {
      final invocation = CliParser.parseBytes(commandBytes);
      prefix = invocation.prefix;
      final denial = CliRemotePolicy.denialFor(invocation);
      if (denial != null) {
        reply = denial;
      } else {
        reply = await cli.runVirtualCommand(invocation.command);
      }
    } on CliFormatException catch (e) {
      prefix = e.prefix;
      reply = 'Error: illegal argument';
    } on CompanionOperationError catch (e) {
      reply = cli.operationErrorText(e);
    }
    if (!deps.isCurrent(generation)) return;
    _scheduleCliReply(
        sender, requestTimestamp, cli.reply(prefix, reply), generation);
  }

  void _scheduleCliReply(
    Contact sender,
    int requestTimestamp,
    String reply,
    int generation,
  ) {
    if (!deps.isCurrent(generation)) return;
    acks.schedule(const Duration(milliseconds: 600), () {
      unawaited(_sendCliReply(sender, requestTimestamp, reply, generation));
    });
  }

  Future<void> _sendCliReply(
    Contact sender,
    int requestTimestamp,
    String reply,
    int generation,
  ) async {
    if (!deps.isCurrent(generation)) return;
    final timestamp = requests.replyTimestamp(requestTimestamp);
    final (packet, _) = await PacketBuilder.createTextMessage(
      contact: sender,
      identity: identity,
      message: reply,
      txtType: txtTypeCliData,
      timestamp: timestamp,
    );
    if (!deps.isCurrent(generation)) return;
    final flood = !sender.hasDirectRoute;
    await deps.transmit(
      packet,
      flood: flood,
      scoped: true,
      identityGeneration: generation,
    );
  }

  /// Endpoint ACK schedule (never the repeater forwarding fan-out):
  /// * known direct route, multi_acks=0: ACK at 200ms
  /// * known direct route, multi_acks>0: ONE multipart ACK at 200ms, ACK at 500ms
  /// * unknown route: flooded ACK at 200ms
  /// * received flooded: encrypted path-return ACK at 200ms
  void _scheduleTextAck(
    Packet packet,
    Contact sender,
    Uint8List secret,
    Uint8List ackBytes,
  ) {
    const firstDelay = Duration(milliseconds: 200);
    if (packet.isRouteFlood) {
      final pathReturn = PacketBuilder.createPathReturn(
        destHashByte: sender.publicKey[0],
        srcHashByte: identity.publicKey[0],
        secret: secret,
        path: packet.path,
        pathLenEncoded: packet.pathLenByte,
        extraType: payloadTypeAck,
        extra: ackBytes,
      );
      acks.schedule(
        firstDelay,
        () => unawaited(deps.transmit(pathReturn, flood: true, scoped: true)),
      );
      return;
    }

    final ack = PacketBuilder.createAckPacket(ackBytes);
    if (!sender.hasDirectRoute) {
      ack.header = (ack.header & ~phRouteMask) | routeTypeFlood;
      acks.schedule(
        firstDelay,
        () => unawaited(deps.transmit(ack, flood: true, scoped: true)),
      );
      return;
    }

    ack.setPath(sender.outPath, sender.outPathLen);
    if (prefs.multiAcks > 0) {
      final multi = PacketBuilder.createMultiAck(ackBytes, 1)
        ..setPath(sender.outPath, sender.outPathLen);
      acks.schedule(
        firstDelay,
        () => unawaited(deps.transmit(multi, flood: false)),
      );
      acks.schedule(
        const Duration(milliseconds: 500),
        () => unawaited(deps.transmit(ack, flood: false)),
      );
    } else {
      acks.schedule(
        firstDelay,
        () => unawaited(deps.transmit(ack, flood: false)),
      );
    }
  }

  Future<void> _onGroupText(
    Packet packet,
    int generation, {
    bool peerOrigin = false,
  }) async {
    if (packet.payload.length < 3) return;
    final decoded = _decryptChannelPayload(packet);
    if (decoded == null) return;
    final plaintext = decoded.plaintext;
    if (deduper.consumeSentGroup(packet.calculatePacketHash())) return;
    if (plaintext.length < 5) return;
    final r = BufferReader(plaintext);
    final ts = r.readUInt32Le();
    r.skipBytes(1); // flags
    final text = r.readCString();
    // Raw RX is forwarded separately for path/repeat tracking; don't queue our
    // own channel TX as a new incoming message. A locally mirrored peer copy is
    // not our own TX even when both identities share a display name.
    if (!peerOrigin && text.startsWith('${prefs.nodeName}: ')) return;
    if (!deps.isCurrent(generation)) return;
    if (deduper.isDuplicate(packet.calculatePacketHash())) return;
    await deps.enqueueMessage(
      QueuedMessage(
        senderKey: Uint8List(32),
        timestamp: ts,
        text: text,
        isChannel: true,
        channelIdx: decoded.channelIdx,
        pathLen: packet.isRouteFlood ? packet.pathLenByte : 0xFF,
        snr: packet.snr,
        rssi: packet.rssi,
      ),
      identityGeneration: generation,
    );
  }

  Future<void> _onGroupData(Packet packet, int generation) async {
    if (packet.payload.length < 4) return;
    final decoded = _decryptChannelPayload(packet);
    if (decoded == null) return;
    final plaintext = decoded.plaintext;
    if (plaintext.length < 3) return;
    final dataType = plaintext[0] | (plaintext[1] << 8);
    final dataLen = plaintext[2];
    if (dataType == dataTypeReserved ||
        dataLen > maxChannelDataLength ||
        plaintext.length < 3 + dataLen) {
      return;
    }
    if (!deps.isCurrent(generation)) return;
    if (deduper.isDuplicate(packet.calculatePacketHash())) return;
    await deps.enqueueMessage(
      QueuedMessage(
        senderKey: Uint8List(32),
        isChannel: true,
        channelIdx: decoded.channelIdx,
        pathLen: packet.isRouteFlood ? packet.pathLenByte : 0xFF,
        snr: packet.snr,
        rssi: packet.rssi,
        channelDataType: dataType,
        channelDataPayload: Uint8List.fromList(
          plaintext.sublist(3, 3 + dataLen),
        ),
      ),
      identityGeneration: generation,
    );
  }

  ({int channelIdx, Uint8List plaintext})? _decryptChannelPayload(
    Packet packet,
  ) {
    final channelHashByte = packet.payload[0];
    Channel? channel;
    var channelIdx = 0;
    channels.forEach((idx, ch) {
      if (channelHash(ch.secret) == channelHashByte) {
        channel = ch;
        channelIdx = idx;
      }
    });
    if (channel == null) return null;
    final ch = channel!;
    final secret = channelSecret32(ch.secret);
    try {
      return (
        channelIdx: channelIdx,
        plaintext: CryptoUtils.macThenDecrypt(
          secret.sublist(0, 16),
          secret,
          packet.payload.sublist(1),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _onRequest(Packet packet, int generation) async {
    if (packet.payload.length < 2) return;
    if (packet.payload[0] != identity.publicKey[0]) return;
    final decrypted = await _decryptFromSource(
      packet.payload[1],
      packet.payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
    // tag u32 + protocol code are the minimum request body.
    if (plaintext.length < 5) return;
    final tag = BufferReader(plaintext).readUInt32Le();
    final protocolCode = plaintext[4];
    if (protocolCode != reqTypeGetTelemetryData) return;
    // Validate the inverse-mask byte before reading it.
    if (plaintext.length < 6) return;
    final inverseMask = plaintext[5];
    if (!contacts.isPersistent(sender)) return;

    final permissions = _grantedTelemetryPermissions(sender, inverseMask);
    if ((permissions & telemPermBase) == 0) return;

    final millivolts = await battery.refresh(force: true);
    if (!deps.isCurrent(generation)) return;
    final lpp = _encodeTelemetryLpp(
      millivolts,
      includeLocation: (permissions & telemPermLocation) != 0,
    );
    final reply = Uint8List.fromList([
      ...(BufferWriter()..writeUInt32Le(tag)).toBytes(),
      ...lpp,
    ]);
    final senderCopy = sender.clone();
    final requestPath = Uint8List.fromList(packet.path);
    final requestPathLen = packet.pathLenByte;
    final requestWasFlood = packet.isRouteFlood;
    acks.schedule(const Duration(milliseconds: 300), () {
      unawaited(_sendTelemetryReply(
        senderCopy,
        reply,
        requestWasFlood: requestWasFlood,
        requestPath: requestPath,
        requestPathLen: requestPathLen,
        generation: generation,
      ));
    });
  }

  int _grantedTelemetryPermissions(Contact sender, int inverseMask) {
    var permissions = 0;
    final baseFlag = (sender.flags & 0x02) != 0;
    final locationFlag = (sender.flags & 0x04) != 0;
    final envFlag = (sender.flags & 0x08) != 0;
    if (prefs.telemetryModeBase == teleModeAllowAll ||
        (prefs.telemetryModeBase == teleModeAllowFlags && baseFlag)) {
      permissions |= telemPermBase;
    }
    if (prefs.telemetryModeLocation == teleModeAllowAll ||
        (prefs.telemetryModeLocation == teleModeAllowFlags && locationFlag)) {
      permissions |= telemPermLocation;
    }
    if (prefs.telemetryModeEnvironment == teleModeAllowAll ||
        (prefs.telemetryModeEnvironment == teleModeAllowFlags && envFlag)) {
      permissions |= telemPermEnvironment;
    }
    return permissions & (~inverseMask & 0xFF);
  }

  Uint8List _encodeTelemetryLpp(
    int millivolts, {
    required bool includeLocation,
  }) {
    final w = BufferWriter()
      ..writeBytes(encodeSelfVoltageTelemetry(millivolts));
    if (includeLocation) {
      w
        ..writeByte(telemChannelSelf)
        ..writeByte(0x88); // CayenneLPP GPS
      _writeSigned24(w, (prefs.latitude * 10000).round());
      _writeSigned24(w, (prefs.longitude * 10000).round());
      _writeSigned24(w, 0); // altitude
    }
    return w.toBytes();
  }

  void _writeSigned24(BufferWriter w, int value) {
    final clamped = value.clamp(-0x800000, 0x7FFFFF);
    final encoded = clamped < 0 ? clamped + 0x1000000 : clamped;
    w
      ..writeByte((encoded >> 16) & 0xFF)
      ..writeByte((encoded >> 8) & 0xFF)
      ..writeByte(encoded & 0xFF);
  }

  Future<void> _sendTelemetryReply(
    Contact sender,
    Uint8List data, {
    required bool requestWasFlood,
    required Uint8List requestPath,
    required int requestPathLen,
    required int generation,
  }) async {
    if (!deps.isCurrent(generation)) return;
    if (requestWasFlood) {
      final secret = await identity.sharedSecret(sender.publicKey);
      if (!deps.isCurrent(generation)) return;
      final pathReturn = PacketBuilder.createPathReturn(
        destHashByte: sender.publicKey[0],
        srcHashByte: identity.publicKey[0],
        secret: secret,
        path: requestPath,
        pathLenEncoded: requestPathLen,
        extraType: payloadTypeResponse,
        extra: data,
      );
      await deps.transmit(
        pathReturn,
        flood: true,
        scoped: true,
        identityGeneration: generation,
      );
      return;
    }

    final flood = !sender.hasDirectRoute;
    final response = await PacketBuilder.createProtocolResponse(
      contact: sender,
      identity: identity,
      data: data,
      flood: flood,
    );
    if (!deps.isCurrent(generation)) return;
    await deps.transmit(
      response,
      flood: flood,
      scoped: flood,
      identityGeneration: generation,
    );
  }

  void _onControlData(Packet packet) {
    if (packet.payload.isEmpty) return;
    // Discovery/probe control payloads are zero-hop direct. Flooded or
    // still-in-transit control data is not delivered as a local discovery event.
    if (!packet.isRouteDirect || packet.pathHashCount != 0) return;
    if (deduper.isDuplicate(packet.calculatePacketHash())) return;
    pushSink?.pushControlData(
      packet.snr,
      packet.rssi,
      packet.pathLenByte,
      packet.payload,
    );
  }

  void _onRawCustom(Packet packet, {bool peerOrigin = false}) {
    // Raw custom delivery is direct-route zero-hop only. Flooded/raw-in-transit
    // packets remain available through the full 0x88 raw RX log. A local peer
    // copy is already at its final endpoint even when a direct path remains.
    if (!packet.isRouteDirect || (!peerOrigin && packet.pathHashCount != 0)) {
      return;
    }
    if (deduper.isDuplicate(packet.calculatePacketHash())) return;
    pushSink?.pushRawData(packet.snr, packet.rssi, packet.payload);
  }

  /// Handle a returned trace packet (`PAYLOAD_TYPE_TRACE`, route direct). The
  /// payload is `tag(4) + auth(4) + flags(1) + requested path hashes`; the
  /// routing path holds one accumulated SNR byte per hop. The proxy does not
  /// forward traces, so it only reports the result once the requested path has
  /// been fully consumed (the trace has returned to us).
  void _onTrace(Packet packet) {
    if (!packet.isRouteDirect) return;
    final trace = decodeTracePayload(packet.payload);
    if (trace == null) return;
    final tag = trace.tag;
    final authCode = trace.authCode;
    final flags = trace.flags;
    final pathSz = trace.pathSize;
    final pathHashes = trace.path;
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
    if (sessions.acceptAck(crc)) return;
    acks.confirm(crc);
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

  /// Handle a returned-path packet (payload type `0x08`). The encrypted inner
  /// payload is `path_len | path | extra_type | extra`. When the extra is an
  /// ACK hash we confirm the pending send; the path is the route back to the
  /// sender, so we cache it for future direct sends.
  Future<void> _onPathReturn(Packet packet, int generation) async {
    final payload = packet.payload;
    if (payload.length < 2) return;
    if (payload[0] != identity.publicKey[0]) return; // not addressed to us
    final srcHash = payload[1];
    final decrypted = await _decryptFromSource(
      srcHash,
      payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
    final pathReturn = decodePathReturnPayload(plaintext);
    if (pathReturn == null) return;
    final pathLenEncoded = pathReturn.pathLenEncoded;
    final outPath = pathReturn.path;
    final extraType = pathReturn.extraType;
    final extra = pathReturn.extra;

    if (pathReturn.hasValidPath) {
      // A zero-length path is a valid zero-hop direct route. Store it like the
      // firmware does instead of leaving the contact in the flood/unknown state.
      sender.outPath = Uint8List.fromList(outPath);
      sender.outPathLen = pathLenEncoded;
      sender.lastmod = clock.wallSeconds;
      final isTransient =
          contacts.transient.any((c) => c.publicKeyHex == sender.publicKeyHex);
      if (!isTransient && deps.isCurrent(generation)) {
        try {
          await deps.addUpdateContact(sender, identityGeneration: generation);
        } on CompanionOperationError {
          // The route update is still useful even if persistence fails.
        }
        if (!deps.isCurrent(generation)) return;
        pushSink?.pushPathUpdated(sender.publicKey);
      }
    }
    if (!deps.isCurrent(generation)) return;

    if (extraType == payloadTypeAck && extra.length >= 4) {
      final crc =
          extra[0] | (extra[1] << 8) | (extra[2] << 16) | (extra[3] << 24);
      acks.confirm(crc);
    } else if (extraType == payloadTypeResponse) {
      _dispatchResponse(
        sender.publicKey,
        extra,
        outPath: outPath,
        outPathLen: pathLenEncoded,
        inPath: packet.path,
        inPathLen: packet.pathLenByte,
      );
    }
  }

  /// Handle a `PAYLOAD_TYPE_RESPONSE` datagram (a response to a request sent as
  /// a direct datagram rather than a returned-path packet).
  Future<void> _onResponse(Packet packet, int generation) async {
    final payload = packet.payload;
    if (payload.length < 2) return;
    if (payload[0] != identity.publicKey[0]) return;
    final srcHash = payload[1];
    final decrypted = await _decryptFromSource(
      srcHash,
      payload.sublist(2),
      generation,
    );
    if (decrypted == null) return;
    final (sender, plaintext) = decrypted;
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
    final prefix4 = Uint8List.fromList(senderPubkey.sublist(0, keyPrefix4));
    sessions.markActive(senderPubkey);

    final discoveryTarget = requests.discoveryTarget(tag);
    if (outPath != null &&
        outPathLen != null &&
        inPath != null &&
        inPathLen != null &&
        discoveryTarget != null &&
        bytesEqual(discoveryTarget, senderPubkey)) {
      requests.removeDiscovery(tag);
      pushSink?.pushPathDiscoveryResponse(
        Uint8List.fromList(senderPubkey.sublist(0, keyPrefix6)),
        outPathLen,
        outPath,
        inPathLen,
        inPath,
      );
      return;
    }

    final telemetryTarget = requests.telemetryTarget(tag);
    if (telemetryTarget != null &&
        bytesEqual(telemetryTarget, senderPubkey) &&
        data.length > 4) {
      requests.removeTelemetry(tag);
      pushSink?.pushTelemetryResponse(
        Uint8List.fromList(senderPubkey.sublist(0, keyPrefix6)),
        Uint8List.fromList(data.sublist(4)),
      );
      return;
    }

    final binaryTarget = requests.binaryTarget(tag);
    if (binaryTarget != null && bytesEqual(binaryTarget, senderPubkey)) {
      requests.removeBinary(tag);
      pushSink?.pushBinaryResponse(
        tag,
        Uint8List.fromList(data.length > 4 ? data.sublist(4) : const []),
      );
      return;
    }

    if (requests.takeLogin(prefix4)) {
      _handleLoginResponse(senderPubkey, data);
      return;
    }

    if (requests.takeStatus(prefix4)) {
      if (data.length > 4) {
        pushSink?.pushStatusResponse(
          Uint8List.fromList(senderPubkey.sublist(0, keyPrefix6)),
          Uint8List.fromList(data.sublist(4)),
        );
      }
      return;
    }

    // Valid authenticated responses that match no pending request are
    // unsolicited pushes (for example sensor telemetry), not virtual requests.
    // Preserve tag + payload bytes exactly, including their timestamp/LPP.
    pushSink?.pushBinaryResponse(
      tag,
      Uint8List.fromList(data.length > 4 ? data.sublist(4) : const []),
    );
  }

  void _handleLoginResponse(Uint8List senderPubkey, Uint8List data) {
    final prefix6 = Uint8List.fromList(senderPubkey.sublist(0, keyPrefix6));
    // Legacy repeater login replies with the literal "OK".
    if (data.length >= 6 && data[4] == 0x4F && data[5] == 0x4B) {
      pushSink?.pushLoginSuccess(prefix6, legacy: true);
      return;
    }
    if (data.length > 4 && data[4] == respServerLoginOk) {
      final tag = data[0] | (data[1] << 8) | (data[2] << 16) | (data[3] << 24);
      final keepAliveSecs = data.length > 5 ? data[5] * 16 : 0;
      if (keepAliveSecs > 0) sessions.start(senderPubkey, keepAliveSecs);
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
}

/// A received advert saved for sharing/export, always normalized to flood so
/// region transport codes are not persisted.
Uint8List _normalizedAdvertBlob(Packet packet) {
  final saved = Packet()
    ..header = (packet.header & ~phRouteMask) | routeTypeFlood
    ..pathLenByte = packet.pathLenByte
    ..path = Uint8List.fromList(packet.path)
    ..payload = Uint8List.fromList(packet.payload);
  return saved.writeTo();
}
