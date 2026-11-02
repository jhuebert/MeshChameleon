import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  late NodePrefs prefs;
  late _Host host;
  late _ErrorLink link;
  late PhysicalRadio radio;
  late CliRuntime cli;

  setUp(() {
    prefs = NodePrefs(nodeName: 'Virtual', pathHashMode: 1, multiAcks: 2);
    host = _Host();
    link = _ErrorLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 14),
    );
    radio = PhysicalRadio(
      link: link,
      prefs: prefs,
      capabilities: const PhysicalCapabilities(
        firmwareVerCode: 14,
        maxTxPower: 30,
      ),
      onPersist: () {},
      onConfigChanged: () {},
    );
    cli = CliRuntime(prefs: prefs, radio: radio, host: host);
  });

  test('runText reports malformed control characters with the prefix',
      () async {
    expect(
      await cli.runText('AB|bad\u0001command'),
      'AB|Error: illegal argument',
    );
    expect(
      await cli.runText('bad\u007fcommand'),
      'Error: illegal argument',
    );
  });

  test('runBytes reports malformed control bytes with the prefix', () async {
    expect(
      await cli.runBytes(Uint8List.fromList([0x41, 0x42, 0x7C, 0x01])),
      'AB|Error: illegal argument',
    );
  });

  test('virtual commands read and update node preferences', () async {
    expect(await cli.runVirtualCommand('get name'), '> Virtual');
    expect(await cli.runVirtualCommand('get path.hash.mode'), '> 1');
    expect(await cli.runVirtualCommand('get multi.acks'), '> 2');
    expect(await cli.runVirtualCommand('get tz.offset'), '> 0');
    expect(await cli.runVirtualCommand('board'), virtualBoardName);
    expect(await cli.runVirtualCommand('ver'), virtualCliVersion);

    expect(await cli.runVirtualCommand('set name New Name'), 'OK');
    expect(host.names, ['New Name']);
    expect(await cli.runVirtualCommand('set path.hash.mode 2'), 'OK');
    expect(host.pathHashModes, [2]);
    expect(await cli.runVirtualCommand('set multi.acks 3'), 'OK');
    expect(host.multiAcks, [3]);
    expect(await cli.runVirtualCommand('set tz.offset -5'), 'OK');
    expect(host.timezones, [-5]);

    expect(await cli.runVirtualCommand('unknown'), 'Unknown command');
  });

  test('virtual setters validate their arguments before mutating', () async {
    expect(await cli.runVirtualCommand('set name '), 'Error, bad chars');
    expect(await cli.runVirtualCommand('set name a:b'), 'Error, bad chars');
    expect(
      await cli.runVirtualCommand('set name ${'a' * 32}'),
      'Error, bad chars',
    );
    expect(
      await cli.runVirtualCommand('set name bad\u0001'),
      'Error, bad chars',
    );
    expect(
      await cli.runVirtualCommand('set path.hash.mode 3'),
      'Error, must be 0,1, or 2',
    );
    expect(
      await cli.runVirtualCommand('set path.hash.mode abc'),
      'Error, must be 0,1, or 2',
    );
    expect(
      await cli.runVirtualCommand('set multi.acks 256'),
      'Error: illegal argument',
    );
    expect(
      await cli.runVirtualCommand('set multi.acks -1'),
      'Error: illegal argument',
    );
    expect(
      await cli.runVirtualCommand('set tz.offset 15'),
      'Error, must be from -12 to +14',
    );
    expect(
      await cli.runVirtualCommand('set tz.offset -13'),
      'Error, must be from -12 to +14',
    );
    expect(host.names, isEmpty);
    expect(host.pathHashModes, isEmpty);
    expect(host.multiAcks, isEmpty);
    expect(host.timezones, isEmpty);
  });

  test('virtual host errors are mapped to companion error text', () async {
    host.error = const CompanionOperationError(errCodeTableFull);
    expect(await cli.runText('set name Fine'), 'Error: storage failure');

    host.error = const CompanionOperationError(errCodeBadState);
    expect(await cli.runText('set name Fine'), 'Error: device unavailable');

    host.error = const CompanionOperationError(errCodeIllegalArg);
    expect(await cli.runText('set name Fine'), 'Error: illegal argument');

    host.error = const CompanionOperationError(errCodeUnsupportedCmd);
    expect(await cli.runText('set name Fine'), 'Error: unsupported');
  });

  test('lifecycle commands use the host and map failures', () async {
    expect(await cli.runText('shutdown'), 'OK');
    expect(host.shutdowns, 1);

    expect(await cli.runText('poweroff'), 'OK');
    expect(host.shutdowns, 2);

    host.error = const CompanionOperationError(errCodeBadState);
    expect(await cli.runText('reboot'), 'Error: device unavailable');
    expect(host.reboots, 0);
  });

  test('operationErrorText covers disabled and every error code', () {
    expect(
      cli.operationErrorText(
        const CompanionOperationError(errCodeFileIoError),
      ),
      'Error: storage failure',
    );
    expect(
      cli.operationErrorText(
        const CompanionOperationError(errCodeTableFull),
      ),
      'Error: storage failure',
    );
    expect(
      cli.operationErrorText(
        const CompanionOperationError(errCodeBadState),
      ),
      'Error: device unavailable',
    );
    expect(
      cli.operationErrorText(
        const CompanionOperationError(errCodeIllegalArg),
      ),
      'Error: illegal argument',
    );
    expect(
      cli.operationErrorText(
        const CompanionOperationError(errCodeNotFound),
      ),
      'Error: unsupported',
    );
    expect(
      cli.operationErrorText(
        const CompanionOperationError(errCodeIllegalArg, disabled: true),
      ),
      'Error: disabled',
    );
  });

  test('deviceErrorText covers every kind and device error code', () {
    expect(
      cli.deviceErrorText(const DeviceCommandError.disabled()),
      'Error: disabled',
    );
    for (final error in [
      const DeviceCommandError.timeout(),
      const DeviceCommandError.disconnected(),
      const DeviceCommandError.malformed(),
    ]) {
      expect(cli.deviceErrorText(error), 'Error: device unavailable');
    }

    final byCode = <int, String>{
      errCodeIllegalArg: 'Error: illegal argument',
      errCodeUnsupportedCmd: 'Error: unsupported',
      errCodeFileIoError: 'Error: storage failure',
      errCodeBadState: 'Error: device unavailable',
      errCodeNotFound: 'Error: device error',
    };
    for (final entry in byCode.entries) {
      expect(
        cli.deviceErrorText(DeviceCommandError.device(entry.key)),
        entry.value,
      );
    }
  });

  test('physical commands report device and operation failures', () async {
    link.cliError = const DeviceCommandError.timeout(message: 'timed out');
    expect(await cli.runText('get radio'), 'Error: device unavailable');
    expect(radio.diagnostic, 'timed out');
    expect(radio.cacheUncertain, isTrue);

    link.cliError = null;
    link.operationError =
        const CompanionOperationError(errCodeFileIoError, message: 'io');
    expect(await cli.runText('get radio'), 'Error: storage failure');
    expect(radio.diagnostic, 'io');
  });

  test('physical commands reject invalid arguments and old firmware', () async {
    expect(await cli.runText('set tx not-a-number'), 'Error: illegal argument');

    final oldLink = _ErrorLink(
      deviceInfo_: const DeviceInfo(firmwareVerCode: 12),
    );
    final oldRadio = PhysicalRadio(
      link: oldLink,
      prefs: prefs,
      capabilities: const PhysicalCapabilities(firmwareVerCode: 12),
      onPersist: () {},
      onConfigChanged: () {},
    );
    final oldCli = CliRuntime(prefs: prefs, radio: oldRadio, host: host);
    expect(await oldCli.runText('get radio'), 'Error: unsupported');
  });
}

