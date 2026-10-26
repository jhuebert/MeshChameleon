// Companion-protocol conformance client for hardware-in-the-loop checks.
//
//   dart run tool/hil_client.dart <command> <host> <port> [options]
//
// Commands:
//   handshake                 DEVICE_QUERY + APP_START, print decoded info
//   raw --hex <hex>...        send exact payloads, print every frame JSONL
//   script <file.json>        run a declarative scenario (see below)
//   listen --secs <n>         print incoming frames
//   fuzz [--count N]          malformed-frame robustness sweep
//   keys-export <file>        export virtual 64-byte key to a 0600 file
//   keys-import <file>        import a 64-byte key from a file
//   contacts [--since N]      list contacts
//   channels                  list all channels (empty-payload extension)
//   messages [--max N]        drain queued messages, V3 layout
//   stats [--type N]          request core/radio stats
//   cli <text>                run a virtual CLI command
//   sign <in> <out>           sign a file, verify with the virtual public key
//   framing                   framing negatives
//   concurrency               pipelining / eviction
//
// Scenario JSON:
//   {"handshake": true, "appVersion": 3, "steps": [
//     {"name":"x", "send":"3A 06 02", "waitMs":300,
//      "expect":{"code":0, "exact":"00", "prefix":"0001",
//                "contains":"5A", "minLen":2, "maxLen":200,
//                "codes":[13,128], "push":128, "noReply":true,
//                "text":"OK"}}]}
//
// Prints one JSON object per step plus a final `{"summary":...}` line.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'src/hil_protocol.dart';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln('usage: hil_client <command> <host> <port> [options]');
    exit(2);
  }
  final command = args[0];
  final host = args[1];
  final port = int.parse(args[2]);
  final rest = args.sublist(3);

  switch (command) {
    case 'handshake':
      await _handshake(host, port, rest);
    case 'raw':
      await _raw(host, port, rest);
    case 'script':
      await _script(host, port, rest);
    case 'listen':
      await _listen(host, port, rest);
    case 'fuzz':
      await _fuzz(host, port, rest);
    case 'keys-export':
      await _keys(host, port, rest, export: true);
    case 'keys-import':
      await _keys(host, port, rest, export: false);
    case 'contacts':
      await _contacts(host, port, rest);
    case 'channels':
      await _channels(host, port, rest);
    case 'messages':
      await _messages(host, port, rest);
    case 'stats':
      await _stats(host, port, rest);
    case 'cli':
      await _cli(host, port, rest);
    case 'sign':
      await _sign(host, port, rest);
    case 'framing':
      await _framing(host, port, rest);
    case 'concurrency':
      await _concurrency(host, port, rest);
    default:
      stderr.writeln('unknown command "$command"');
      exit(2);
  }
  exit(0);
}

Future<HilConnection> _connect(String host, int port) async {
  final conn = HilConnection(host, port);
  await conn.connect();
  return conn;
}

int _appVersion(List<String> args) {
  final i = args.indexOf('--app-ver');
  return i >= 0 && i + 1 < args.length
      ? int.parse(args[i + 1])
      : appProtocolVersion;
}

void _emit(Map<String, Object?> value) => stdout.writeln(jsonEncode(value));

Future<void> _handshake(String host, int port, List<String> args) async {
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    _emit({
      'command': 'handshake',
      'device': conn.deviceInfo == null
          ? null
          : {
              'fw': conn.deviceInfo!.firmwareVerCode,
              'maxContacts': conn.deviceInfo!.maxContacts,
              'maxChannels': conn.deviceInfo!.maxChannels,
              'clientRepeat': conn.deviceInfo!.clientRepeat,
              'pathHashMode': conn.deviceInfo!.pathHashMode,
              'manufacturer': conn.deviceInfo!.manufacturer,
              'version': conn.deviceInfo!.version,
            },
      'pubkey': conn.publicKey == null ? null : bytesToHex(conn.publicKey!),
      'frames': conn.log.map((f) => f.toJson()).toList(),
    });
  } finally {
    await conn.close();
  }
}

