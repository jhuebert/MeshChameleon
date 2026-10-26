// Device-link TCP relay and fault injector for hardware-in-the-loop checks.
//
//   dart run tool/hil_relay.dart --listen 127.0.0.1:15000 \
//     --upstream <host>:<port> --log /tmp/.../relay.jsonl
//
// Transparent by default. Fault options (all repeatable, `<cmdId>` decimal or
// 0x-hex, `<ms>` milliseconds):
//   --delay-reply <cmd>=<ms>     hold that command's reply
//   --drop-reply <cmd>           never forward that command's reply
//   --inject-err <cmd>=<code>    replace the reply with `[0x01, code]`
//   --truncate-reply <cmd>       forward only the reply's first byte
//   --close-after <cmd>          close the client+upstream after the reply
//
// Secrets are redacted in the log: private-key export/import, CLI commands and
// replies involving WiFi credentials, and channel PSKs. Raw companion pushes
// (>= 0x80) always pass through while a reply is held, so RX during ACK can be
// exercised.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

class _Endpoint {
  _Endpoint(String raw) {
    final sep = raw.lastIndexOf(':');
    if (sep <= 0) throw FormatException('endpoint needs host:port: $raw');
    host = raw.substring(0, sep);
    port = int.parse(raw.substring(sep + 1));
  }

  late final String host;
  late final int port;
}

class _Rule {
  _Rule(this.delayMs, this.drop, this.errCode, this.truncate, this.closeAfter);

  int? delayMs;
  bool drop = false;
  int? dropNth;
  int seen = 0;
  int? errCode;
  bool truncate = false;
  bool closeAfter = false;
}

/// Map a command id to the response code(s) its reply can carry.
const Map<int, Set<int>> _replyCodes = {
  cmdAppStart: {respCodeSelfInfo},
  cmdSendTxtMsg: {respCodeSent},
  cmdSendChannelTxtMsg: {respCodeOk},
  cmdGetContacts: {respCodeContactsStart},
  cmdGetDeviceTime: {respCodeCurrTime},
  cmdSetDeviceTime: {respCodeOk},
  cmdSendSelfAdvert: {respCodeOk},
  cmdSetAdvertName: {respCodeOk},
  cmdAddUpdateContact: {respCodeOk},
  cmdSyncNextMessage: {
    respCodeContactMsgRecv,
    respCodeChannelMsgRecv,
    respCodeNoMoreMessages,
  },
  cmdSetRadioParams: {respCodeOk},
  cmdSetRadioTxPower: {respCodeOk},
  cmdResetPath: {respCodeOk},
  cmdSetAdvertLatLon: {respCodeOk},
  cmdRemoveContact: {respCodeOk},
  cmdShareContact: {respCodeOk},
  cmdExportContact: {respCodeExportContact},
  cmdImportContact: {respCodeOk},
  cmdGetBattAndStorage: {respCodeBattAndStorage},
  cmdSetTuningParams: {respCodeOk},
  cmdDeviceQuery: {respCodeDeviceInfo},
  cmdExportPrivateKey: {respCodePrivateKey},
  cmdImportPrivateKey: {respCodeOk},
  cmdSendRawData: {respCodeOk},
  cmdSendLogin: {respCodeSent},
  cmdSendStatusReq: {respCodeSent},
  cmdHasConnection: {respCodeOk},
  cmdLogout: {respCodeOk},
  cmdGetContactByKey: {respCodeContact},
  cmdGetChannel: {respCodeChannelInfo},
  cmdSetChannel: {respCodeOk},
  cmdSignStart: {respCodeSignStart},
  cmdSignData: {respCodeOk},
  cmdSignFinish: {respCodeSignature},
  cmdSendTracePath: {respCodeSent},
  cmdSetDevicePin: {respCodeDisabled},
  cmdSetOtherParams: {respCodeOk},
  cmdSendTelemetryReq: {respCodeSent, pushCodeTelemetryResponse},
  cmdGetCustomVars: {respCodeCustomVars},
  cmdSetCustomVar: {respCodeOk},
  cmdGetAdvertPath: {respCodeAdvertPath},
  cmdGetTuningParams: {respCodeTuningParams},
  cmdSendBinaryReq: {respCodeSent},
  cmdFactoryReset: {respCodeDisabled},
  cmdSendPathDiscoveryReq: {respCodeSent},
  cmdSetFloodScope: {respCodeOk},
  cmdSendControlData: {respCodeOk},
  cmdGetStats: {respCodeStats},
  cmdSendAnonReq: {respCodeSent},
  cmdSetAutoAddConfig: {respCodeOk},
  cmdGetAutoAddConfig: {respCodeAutoAddConfig},
  cmdGetAllowedRepeatFreq: {respCodeAllowedRepeatFreq},
  cmdSetPathHashMode: {respCodeOk},
  cmdSendChannelData: {respCodeOk},
  cmdSetDefaultFloodScope: {respCodeOk},
  cmdGetDefaultFloodScope: {respCodeDefaultFloodScope},
  cmdSendRawPacket: {respCodeOk},
  cmdRunCliCommand: {respCodeCliReply, respCodeDisabled},
};

