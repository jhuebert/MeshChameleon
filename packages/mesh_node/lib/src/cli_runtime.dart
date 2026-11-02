import 'dart:convert';
import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'cli.dart';
import 'physical_radio.dart';

/// Node operations a CLI invocation can reach.
abstract class CliHost {
  Future<void> setAdvertName(String name);
  Future<void> setPathHashMode(int mode);
  Future<void> setMultiAcks(int value);
  Future<void> setTimezoneOffsetHours(int hours);
  Future<void> reboot();
  Future<void> shutdown();
}

/// Companion CLI parsing, allowlist routing, execution, and reply formatting.
///
/// Virtual commands mutate node state through [host]; physical commands go
/// through [radio] so they share its serialised config transaction and cache
/// reconciliation. Lifecycle commands remain explicit host operations.
class CliRuntime {
  CliRuntime({
    required this.prefs,
    required this.radio,
    required this.host,
  });

  final NodePrefs prefs;
  final PhysicalRadio radio;
  final CliHost host;

  Future<String?> runText(String command) async {
    try {
      return await _route(CliParser.parseText(command));
    } on CliFormatException catch (e) {
      return reply(e.prefix, 'Error: illegal argument');
    }
  }

  Future<String> runBytes(Uint8List payload) async {
    try {
      return await _route(CliParser.parseBytes(payload));
    } on CliFormatException catch (e) {
      return reply(e.prefix, 'Error: illegal argument');
    }
  }

  /// Execute a virtual command without routing (remote CLI).
  Future<String> runVirtualCommand(String command) => _runVirtual(command);

  String reply(String? prefix, String text, {bool secret = false}) =>
      CliParser.boundReply(prefix, text, secret: secret);

  Future<String> _route(CliInvocation invocation) async {
    switch (invocation.target) {
      case CliTarget.unknown:
        return reply(invocation.prefix, 'Unknown command');
      case CliTarget.disabled:
        return reply(invocation.prefix, 'Error: disabled');
      case CliTarget.virtual:
        try {
          final text = await _runVirtual(invocation.command);
          return reply(invocation.prefix, text);
        } on CompanionOperationError catch (e) {
          return reply(invocation.prefix, operationErrorText(e));
        }
      case CliTarget.physical:
        return _runPhysical(invocation);
      case CliTarget.lifecycle:
        try {
          if (invocation.command == 'reboot') {
            await host.reboot();
          } else {
            await host.shutdown();
          }
          return reply(invocation.prefix, 'OK');
        } on CompanionOperationError catch (e) {
          return reply(invocation.prefix, operationErrorText(e));
        }
    }
  }

  String operationErrorText(CompanionOperationError e) {
    if (e.disabled) return 'Error: disabled';
    return switch (e.code) {
      errCodeFileIoError || errCodeTableFull => 'Error: storage failure',
      errCodeBadState => 'Error: device unavailable',
      errCodeIllegalArg => 'Error: illegal argument',
      _ => 'Error: unsupported',
    };
  }

  String deviceErrorText(DeviceCommandError e) => switch (e.kind) {
        DeviceCommandErrorKind.disabled => 'Error: disabled',
        DeviceCommandErrorKind.timeout ||
        DeviceCommandErrorKind.disconnected ||
        DeviceCommandErrorKind.malformed =>
          'Error: device unavailable',
        DeviceCommandErrorKind.device => switch (e.code) {
            errCodeIllegalArg => 'Error: illegal argument',
            errCodeUnsupportedCmd => 'Error: unsupported',
            errCodeFileIoError => 'Error: storage failure',
            errCodeBadState => 'Error: device unavailable',
            _ => 'Error: device error',
          },
      };

  Future<String> _runVirtual(String command) async {
    switch (command) {
      case 'get name':
        return '> ${prefs.nodeName}';
      case 'get path.hash.mode':
        return '> ${prefs.pathHashMode}';
      case 'get multi.acks':
        return '> ${prefs.multiAcks}';
      case 'get tz.offset':
        return '> ${prefs.timezoneOffsetHours}';
      case 'board':
        return virtualBoardName;
      case 'ver':
        return virtualCliVersion;
    }

    if (command.startsWith('set name ')) {
      final name = command.substring(9);
      if (!_validName(name)) return 'Error, bad chars';
      await host.setAdvertName(name);
      return 'OK';
    }
    if (command.startsWith('set path.hash.mode ')) {
      final mode = _strictInt(command.substring(19));
      if (mode == null || mode < 0 || mode > 2) {
        return 'Error, must be 0,1, or 2';
      }
      await host.setPathHashMode(mode);
      return 'OK';
    }
    if (command.startsWith('set multi.acks ')) {
      final value = _strictInt(command.substring(15));
      if (value == null || value < 0 || value > 255) {
        return 'Error: illegal argument';
      }
      await host.setMultiAcks(value);
      return 'OK';
    }
    if (command.startsWith('set tz.offset ')) {
      final hours = _strictInt(command.substring(14));
      if (hours == null || hours < -12 || hours > 14) {
        return 'Error, must be from -12 to +14';
      }
      await host.setTimezoneOffsetHours(hours);
      return 'OK';
    }

    return 'Unknown command';
  }

  bool _validName(String value) {
    if (value.isEmpty || utf8.encode(value).length > 31) return false;
    const forbidden = '[]\\:,?*';
    if (value.runes.any((r) => forbidden.runes.contains(r))) return false;
    return validateAdvertName(value) != null;
  }

  static final RegExp _intPattern = RegExp(r'^[+-]?[0-9]+$');

  int? _strictInt(String value) =>
      _intPattern.hasMatch(value) ? int.tryParse(value) : null;

  Future<String> _runPhysical(CliInvocation invocation) async {
    final CliPhysicalCommand spec;
    try {
      spec = CliPhysicalValidator.validate(
        invocation.command,
        maxTxPower: radio.capabilities.maxTxPower,
      );
    } on CliFormatException {
      return reply(invocation.prefix, 'Error: illegal argument');
    }
    if (radio.capabilities.firmwareVerCode < 14) {
      return reply(invocation.prefix, 'Error: unsupported');
    }

    try {
      final text = await radio.runPhysicalCli(spec);
      return reply(invocation.prefix, text, secret: spec.replyIsSecret);
    } on DeviceCommandError catch (e) {
      radio.recordPhysicalCliFailure(e, spec);
      return reply(invocation.prefix, deviceErrorText(e));
    } on CompanionOperationError catch (e) {
      radio.recordCliOperationFailure(e);
      return reply(invocation.prefix, operationErrorText(e));
    }
  }
}