Future<void> _raw(String host, int port, List<String> args) async {
  final hexes = <String>[];
  var handshake = false;
  var wait = 400;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--hex':
        hexes.add(args[++i]);
      case '--handshake':
        handshake = true;
      case '--wait':
        wait = int.parse(args[++i]);
    }
  }
  final conn = await _connect(host, port);
  try {
    if (handshake) await conn.handshake(appVersion: _appVersion(args));
    for (final hex in hexes) {
      conn.sendHex(hex);
      final frames = await conn.collect(
        quiet: Duration(milliseconds: wait),
        timeout: Duration(seconds: 10),
      );
      _emit({
        'sent': hex,
        'frames': frames.map((f) => f.toJson()).toList(),
      });
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  } finally {
    await conn.close();
  }
}

Future<void> _script(String host, int port, List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('script needs a file');
    exit(2);
  }
  final spec =
      jsonDecode(File(args.first).readAsStringSync()) as Map<String, dynamic>;
  final conn = await _connect(host, port);
  var pass = 0;
  var fail = 0;
  try {
    if (spec['handshake'] == true) {
      await conn.handshake(
          appVersion:
              (spec['appVersion'] as num?)?.toInt() ?? appProtocolVersion);
    }
    final steps = (spec['steps'] as List<dynamic>? ?? const []);
    for (final rawStep in steps) {
      final step = rawStep as Map<String, dynamic>;
      final name = step['name'] as String? ?? 'step';
      final send = step['send'] as String?;
      final sendBytes = step['sendBytes'] == true;
      final waitMs = (step['waitMs'] as num?)?.toInt() ?? 300;
      final sleepMs = (step['sleepMs'] as num?)?.toInt();
      final expect = step['expect'] as Map<String, dynamic>?;
      final before = conn.log.length;
      try {
        if (send != null) {
          if (sendBytes) {
            conn.sendRaw(parseHex(send));
          } else {
            conn.send(parseHex(send));
          }
        }
        await Future<void>.delayed(Duration(milliseconds: waitMs));
        if (sleepMs != null && sleepMs > 0) {
          await Future<void>.delayed(Duration(milliseconds: sleepMs));
        }
      } catch (e) {
        _emit({'step': name, 'ok': false, 'error': '$e'});
        fail++;
        continue;
      }
      final frames = conn.log.sublist(before);
      final nonPush = frames.where((f) => !f.isPush).toList();
      String? error;
      if (expect != null) error = _checkExpect(expect, frames, nonPush);
      final ok = error == null;
      ok ? pass++ : fail++;
      _emit({
        'step': name,
        'ok': ok,
        if (error != null) 'error': error,
        'frames': frames.map((f) => f.toJson()).toList(),
      });
    }
  } finally {
    await conn.close();
  }
  _emit({
    'summary': {'pass': pass, 'fail': fail}
  });
}