const Map<int, String> _cmdNames = {
  cmdAppStart: 'APP_START',
  cmdSendTxtMsg: 'SEND_TXT_MSG',
  cmdSendChannelTxtMsg: 'SEND_CHANNEL_TXT_MSG',
  cmdGetContacts: 'GET_CONTACTS',
  cmdGetDeviceTime: 'GET_DEVICE_TIME',
  cmdSetDeviceTime: 'SET_DEVICE_TIME',
  cmdSendSelfAdvert: 'SEND_SELF_ADVERT',
  cmdSetAdvertName: 'SET_ADVERT_NAME',
  cmdAddUpdateContact: 'ADD_UPDATE_CONTACT',
  cmdSyncNextMessage: 'SYNC_NEXT_MESSAGE',
  cmdSetRadioParams: 'SET_RADIO_PARAMS',
  cmdSetRadioTxPower: 'SET_RADIO_TX_POWER',
  cmdResetPath: 'RESET_PATH',
  cmdSetAdvertLatLon: 'SET_ADVERT_LATLON',
  cmdRemoveContact: 'REMOVE_CONTACT',
  cmdShareContact: 'SHARE_CONTACT',
  cmdExportContact: 'EXPORT_CONTACT',
  cmdImportContact: 'IMPORT_CONTACT',
  cmdReboot: 'REBOOT',
  cmdGetBattAndStorage: 'GET_BATT_AND_STORAGE',
  cmdSetTuningParams: 'SET_TUNING_PARAMS',
  cmdDeviceQuery: 'DEVICE_QUERY',
  cmdExportPrivateKey: 'EXPORT_PRIVATE_KEY',
  cmdImportPrivateKey: 'IMPORT_PRIVATE_KEY',
  cmdSendRawData: 'SEND_RAW_DATA',
  cmdSendLogin: 'SEND_LOGIN',
  cmdSendStatusReq: 'SEND_STATUS_REQ',
  cmdHasConnection: 'HAS_CONNECTION',
  cmdLogout: 'LOGOUT',
  cmdGetContactByKey: 'GET_CONTACT_BY_KEY',
  cmdGetChannel: 'GET_CHANNEL',
  cmdSetChannel: 'SET_CHANNEL',
  cmdSignStart: 'SIGN_START',
  cmdSignData: 'SIGN_DATA',
  cmdSignFinish: 'SIGN_FINISH',
  cmdSendTracePath: 'SEND_TRACE_PATH',
  cmdSetDevicePin: 'SET_DEVICE_PIN',
  cmdSetOtherParams: 'SET_OTHER_PARAMS',
  cmdSendTelemetryReq: 'SEND_TELEMETRY_REQ',
  cmdGetCustomVars: 'GET_CUSTOM_VARS',
  cmdSetCustomVar: 'SET_CUSTOM_VAR',
  cmdGetAdvertPath: 'GET_ADVERT_PATH',
  cmdGetTuningParams: 'GET_TUNING_PARAMS',
  cmdSendBinaryReq: 'SEND_BINARY_REQ',
  cmdFactoryReset: 'FACTORY_RESET',
  cmdSendPathDiscoveryReq: 'SEND_PATH_DISCOVERY_REQ',
  cmdSetFloodScope: 'SET_FLOOD_SCOPE_KEY',
  cmdSendControlData: 'SEND_CONTROL_DATA',
  cmdGetStats: 'GET_STATS',
  cmdSendAnonReq: 'SEND_ANON_REQ',
  cmdSetAutoAddConfig: 'SET_AUTOADD_CONFIG',
  cmdGetAutoAddConfig: 'GET_AUTOADD_CONFIG',
  cmdGetAllowedRepeatFreq: 'GET_ALLOWED_REPEAT_FREQ',
  cmdSetPathHashMode: 'SET_PATH_HASH_MODE',
  cmdSendChannelData: 'SEND_CHANNEL_DATA',
  cmdSetDefaultFloodScope: 'SET_DEFAULT_FLOOD_SCOPE',
  cmdGetDefaultFloodScope: 'GET_DEFAULT_FLOOD_SCOPE',
  cmdSendRawPacket: 'SEND_RAW_PACKET',
  cmdRunCliCommand: 'RUN_CLI_COMMAND',
};