class _Host implements CliHost {
  CompanionOperationError? error;
  final names = <String>[];
  final pathHashModes = <int>[];
  final multiAcks = <int>[];
  final timezones = <int>[];
  int reboots = 0;
  int shutdowns = 0;

  void _check() {
    if (error != null) throw error!;
  }

  @override
  Future<void> setAdvertName(String name) async {
    _check();
    names.add(name);
  }

  @override
  Future<void> setPathHashMode(int mode) async {
    _check();
    pathHashModes.add(mode);
  }

  @override
  Future<void> setMultiAcks(int value) async {
    _check();
    multiAcks.add(value);
  }

  @override
  Future<void> setTimezoneOffsetHours(int hours) async {
    _check();
    timezones.add(hours);
  }

  @override
  Future<void> reboot() async {
    _check();
    reboots++;
  }

  @override
  Future<void> shutdown() async {
    _check();
    shutdowns++;
  }
}

class _ErrorLink extends FakeDeviceLink {
  _ErrorLink({super.deviceInfo_});

  DeviceCommandError? cliError;
  CompanionOperationError? operationError;

  @override
  Future<String> runCliCommand(String command) async {
    if (operationError != null) throw operationError!;
    if (cliError != null) throw cliError!;
    return super.runCliCommand(command);
  }
}