String? _checkExpect(
  Map<String, dynamic> expect,
  List<HilFrame> frames,
  List<HilFrame> nonPush,
) {
  if (expect['noReply'] == true && nonPush.isNotEmpty) {
    return 'expected no reply, got ${nonPush.map((f) => f.hex).toList()}';
  }
  if (expect['code'] != null) {
    if (nonPush.isEmpty) return 'no reply (wanted code ${expect['code']})';
    if (nonPush.first.code != (expect['code'] as num).toInt()) {
      return 'code ${nonPush.first.code} != ${expect['code']}';
    }
  }
  if (expect['exact'] != null) {
    if (nonPush.isEmpty) return 'no reply (wanted exact ${expect['exact']})';
    final wanted =
        (expect['exact'] as String).toLowerCase().replaceAll(' ', '');
    if (nonPush.first.hex.toLowerCase() != wanted) {
      return 'exact ${nonPush.first.hex} != $wanted';
    }
  }
  if (expect['prefix'] != null) {
    if (nonPush.isEmpty) return 'no reply (wanted prefix ${expect['prefix']})';
    final wanted =
        (expect['prefix'] as String).toLowerCase().replaceAll(' ', '');
    if (!nonPush.first.hex.toLowerCase().startsWith(wanted)) {
      return 'prefix ${nonPush.first.hex} !~ $wanted';
    }
  }
  if (expect['contains'] != null) {
    final wanted =
        (expect['contains'] as String).toLowerCase().replaceAll(' ', '');
    if (!frames.any((f) => f.hex.toLowerCase().contains(wanted))) {
      return 'no frame contains $wanted';
    }
  }
  if (expect['minLen'] != null) {
    if (nonPush.isEmpty ||
        nonPush.first.payload.length < (expect['minLen'] as num)) {
      return 'len ${nonPush.isEmpty ? 'none' : nonPush.first.payload.length} < ${expect['minLen']}';
    }
  }
  if (expect['maxLen'] != null) {
    if (nonPush.isEmpty ||
        nonPush.first.payload.length > (expect['maxLen'] as num)) {
      return 'len ${nonPush.isEmpty ? 'none' : nonPush.first.payload.length} > ${expect['maxLen']}';
    }
  }
  if (expect['codes'] != null) {
    final wanted = (expect['codes'] as List<dynamic>)
        .cast<num>()
        .map((n) => n.toInt())
        .toList();
    final got = frames.map((f) => f.code).toList();
    if (!_listEquals(wanted, got)) return 'codes $got != $wanted';
  }
  if (expect['push'] != null) {
    final wanted = (expect['push'] as num).toInt();
    if (!frames.any((f) => f.isPush && f.code == wanted)) {
      return 'no push 0x${wanted.toRadixString(16)}';
    }
  }
  if (expect['text'] != null) {
    if (nonPush.isEmpty) return 'no CLI reply';
    final text =
        utf8.decode(nonPush.first.payload.sublist(1), allowMalformed: true);
    if (text != expect['text']) return 'text "$text" != "${expect['text']}"';
  }
  if (expect['textStarts'] != null) {
    if (nonPush.isEmpty) return 'no CLI reply';
    final text =
        utf8.decode(nonPush.first.payload.sublist(1), allowMalformed: true);
    if (!text.startsWith(expect['textStarts'] as String)) {
      return 'text "$text" !~ "${expect['textStarts']}"';
    }
  }
  if (expect['frame'] != null) {
    final wanted = (expect['frame'] as List<dynamic>).cast<dynamic>();
    if (nonPush.isEmpty) return 'no reply';
    final expectedHex = (wanted[0] as String).toLowerCase().replaceAll(' ', '');
    final at = (wanted.length > 1 ? wanted[1] as num : 0).toInt();
    if (at >= nonPush.length) return 'frame index $at missing';
    if (nonPush[at].hex.toLowerCase() != expectedHex) {
      return 'frame[$at] ${nonPush[at].hex} != $expectedHex';
    }
  }
  return null;
}

bool _listEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<void> _listen(String host, int port, List<String> args) async {
  final secs = args.contains('--secs')
      ? int.parse(args[args.indexOf('--secs') + 1])
      : 10;
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    final end = DateTime.now().add(Duration(seconds: secs));
    while (DateTime.now().isBefore(end)) {
      try {
        final frame = await conn.next(
          timeout: end.difference(DateTime.now()),
          includePushes: true,
        );
        _emit(frame.toJson());
      } on TimeoutException {
        break;
      }
    }
  } finally {
    await conn.close();
  }
}