String _cmdName(int cmd) => _cmdNames[cmd] ?? 'CMD_$cmd';

void main(List<String> args) async {
  late _Endpoint upstream;
  String? logPath;
  final rules = <int, _Rule>{};
  final rewrites = <int, Uint8List>{};
  int? rewriteFw;
  var verbose = false;

  String? nextArg(int i, String flag) {
    if (i + 1 >= args.length) _die('$flag needs a value');
    return args[i + 1];
  }

  int parseIntArg(String raw) => raw.startsWith('0x')
      ? int.parse(raw.substring(2), radix: 16)
      : int.parse(raw);

  _Rule rule(int cmd) =>
      rules.putIfAbsent(cmd, () => _Rule(null, false, null, false, false));

  var listenArg = '127.0.0.1:15000';
  String? upstreamArg;
  for (var i = 0; i < args.length; i++) {
    final flag = args[i];
    switch (flag) {
      case '--listen':
        listenArg = nextArg(i++, flag)!;
      case '--upstream':
        upstreamArg = nextArg(i++, flag);
      case '--log':
        logPath = nextArg(i++, flag);
      case '--delay-reply':
        final v = nextArg(i++, flag)!;
        final eq = v.indexOf('=');
        rule(parseIntArg(v.substring(0, eq))).delayMs =
            int.parse(v.substring(eq + 1));
      case '--drop-reply':
        rule(parseIntArg(nextArg(i++, flag)!)).drop = true;
      case '--drop-reply-nth':
        final v = nextArg(i++, flag)!;
        final eq = v.indexOf('=');
        rule(parseIntArg(v.substring(0, eq))).dropNth =
            int.parse(v.substring(eq + 1));
      case '--inject-err':
        final v = nextArg(i++, flag)!;
        final eq = v.indexOf('=');
        rule(parseIntArg(v.substring(0, eq))).errCode =
            int.parse(v.substring(eq + 1));
      case '--truncate-reply':
        rule(parseIntArg(nextArg(i++, flag)!)).truncate = true;
      case '--close-after':
        rule(parseIntArg(nextArg(i++, flag)!)).closeAfter = true;
      case '--set-fw':
        rewriteFw = int.parse(nextArg(i++, flag)!);
      case '--rewrite-reply':
        final v = nextArg(i++, flag)!;
        final eq = v.indexOf('=');
        rewrites[parseIntArg(v.substring(0, eq))] =
            Uint8List.fromList(_hex(v.substring(eq + 1)));
      case '--verbose':
        verbose = true;
      case '-h':
      case '--help':
        stdout.writeln('see tool/hil_relay.dart header');
        exit(0);
      default:
        _die('unknown argument "$flag"');
    }
  }
  if (upstreamArg == null) _die('--upstream is required');
  upstream = _Endpoint(upstreamArg);
  final sink =
      logPath == null ? null : File(logPath).openWrite(mode: FileMode.append);
  void log(Map<String, Object?> entry) {
    if (sink == null) return;
    entry['t'] = DateTime.now().toUtc().toIso8601String();
    sink.writeln(jsonEncode(entry));
  }

  final listenParts = listenArg.split(':');
  final server =
      await ServerSocket.bind(listenParts[0], int.parse(listenParts[1]));
  stdout.writeln('relay listening on ${server.address.host}:${server.port} '
      '-> ${upstream.host}:${upstream.port}');

  await for (final client in server) {
    unawaited(
        _serve(client, upstream, log, rules, rewrites, rewriteFw, verbose));
  }
}

