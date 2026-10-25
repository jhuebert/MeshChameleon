import 'dart:convert';
import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

var _seed = 60;

Future<(MeshNode, FakeDeviceLink)> _makeNode({
  int firmwareVerCode = 14,
  int maxTxPower = 30,
  RadioParams? radioParams,
}) async {
  final id = await LocalIdentity.fromSeed(Uint8List(32)..[0] = _seed++);
  final link = FakeDeviceLink(
    deviceInfo_: DeviceInfo(firmwareVerCode: firmwareVerCode),
    radioParams_: radioParams ??
        const RadioParams(
          frequencyHz: 915000000,
          bandwidthHz: 250000,
          spreadingFactor: 10,
          codingRate: 5,
          txPowerDbm: 20,
        ),
    maxTxPower: maxTxPower,
  );
  final node = MeshNode(
    identity: id,
    link: link,
    physical: PhysicalCapabilities(
      firmwareVerCode: firmwareVerCode,
      maxTxPower: maxTxPower,
    ),
    store: InMemoryNodeStore(),
  );
  await node.load();
  return (node, link);
}

void main() {
  test('R3 table covers every standard CLI target', () {
    const cases = <String, CliTarget>{
      'get name': CliTarget.virtual,
      'set name Bob': CliTarget.virtual,
      'get path.hash.mode': CliTarget.virtual,
      'set path.hash.mode 1': CliTarget.virtual,
      'get multi.acks': CliTarget.virtual,
      'set multi.acks 2': CliTarget.virtual,
      'get tz.offset': CliTarget.virtual,
      'set tz.offset -3': CliTarget.virtual,
      'board': CliTarget.virtual,
      'ver': CliTarget.virtual,
      'get radio': CliTarget.physical,
      'set radio 915.0,250.0,10,5': CliTarget.physical,
      'get freq': CliTarget.physical,
      'get tx': CliTarget.physical,
      'get tx suffix': CliTarget.physical,
      'set tx 17': CliTarget.physical,
      'get af': CliTarget.physical,
      'set af 1.5': CliTarget.physical,
      'get dutycycle': CliTarget.physical,
      'set dutycycle 10': CliTarget.physical,
      'get rxdelay': CliTarget.physical,
      'set rxdelay 1': CliTarget.physical,
      'get int.thresh': CliTarget.physical,
      'set int.thresh 10': CliTarget.physical,
      'get cad': CliTarget.physical,
      'set cad on': CliTarget.physical,
      'get radio.rxgain': CliTarget.physical,
      'set radio.rxgain off': CliTarget.physical,
      'get agc.reset.interval': CliTarget.physical,
      'set agc.reset.interval 8': CliTarget.physical,
      'get txdelay': CliTarget.physical,
      'set txdelay 0.5': CliTarget.physical,
      'get direct.txdelay': CliTarget.physical,
      'set direct.txdelay 0.5': CliTarget.physical,
      'get wifi.ssid': CliTarget.physical,
      'set wifi.ssid My Net': CliTarget.physical,
      'get wifi.pwd': CliTarget.physical,
      'set wifi.pwd pass word': CliTarget.physical,
      'get wifi.enabled': CliTarget.physical,
      'set wifi.enabled 1': CliTarget.physical,
      'set wifi.clear': CliTarget.physical,
      'get wifi.status': CliTarget.physical,
      'get wifi.ip': CliTarget.physical,
      'reboot': CliTarget.lifecycle,
      'poweroff': CliTarget.lifecycle,
      'shutdown': CliTarget.lifecycle,
      'set pin 1234': CliTarget.disabled,
      'erase': CliTarget.disabled,
      'reset': CliTarget.disabled,
      'factory_reset': CliTarget.disabled,
      'factory reset': CliTarget.disabled,
      'adv_int 0': CliTarget.unknown,
      'get fem_rxgain': CliTarget.unknown,
      'set comp.foo 1': CliTarget.unknown,
      'get private.key': CliTarget.unknown,
    };
    for (final entry in cases.entries) {
      expect(CliParser.parseText(entry.key).target, entry.value,
          reason: entry.key);
    }
  });

  test('remote policy denies physical administration but allows virtual CLI',
      () {
    expect(
      CliRemotePolicy.denialFor(CliParser.parseText('set name Remote')),
      isNull,
    );
    expect(
      CliRemotePolicy.denialFor(CliParser.parseText('set radio 915,250,10,5')),
      'Error: physical administration disabled',
    );
    expect(
      CliRemotePolicy.denialFor(CliParser.parseText('reboot')),
      'Error: physical administration disabled',
    );
    expect(
      CliRemotePolicy.denialFor(CliParser.parseText('set pin 1234')),
      'Error: disabled',
    );
    expect(
      CliRemotePolicy.denialFor(CliParser.parseText('adv_int 0')),
      'Unknown command',
    );
  });

  test('binary_cli_name_path_multiack_agree_and_never_touch_physical',
      () async {
    final (node, link) = await _makeNode();
    await node.setAdvertName('Binary Name');
    await node.setPathHashMode(2);
    await node.setMultiAcks(3);
    await node.setTimezoneOffsetHours(-5);

    expect(await node.runCliCommand('get name'), '> Binary Name');
    expect(await node.runCliCommand('get path.hash.mode'), '> 2');
    expect(await node.runCliCommand('get multi.acks'), '> 3');
    expect(await node.runCliCommand('get tz.offset'), '> -5');

    expect(await node.runCliCommand('set name Cli Name'), 'OK');
    expect(await node.runCliCommand('set path.hash.mode 1'), 'OK');
    expect(await node.runCliCommand('set multi.acks 4'), 'OK');
    expect(await node.runCliCommand('set tz.offset 7'), 'OK');
    expect(node.prefs.nodeName, 'Cli Name');
    expect(node.prefs.pathHashMode, 1);
    expect(node.prefs.multiAcks, 4);
    expect(node.prefs.timezoneOffsetHours, 7);

    expect(await node.runCliCommand('set name Bad:Name'), 'Error, bad chars');
    expect(await node.runCliCommand('set path.hash.mode 3'),
        'Error, must be 0,1, or 2');
    expect(await node.runCliCommand('set tz.offset 15'),
        'Error, must be from -12 to +14');
    expect(link.calls, isEmpty);
  });

  test('leading_spaces_and_prefix_cannot_bypass_pin_reset_unknown_denial',
      () async {
    final (node, link) = await _makeNode();
    expect(await node.runCliCommand('set name Prefix Name'), 'OK');
    expect(
      await node.runCliCommandBytes(
        Uint8List.fromList([...utf8.encode('  AB|set pin 1234'), 0]),
      ),
      'AB|Error: disabled',
    );
    expect(
        await node.runCliCommand('  AB|factory reset'), 'AB|Error: disabled');
    expect(await node.runCliCommand('AB| erase'), 'AB|Error: disabled');
    expect(await node.runCliCommand('  set pin 1234'), 'Error: disabled');
    expect(await node.runCliCommand('AB|ver'), 'AB|$virtualCliVersion');
    expect(await node.runCliCommand('AB| get name'), 'AB|> Prefix Name');
    expect(await node.runCliCommand('AB|ADV_INT 0'), 'AB|Unknown command');
    expect(await node.runCliCommand('AB|set private.key 00'),
        'AB|Unknown command');
    final prefixed = await node.runCliCommand('AB|ver');
    expect(prefixed!.indexOf('AB|', 1), -1, reason: 'prefix echoed once');
    expect(link.calls, isEmpty);
  });

  test('newlines_nul_nan_infinity_trailing_garbage_rejected_no_device_calls',
      () async {
    final (node, link) = await _makeNode();
    final invalidPayloads = <List<int>>[
      utf8.encode('ver\n'),
      utf8.encode('ver\r'),
      [...utf8.encode('ver'), 0, 0],
      [...utf8.encode('ver'), 0x1B],
      [...utf8.encode('ver'), 0xC3],
    ];
    for (final payload in invalidPayloads) {
      expect(
        await node.runCliCommandBytes(Uint8List.fromList(payload)),
        'Error: illegal argument',
      );
    }
    expect(
      await node.runCliCommandBytes(
        Uint8List.fromList([...utf8.encode('AB|ver'), 0, 0]),
      ),
      'AB|Error: illegal argument',
      reason: 'recover the correlation prefix on malformed input',
    );
    final invalidCommands = [
      'set tx NaN',
      'set tx Infinity',
      'set tx 5x',
      'set tx  5',
      'set radio 915,250,10,5x',
      'set radio 915,250,10,5,',
      'set af 1.2.3',
      'set cad onx',
      'set wifi.enabled 2',
      'set int.thresh 256',
      'set path.hash.mode 3',
      'set tz.offset 15',
    ];
    for (final command in invalidCommands) {
      final reply = await node.runCliCommand(command);
      expect(reply, isNot('OK'), reason: command);
    }
    expect(link.cliCommands, isEmpty);
    expect(link.calls.where((c) => c == 'selfInfo' || c == 'tuningParams'),
        isEmpty);
  });

  test('wifi_commands_hit_device_not_host_and_preserve_password_spaces',
      () async {
    final (node, link) = await _makeNode();
    final commands = <String, String>{
      'set wifi.ssid My  Network  ': '> wifi.ssid is now My  Network',
      'set wifi.pwd  correct  horse  battery  ':
          '> wifi.pwd updated (reboot to apply)',
      'get wifi.pwd': '>  correct  horse  battery  ',
      'set wifi.enabled 1': '> wifi.enabled is now 1 (reboot to apply)',
      'get wifi.enabled': '> 1',
      'set wifi.clear': '> wifi config cleared (reboot to apply)',
      'get wifi.status': '> connected',
      'get wifi.ip': '> 192.0.2.7',
    };
    for (final entry in commands.entries) {
      link.cliReply = entry.value;
      expect(await node.runCliCommand(entry.key), entry.value);
      expect(link.cliCommands.last, entry.key);
    }
    expect(node.prefs.nodeName, 'MeshChameleon');
    expect(
      link.calls.where((c) =>
          c != 'runCliCommand' && c != 'selfInfo' && c != 'tuningParams'),
      isEmpty,
    );
  });

  test('get_wifi_pwd_allowed_no_password_in_log_or_diagnostic_cache', () async {
    final (node, link) = await _makeNode();
    link.cliReply = '> first super secret';
    expect(await node.runCliCommand('get wifi.pwd'), '> first super secret');
    expect(node.physicalDiagnostic, isNull);

    link.cliReply = '> second super secret';
    expect(await node.runCliCommand('get wifi.pwd'), '> second super secret',
        reason: 'passwords are not cached');
    expect(node.physicalDiagnostic, isNull);
  });

  test('physical_fw13_denies_physical_cli_but_virtual_cli_works', () async {
    final (node, link) = await _makeNode(firmwareVerCode: 13);
    expect(await node.runCliCommand('ver'), virtualCliVersion);
    expect(await node.runCliCommand('get name'), '> MeshChameleon');
    expect(await node.runCliCommand('set name Still Virtual'), 'OK');
    expect(node.prefs.nodeName, 'Still Virtual');
    expect(await node.runCliCommand('get radio'), 'Error: unsupported');
    expect(await node.runCliCommand('set radio 920,125,11,6'),
        'Error: unsupported');
    expect(link.cliCommands, isEmpty);
    expect(link.calls, isEmpty);
  });

  test('cli_radio_tx_tuning_refresh_only_physical_cache', () async {
    const initialRadio = RadioParams(
      frequencyHz: 915000000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
      txPowerDbm: 20,
    );
    final (node, link) = await _makeNode(radioParams: initialRadio);
    node.syncRadioParams(initialRadio);
    await link.setTuningParams(
      const TuningParams(rxDelayBaseMs: 7, airtimeFactorMs: 3),
    );
    await node.setAdvertName('Virtual Name');
    await node.setPathHashMode(2);
    await node.setMultiAcks(3);
    await node.setTimezoneOffsetHours(5);
    link.calls.clear();

    link.cliReply = 'OK - reboot to apply';
    expect(await node.runCliCommand('set radio 920.0,125.0,11,6'),
        'OK - reboot to apply');
    expect(link.cliCommands.last, 'set radio 920.0,125.0,11,6');
    expect(link.calls.where((c) => c == 'selfInfo').length, 1);
    expect(link.calls, isNot(contains('setRadioParams')));
    expect(node.prefs.frequencyHz, 915000000,
        reason: 'readback reflects active, not saved-only, RF');
    expect(node.prefs.spreadingFactor, 10);
    expect(node.physicalRadioRequiresReboot, isTrue);
    expect(node.radioRequiresReboot, isTrue);

    link.cliReply = 'OK';
    expect(await node.runCliCommand('set tx 17'), 'OK');
    expect(link.cliCommands.last, 'set tx 17');
    expect(link.calls, isNot(contains('setTxPower')));
    expect(node.prefs.txPowerDbm, 20,
        reason: 'SELF_INFO readback is authoritative');

    link.cliReply = 'OK';
    expect(await node.runCliCommand('set af 2.5'), 'OK');
    expect(link.cliCommands.last, 'set af 2.5');
    expect(link.calls, isNot(contains('setTuningParams')));
    expect(node.prefs.rxDelayBaseMs, 7);
    expect(node.prefs.airtimeFactorMs, 3);

    link.cliReply = '> 915.000,250.000,10,5';
    expect(await node.runCliCommand('get radio'), '> 915.000,250.000,10,5');
    link.cliReply = '> 20';
    expect(await node.runCliCommand('get tx suffix'), '> 20');
    expect(link.cliCommands[link.cliCommands.length - 1], 'get tx suffix');
    link.cliReply = '> 7.0';
    expect(await node.runCliCommand('get af'), '> 7.0');

    expect(node.prefs.nodeName, 'Virtual Name');
    expect(node.prefs.pathHashMode, 2);
    expect(node.prefs.multiAcks, 3);
    expect(node.prefs.timezoneOffsetHours, 5);
    expect(link.calls, isNot(contains('setRadioParams')));
    expect(link.calls, isNot(contains('setTxPower')));
    expect(link.calls, isNot(contains('setTuningParams')));
  });

  test('physical_cli_error_reply_keeps_cache_and_is_not_rewritten_ok',
      () async {
    const initialRadio = RadioParams(
      frequencyHz: 915000000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
      txPowerDbm: 20,
    );
    final (node, link) = await _makeNode(radioParams: initialRadio);
    node.syncRadioParams(initialRadio);
    await link.setTuningParams(
      const TuningParams(rxDelayBaseMs: 7, airtimeFactorMs: 3),
    );
    link.calls.clear();

    link.cliReply = 'Error, invalid radio params';
    final radioReply = await node.runCliCommand('set radio 920.0,125.0,11,6');
    expect(radioReply, 'Error, invalid radio params');
    expect(node.prefs.frequencyHz, 915000000);
    expect(node.prefs.spreadingFactor, 10);
    expect(node.physicalRadioRequiresReboot, isFalse);
    expect(link.calls, isNot(contains('setRadioParams')));

    link.cliReply = 'ERROR: af must be 0-9';
    final tuningReply = await node.runCliCommand('set af 2.5');
    expect(tuningReply, 'ERROR: af must be 0-9');
    expect(node.prefs.rxDelayBaseMs, 7);
    expect(node.prefs.airtimeFactorMs, 3);
    expect(link.calls, isNot(contains('setTuningParams')));
  });

  test('cli_reply_max_bytes_utf8_and_correlation_prefix_once', () async {
    final (node, link) = await _makeNode();
    link.cliReply = 'é' * 200;
    final reply = await node.runCliCommandBytes(
      Uint8List.fromList(utf8.encode('AB|get wifi.ssid')),
    );
    expect(reply.startsWith('AB|'), isTrue);
    expect(reply.indexOf('AB|', 1), -1);
    expect(utf8.encode(reply).length, lessThanOrEqualTo(175));
    expect(reply.endsWith('...'), isTrue);
    expect(link.cliCommands.single, 'get wifi.ssid');

    link.cliReply = '> ${'p' * 200}';
    final secret = await node.runCliCommandBytes(
      Uint8List.fromList(utf8.encode('AB|get wifi.pwd')),
    );
    expect(secret, 'AB|Error: response too large');
    expect(secret, isNot(contains('p' * 10)));

    expect(await node.runCliCommand('AB|not-a-command'), 'AB|Unknown command');
    expect(await node.runCliCommand('AB|not-a-command'), 'AB|Unknown command');
  });
}