Future<void> _fuzz(String host, int port, List<String> args) async {
  final count = args.contains('--count')
      ? int.parse(args[args.indexOf('--count') + 1])
      : 100;
  final conn = await _connect(host, port);
  final random = _SeededRandom(0x48494c);
  var sent = 0;
  var alive = true;
  String? error;
  try {
    for (var i = 0; i < count; i++) {
      final kind = i % 4;
      if (kind == 0) {
        // Random junk.
        final n = 1 + random.nextInt(64);
        conn.sendRaw(List<int>.generate(n, (_) => random.nextInt(256)));
      } else if (kind == 1) {
        // Wrong prefix, valid-looking payload.
        conn.sendRaw([0x3E, 1, 0, cmdDeviceQuery]);
      } else if (kind == 2) {
        // Oversized declared payload followed by a little data.
        conn.sendRaw([0x3C, 0xFF, 0x00, cmdDeviceQuery, 0]);
      } else {
        // Truncated valid frame.
        conn.sendRaw([0x3C, 8, 0, cmdDeviceQuery]);
      }
      sent++;
      await Future<void>.delayed(const Duration(milliseconds: 5));
      // Keep only bounded unread input: drop whatever arrived.
      try {
        await conn.next(timeout: const Duration(milliseconds: 20));
      } on TimeoutException {
        // expected most of the time
      }
    }
    // Liveness probe after junk.
    conn.send([cmdDeviceQuery, appProtocolVersion]);
    final reply = await conn.next(timeout: const Duration(seconds: 10));
    alive = reply.code == respCodeDeviceInfo;
    if (!alive) error = 'liveness reply code ${reply.code}';
  } catch (e) {
    alive = false;
    error = '$e';
  } finally {
    await conn.close();
  }
  _emit({
    'command': 'fuzz',
    'sent': sent,
    'alive': alive,
    if (error != null) 'error': error,
    'ok': alive,
  });
}

Future<void> _keys(
  String host,
  int port,
  List<String> args, {
  required bool export,
}) async {
  if (args.isEmpty) {
    stderr.writeln(
        export ? 'keys-export needs a file' : 'keys-import needs a file');
    exit(2);
  }
  final path = args.first;
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    if (export) {
      conn.send([cmdExportPrivateKey]);
      final reply = await conn.next(timeout: const Duration(seconds: 10));
      if (reply.code != respCodePrivateKey || reply.payload.length < 65) {
        _emit({'ok': false, 'error': 'export failed: ${reply.hex}'});
        return;
      }
      final key = Uint8List.fromList(reply.payload.sublist(1, 65));
      final file = File(path);
      await file.writeAsBytes(key, flush: true);
      await Process.run('chmod', ['600', path]);
      _emit({
        'command': 'keys-export',
        'ok': true,
        'fingerprint': bytesToHex(CryptoUtils.sha256(key)),
        'publicKey': bytesToHex(conn.publicKey ?? const []),
      });
    } else {
      final key = await File(path).readAsBytes();
      conn.send([cmdImportPrivateKey, ...key]);
      final reply = await conn.next(timeout: const Duration(seconds: 10));
      _emit({
        'command': 'keys-import',
        'ok': reply.code == respCodeOk,
        'reply': reply.hex,
        'fingerprint': bytesToHex(CryptoUtils.sha256(key)),
      });
    }
  } finally {
    await conn.close();
  }
}

Future<void> _contacts(String host, int port, List<String> args) async {
  final since = args.contains('--since')
      ? int.parse(args[args.indexOf('--since') + 1])
      : 0;
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    conn.send([
      cmdGetContacts,
      since & 0xFF,
      (since >> 8) & 0xFF,
      (since >> 16) & 0xFF,
      (since >> 24) & 0xFF,
    ]);
    final frames = await conn.collect(
      quiet: const Duration(milliseconds: 400),
      timeout: const Duration(seconds: 30),
    );
    final contacts = <Map<String, Object?>>[];
    for (final f in frames) {
      if (f.code == respCodeContact) contacts.add(parseContact(f.payload));
    }
    _emit({
      'command': 'contacts',
      'count': contacts.length,
      'contacts': contacts
    });
  } finally {
    await conn.close();
  }
}

Future<void> _channels(String host, int port, List<String> args) async {
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    conn.send([cmdGetChannel]);
    final frames = await conn.collect(
      quiet: const Duration(milliseconds: 400),
      timeout: const Duration(seconds: 10),
    );
    final channels = <Map<String, Object?>>[];
    for (final f in frames) {
      if (f.code == respCodeChannelInfo) channels.add(parseChannel(f.payload));
    }
    _emit({
      'command': 'channels',
      'count': channels.length,
      'channels': channels
    });
  } finally {
    await conn.close();
  }
}