Never _die(String message) {
  stderr.writeln('hil_relay: $message');
  exit(2);
}

Future<void> _serve(
  Socket client,
  _Endpoint upstream,
  void Function(Map<String, Object?>) log,
  Map<int, _Rule> rules,
  Map<int, Uint8List> rewrites,
  int? rewriteFw,
  bool verbose,
) async {
  Socket device;
  try {
    device = await Socket.connect(upstream.host, upstream.port,
        timeout: const Duration(seconds: 10));
  } catch (e) {
    stderr.writeln('hil_relay: upstream connect failed: $e');
    await client.close();
    return;
  }
  client.setOption(SocketOption.tcpNoDelay, true);
  device.setOption(SocketOption.tcpNoDelay, true);
  log({'event': 'client_connected', 'peer': client.remoteAddress.host});

  final appCodec = SerialFrameCodec(direction: FrameDirection.inbound);
  final devCodec = SerialFrameCodec(direction: FrameDirection.outbound);
  final pending = <int>[];
  var lastCliSensitive = false;
  var closed = false;
  final held = <Timer>[];

  void sendToApp(List<int> payload) {
    if (closed) return;
    client.add(appCodec.encodeFrame(payload, prefix: frameOutboundPrefix));
  }

  void closeAll() {
    if (closed) return;
    closed = true;
    for (final t in held) {
      t.cancel();
    }
    unawaited(client.close());
    unawaited(device.close());
    log({'event': 'client_closed'});
  }

  client.listen((data) {
    for (final frame in appCodec.ingest(data)) {
      if (frame.isEmpty) continue;
      final cmd = frame[0];
      pending.add(cmd);
      final payload = Uint8List.fromList(frame);
      Map<String, Object?> entry = {
        'dir': 'app>dev',
        'cmd': cmd,
        'name': _cmdName(cmd),
        'len': frame.length,
      };
      if (cmd == cmdImportPrivateKey) {
        entry['redacted'] = 'private-key';
      } else if (cmd == cmdRunCliCommand) {
        final text = utf8.decode(frame.sublist(1), allowMalformed: true);
        lastCliSensitive = text.contains('wifi');
        entry['text'] = lastCliSensitive ? 'REDACTED' : text;
        if (lastCliSensitive) entry['redacted'] = 'wifi';
      } else if (cmd == cmdSetChannel) {
        entry['index'] = frame.length > 1 ? frame[1] : null;
        entry['name'] =
            frame.length >= 33 ? _cstring(frame.sublist(2, 33)) : null;
        entry['redacted'] = 'channel-psk';
      } else {
        entry['hex'] = bytesToHex(payload);
      }
      log(entry);
      if (verbose) {
        stdout.writeln('app>dev ${entry['name']} len=${frame.length}');
      }
      device.add(appCodec.encodeFrame(frame, prefix: frameInboundPrefix));
    }
  }, onDone: closeAll, onError: (_) => closeAll(), cancelOnError: true);

  device.listen((data) {
    for (final frame in devCodec.ingest(data)) {
      if (frame.isEmpty) continue;
      final code = frame[0];
      int? matchedCmd;
      if (code < 0x80) {
        // Match the oldest pending command whose reply set contains this code.
        for (var i = 0; i < pending.length; i++) {
          final candidate = pending[i];
          if (_replyCodes[candidate]?.contains(code) ?? false) {
            matchedCmd = candidate;
            pending.removeAt(i);
            break;
          }
          // ERR/DISABLED replies can belong to any pending command.
          if (code == respCodeErr || code == respCodeDisabled) {
            matchedCmd = candidate;
            pending.removeAt(i);
            break;
          }
        }
      }
      final rule = matchedCmd == null ? null : rules[matchedCmd];
      Map<String, Object?> entry = {
        'dir': 'dev>app',
        'code': code,
        'cmd': matchedCmd,
        'name': matchedCmd == null ? null : _cmdName(matchedCmd),
        'len': frame.length,
      };
      if (code == respCodePrivateKey) {
        entry['redacted'] = 'private-key';
      } else if (code == respCodeCliReply) {
        final text = utf8.decode(frame.sublist(1), allowMalformed: true);
        if (lastCliSensitive) {
          entry['text'] = 'REDACTED';
          entry['redacted'] = 'wifi';
        } else {
          entry['text'] = text;
        }
      } else {
        entry['hex'] = bytesToHex(frame);
      }
      if (rule != null) {
        entry['fault'] = {
          if (rule.delayMs != null) 'delayMs': rule.delayMs,
          if (rule.drop) 'drop': true,
          if (rule.errCode != null) 'err': rule.errCode,
          if (rule.truncate) 'truncate': true,
          if (rule.closeAfter) 'closeAfter': true,
        };
      }
      log(entry);
      if (verbose) {
        stdout.writeln(
            'dev>app ${matchedCmd == null ? 'push/other' : _cmdName(matchedCmd)} '
            'code=0x${code.toRadixString(16)} len=${frame.length}');
      }
      if (rule != null) {
        rule.seen++;
        if (rule.drop || (rule.dropNth != null && rule.seen == rule.dropNth)) {
          entry['dropped'] = true;
          continue;
        }
      }

      List<int> outgoing = frame;
      if (rewrites.containsKey(matchedCmd)) {
        outgoing = rewrites[matchedCmd]!;
        entry['rewritten'] = bytesToHex(outgoing);
      } else if (rule?.errCode != null) {
        outgoing = [respCodeErr, rule!.errCode!];
      } else if (rule?.truncate ?? false) {
        outgoing = frame.sublist(0, 1);
      } else if (rewriteFw != null && code == respCodeDeviceInfo) {
        final copy = Uint8List.fromList(frame);
        if (copy.length > 1) copy[1] = rewriteFw;
        outgoing = copy;
        entry['rewritten'] = bytesToHex(outgoing);
      }

      void deliver() {
        sendToApp(outgoing);
        if (rule?.closeAfter ?? false) {
          log({'event': 'fault_close_after', 'cmd': matchedCmd});
          closeAll();
        }
      }

      if (rule?.delayMs != null) {
        final timer = Timer(Duration(milliseconds: rule!.delayMs!), deliver);
        held.add(timer);
      } else {
        deliver();
      }
    }
  }, onDone: closeAll, onError: (_) => closeAll(), cancelOnError: true);
}

List<int> _hex(String input) {
  final clean = input.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.length.isOdd) throw FormatException('odd hex: $input');
  return [
    for (var i = 0; i < clean.length; i += 2)
      int.parse(clean.substring(i, i + 2), radix: 16),
  ];
}

String _cstring(List<int> bytes) {
  final end = bytes.indexOf(0);
  return String.fromCharCodes(end >= 0 ? bytes.sublist(0, end) : bytes).trim();
}