Future<void> _messages(String host, int port, List<String> args) async {
  final max =
      args.contains('--max') ? int.parse(args[args.indexOf('--max') + 1]) : 50;
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    final messages = <Map<String, Object?>>[];
    for (var i = 0; i < max; i++) {
      conn.send([cmdSyncNextMessage]);
      final reply = await conn.next(timeout: const Duration(seconds: 5));
      final parsed = parseQueuedMessage(reply.payload);
      if (parsed['empty'] == true) break;
      messages.add(parsed);
    }
    _emit({
      'command': 'messages',
      'count': messages.length,
      'messages': messages
    });
  } finally {
    await conn.close();
  }
}

Future<void> _stats(String host, int port, List<String> args) async {
  final type = args.contains('--type')
      ? int.parse(args[args.indexOf('--type') + 1])
      : statsTypeCore;
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    conn.send([cmdGetStats, type]);
    final reply = await conn.next(timeout: const Duration(seconds: 5));
    _emit({'command': 'stats', 'type': type, 'reply': reply.hex});
  } finally {
    await conn.close();
  }
}

Future<void> _cli(String host, int port, List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('cli needs a command string');
    exit(2);
  }
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    conn.send([cmdRunCliCommand, ...utf8.encode(args.first)]);
    final reply = await conn.next(timeout: const Duration(seconds: 20));
    final text = reply.code == respCodeCliReply
        ? utf8.decode(reply.payload.sublist(1), allowMalformed: true)
        : '<code ${reply.code}>';
    _emit({
      'command': 'cli',
      'sent': args.first,
      'code': reply.code,
      'text': text
    });
  } finally {
    await conn.close();
  }
}

Future<void> _sign(String host, int port, List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('sign needs <in> <out>');
    exit(2);
  }
  final data = await File(args[0]).readAsBytes();
  final conn = await _connect(host, port);
  try {
    await conn.handshake(appVersion: _appVersion(args));
    final start = await conn.request([cmdSignStart]);
    final maxLen = start.payload.length >= 5
        ? ByteData.sublistView(start.payload, 1, 5).getUint32(0, Endian.little)
        : -1;
    var offset = 0;
    while (offset < data.length) {
      final n = (data.length - offset).clamp(0, 128);
      final chunk = data.sublist(offset, offset + n);
      conn.send([cmdSignData, ...chunk]);
      final ack = await conn.next(timeout: const Duration(seconds: 10));
      if (ack.code != respCodeOk) throw StateError('sign data: ${ack.hex}');
      offset += n;
    }
    conn.send([cmdSignFinish]);
    final sigFrame = await conn.next(timeout: const Duration(seconds: 10));
    if (sigFrame.code != respCodeSignature || sigFrame.payload.length < 65) {
      _emit({'ok': false, 'error': 'sign finish: ${sigFrame.hex}'});
      return;
    }
    final signature = Uint8List.fromList(sigFrame.payload.sublist(1, 65));
    await File(args[1]).writeAsBytes(signature, flush: true);
    final verified = conn.publicKey == null
        ? false
        : await LocalIdentity.verify(data, signature, conn.publicKey!);
    _emit({
      'command': 'sign',
      'ok': verified,
      'start': start.hex,
      'maxLen': maxLen,
      'bytes': data.length,
      'signature': bytesToHex(CryptoUtils.sha256(signature)),
      'verified': verified,
    });
  } finally {
    await conn.close();
  }
}

Future<void> _framing(String host, int port, List<String> args) async {
  final conn = await _connect(host, port);
  final results = <Map<String, Object?>>[];
  Future<bool> liveness() async {
    conn.send([cmdDeviceQuery, appProtocolVersion]);
    try {
      final reply = await conn.next(timeout: const Duration(seconds: 3));
      return reply.code == respCodeDeviceInfo;
    } on TimeoutException {
      return false;
    }
  }

  Future<void> record(String name, Future<void> Function() action) async {
    String? error;
    var alive = false;
    try {
      await action();
      alive = await liveness();
      if (!alive) error = 'not alive after $name';
    } catch (e) {
      error = '$e';
    }
    results.add({
      'case': name,
      'alive': alive,
      'ok': error == null,
      if (error != null) 'error': error
    });
  }

  try {
    await record('baseline-liveness', () async {});

    await record('wrong-prefix', () async {
      conn.sendRaw([0x3E, 1, 0, cmdDeviceQuery]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await record('oversize-177', () async {
      final payload = [cmdDeviceQuery, ...List<int>.filled(176, 0)];
      conn.sendRaw(
          [0x3C, payload.length & 0xFF, payload.length >> 8, ...payload]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    await record('payload-176', () async {
      final payload = [0xEE, ...List<int>.filled(175, 0)];
      conn.send(payload);
      final reply = await conn.next(timeout: const Duration(seconds: 3));
      if (reply.code != respCodeErr || reply.payload.length < 2) {
        throw StateError('expected [1,1], got ${reply.hex}');
      }
    });

    await record('split-frame', () async {
      final frame = [0x3C, 2, 0, cmdDeviceQuery, appProtocolVersion];
      conn.sendRaw(frame.sublist(0, 2));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      conn.sendRaw(frame.sublist(2));
      final reply = await conn.next(timeout: const Duration(seconds: 3));
      if (reply.code != respCodeDeviceInfo) {
        throw StateError('split reply ${reply.hex}');
      }
    });

    await record('concatenated', () async {
      final frame = [0x3C, 2, 0, cmdDeviceQuery, appProtocolVersion];
      conn.sendRaw([...frame, ...frame]);
      final a = await conn.next(timeout: const Duration(seconds: 3));
      final b = await conn.next(timeout: const Duration(seconds: 3));
      if (a.code != respCodeDeviceInfo || b.code != respCodeDeviceInfo) {
        throw StateError('concat replies ${a.hex} ${b.hex}');
      }
    });

    await record('zero-length', () async {
      conn.sendRaw([0x3C, 0, 0]);
      final reply = await conn.next(timeout: const Duration(seconds: 3));
      if (reply.code != respCodeErr) {
        throw StateError('zero reply ${reply.hex}');
      }
    });

    await record('junk-recovery', () async {
      conn.sendRaw([0xFF, 0x00, 0x3C, 0x99]);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    await record('after-all', () async {});
  } finally {
    await conn.close();
  }
  final ok = results.every((r) => r['ok'] == true);
  _emit({'command': 'framing', 'ok': ok, 'results': results});
}

Future<void> _concurrency(String host, int port, List<String> args) async {
  final conn = await _connect(host, port);
  final results = <Map<String, Object?>>[];
  try {
    await conn.handshake(appVersion: _appVersion(args));
    const n = 20;
    for (var i = 0; i < n; i++) {
      conn.send([cmdDeviceQuery, appProtocolVersion]);
    }
    var ordered = true;
    for (var i = 0; i < n; i++) {
      final reply = await conn.next(timeout: const Duration(seconds: 5));
      if (reply.code != respCodeDeviceInfo) ordered = false;
    }
    results.add({'case': 'pipeline-20', 'ok': ordered});

    // A second client must evict this one; the replacement must get only its
    // own replies.
    final second = await _connect(host, port);
    try {
      await second.handshake(appVersion: _appVersion(args));
      var closed = false;
      try {
        conn.send([cmdDeviceQuery, appProtocolVersion]);
        await conn.next(timeout: const Duration(seconds: 2));
      } catch (_) {
        closed = true;
      }
      results.add({'case': 'second-client-evicts', 'ok': closed});
      final reply = await second.request([cmdDeviceQuery, appProtocolVersion]);
      results.add({
        'case': 'replacement-clean',
        'ok': reply.code == respCodeDeviceInfo,
      });
    } finally {
      await second.close();
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  } finally {
    await conn.close();
  }
  final ok = results.every((r) => r['ok'] == true);
  _emit({'command': 'concurrency', 'ok': ok, 'results': results});
}

class _SeededRandom {
  _SeededRandom(this._state);
  int _state;

  int nextInt(int max) {
    _state = (_state * 1103515245 + 12345) & 0x7FFFFFFF;
    return _state % max;
  }
}
