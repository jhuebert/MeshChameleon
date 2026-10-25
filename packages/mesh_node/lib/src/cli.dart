import 'dart:convert';
import 'dart:typed_data';

/// Maximum companion CLI reply text, including an optional correlation prefix.
const int maxCliReplyBytes = 175;

/// Where an allowlisted CLI command is executed.
enum CliTarget {
  /// Virtual node state; never touches the attached radio.
  virtual,

  /// Explicitly allowlisted physical firmware CLI command.
  physical,

  /// PIN/factory-reset style destructive command, always denied.
  disabled,

  /// Reboot/shutdown lifecycle (implemented by T12).
  lifecycle,

  /// Not in the standard companion allowlist.
  unknown,
}

/// Strict CLI input/UTF-8 failure.
class CliFormatException implements Exception {
  const CliFormatException(this.message, {this.prefix});
  final String message;

  /// Correlation prefix recoverable before the malformed bytes, if any.
  final String? prefix;

  @override
  String toString() => 'CliFormatException($message)';
}

/// One normalized local CLI invocation.
class CliInvocation {
  const CliInvocation({
    required this.prefix,
    required this.command,
    required this.target,
  });

  /// Exactly two printable ASCII bytes from `AB|...`, or null.
  final String? prefix;

  /// Normalized command without the correlation prefix.
  final String command;

  final CliTarget target;
}

/// Strict parser for the companion `CMD_RUN_CLI_COMMAND` payload.
class CliParser {
  const CliParser._();

  static CliInvocation parseBytes(List<int> payload) {
    var bytes = payload;
    if (bytes.isNotEmpty && bytes.last == 0) {
      bytes = bytes.sublist(0, bytes.length - 1);
    }
    final prefix = _prefixFromBytes(bytes);
    for (final b in bytes) {
      if (b < 0x20 || b == 0x7F) {
        throw CliFormatException(
          'control byte in CLI command',
          prefix: prefix,
        );
      }
    }
    final String text;
    try {
      text = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      throw CliFormatException(
        'CLI command is not valid UTF-8',
        prefix: prefix,
      );
    }
    return _parseDecoded(text, prefix);
  }

  static CliInvocation parseText(String input) {
    final prefix = _prefixFromText(input);
    for (final rune in input.runes) {
      if (rune < 0x20 || rune == 0x7F || (rune >= 0x80 && rune <= 0x9F)) {
        throw CliFormatException(
          'control character in CLI command',
          prefix: prefix,
        );
      }
    }
    return _parseDecoded(input, prefix);
  }

  static CliInvocation _parseDecoded(String input, String? recoveredPrefix) {
    var command = input;
    while (command.startsWith(' ')) {
      command = command.substring(1);
    }

    String? prefix = recoveredPrefix;
    if (command.length >= 4 &&
        _isPrintableAscii(command.codeUnitAt(0)) &&
        _isPrintableAscii(command.codeUnitAt(1)) &&
        command.codeUnitAt(2) == 0x7C) {
      prefix = command.substring(0, 2);
      command = command.substring(3);
      while (command.startsWith(' ')) {
        command = command.substring(1);
      }
    }

    return CliInvocation(
      prefix: prefix,
      command: command,
      target: CliCatalog.targetFor(command),
    );
  }

  static bool _isPrintableAscii(int codeUnit) =>
      codeUnit >= 0x20 && codeUnit <= 0x7E;

  static String? _prefixFromBytes(List<int> bytes) {
    var i = 0;
    while (i < bytes.length && bytes[i] == 0x20) {
      i++;
    }
    if (i + 3 < bytes.length &&
        _isPrintableAscii(bytes[i]) &&
        _isPrintableAscii(bytes[i + 1]) &&
        bytes[i + 2] == 0x7C) {
      return String.fromCharCodes(bytes.sublist(i, i + 2));
    }
    return null;
  }

  static String? _prefixFromText(String input) {
    var i = 0;
    while (i < input.length && input.codeUnitAt(i) == 0x20) {
      i++;
    }
    if (i + 3 < input.length &&
        _isPrintableAscii(input.codeUnitAt(i)) &&
        _isPrintableAscii(input.codeUnitAt(i + 1)) &&
        input.codeUnitAt(i + 2) == 0x7C) {
      return input.substring(i, i + 2);
    }
    return null;
  }

  /// Bound a reply to [maxCliReplyBytes] UTF-8 bytes while keeping the
  /// correlation prefix exactly once.
  ///
  /// Secret replies (WiFi password reads) are never truncated; if they cannot
  /// fit the caller gets a fixed error instead.
  static String boundReply(
    String? prefix,
    String text, {
    bool secret = false,
  }) {
    final marker = prefix == null ? '' : '$prefix|';
    final body =
        prefix != null && text.startsWith(marker) ? text : marker + text;
    final bytes = utf8.encode(body);
    if (bytes.length <= maxCliReplyBytes) return body;
    if (secret) {
      return '${marker}Error: response too large';
    }

    final markerBytes = utf8.encode(marker).length;
    final available = maxCliReplyBytes - markerBytes - 3;
    if (available <= 0) return marker;
    final cut = _utf8Boundary(bytes, available);
    final kept = utf8.decode(bytes.sublist(0, cut));
    return '$kept...';
  }

  static int _utf8Boundary(Uint8List bytes, int limit) {
    var end = limit;
    if (end > bytes.length) end = bytes.length;
    while (end > 0 && end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
      end--;
    }
    return end;
  }
}

/// Complete R3 allowlist. Matching is case-sensitive and exact; arbitrary
/// `get`/`set` prefixes are not accepted.
class CliCatalog {
  const CliCatalog._();

  static const Set<String> _virtualExact = {
    'get name',
    'get path.hash.mode',
    'get multi.acks',
    'get tz.offset',
    'board',
    'ver',
  };

  static const Set<String> _virtualArg = {
    'set name',
    'set path.hash.mode',
    'set multi.acks',
    'set tz.offset',
  };

  static const Set<String> _physicalExact = {
    'get radio',
    'get freq',
    'get af',
    'get dutycycle',
    'get rxdelay',
    'get int.thresh',
    'get cad',
    'get radio.rxgain',
    'get agc.reset.interval',
    'get txdelay',
    'get direct.txdelay',
    'get wifi.ssid',
    'get wifi.pwd',
    'get wifi.enabled',
    'get wifi.status',
    'get wifi.ip',
    'set wifi.clear',
  };

  static const Set<String> _physicalArg = {
    'set radio',
    'set tx',
    'set af',
    'set dutycycle',
    'set rxdelay',
    'set int.thresh',
    'set cad',
    'set radio.rxgain',
    'set agc.reset.interval',
    'set txdelay',
    'set direct.txdelay',
    'set wifi.ssid',
    'set wifi.pwd',
    'set wifi.enabled',
  };

  static const Set<String> _disabledExact = {
    'erase',
    'reset',
    'factory_reset',
    'factory reset',
  };

  static const Set<String> _lifecycle = {
    'reboot',
    'poweroff',
    'shutdown',
  };

  static CliTarget targetFor(String command) {
    if (_virtualExact.contains(command) ||
        _matchesArgPrefix(command, _virtualArg)) {
      return CliTarget.virtual;
    }
    if (_physicalExact.contains(command) ||
        _matchesArgPrefix(command, _physicalArg)) {
      return CliTarget.physical;
    }
    // Source accepts `get tx` and `get tx <suffix>`.
    if (command == 'get tx' || command.startsWith('get tx ')) {
      return CliTarget.physical;
    }
    if (_disabledExact.contains(command) ||
        command == 'set pin' ||
        command.startsWith('set pin ')) {
      return CliTarget.disabled;
    }
    if (_lifecycle.contains(command)) return CliTarget.lifecycle;
    return CliTarget.unknown;
  }

  static bool _matchesArgPrefix(String command, Set<String> names) {
    for (final name in names) {
      if (command.startsWith('$name ')) return true;
    }
    return false;
  }
}

/// Validated physical CLI command and the cache refresh it requires.
class CliPhysicalCommand {
  const CliPhysicalCommand({
    required this.command,
    this.refreshRadio = false,
    this.refreshTuning = false,
    this.mutation = false,
    this.savedRadio = false,
    this.replyIsSecret = false,
  });

  /// Command sent to the physical device (without any correlation prefix).
  final String command;
  final bool refreshRadio;
  final bool refreshTuning;
  final bool mutation;

  /// `set radio` saves firmware prefs and normally needs a reboot to apply.
  final bool savedRadio;

  /// `get wifi.pwd`; never log/cache/truncate this reply.
  final bool replyIsSecret;
}

/// Strict argument validation for the physical R3 subset.
class CliPhysicalValidator {
  const CliPhysicalValidator._();

  static CliPhysicalCommand validate(
    String command, {
    required int maxTxPower,
  }) {
    switch (command) {
      case 'get radio':
      case 'get freq':
        return CliPhysicalCommand(command: command, refreshRadio: true);
      case 'get af':
      case 'get dutycycle':
      case 'get rxdelay':
        return CliPhysicalCommand(command: command, refreshTuning: true);
      case 'get int.thresh':
      case 'get cad':
      case 'get radio.rxgain':
      case 'get agc.reset.interval':
      case 'get txdelay':
      case 'get direct.txdelay':
      case 'get wifi.ssid':
      case 'get wifi.enabled':
      case 'get wifi.status':
      case 'get wifi.ip':
        return CliPhysicalCommand(command: command);
      case 'get wifi.pwd':
        return const CliPhysicalCommand(
          command: 'get wifi.pwd',
          replyIsSecret: true,
        );
      case 'set wifi.clear':
        return const CliPhysicalCommand(
          command: 'set wifi.clear',
          mutation: true,
        );
    }

    if (command == 'get tx' || command.startsWith('get tx ')) {
      return CliPhysicalCommand(command: command, refreshRadio: true);
    }
    if (command.startsWith('set radio ')) {
      _validateRadio(command.substring(10));
      return CliPhysicalCommand(
        command: command,
        refreshRadio: true,
        mutation: true,
        savedRadio: true,
      );
    }
    if (command.startsWith('set tx ')) {
      final dbm = _strictInt(command.substring(7));
      if (dbm == null || dbm < -9 || dbm > maxTxPower) {
        throw const CliFormatException('invalid TX power');
      }
      return CliPhysicalCommand(
        command: command,
        refreshRadio: true,
        mutation: true,
      );
    }
    if (command.startsWith('set af ')) {
      final value = _strictDouble(command.substring(7));
      if (value == null || value < 0 || value > 9) {
        throw const CliFormatException('invalid airtime factor');
      }
      return CliPhysicalCommand(
        command: command,
        refreshTuning: true,
        mutation: true,
      );
    }
    if (command.startsWith('set dutycycle ')) {
      final value = _strictDouble(command.substring(14));
      if (value == null || value < 1 || value > 100) {
        throw const CliFormatException('invalid duty cycle');
      }
      return CliPhysicalCommand(
        command: command,
        refreshTuning: true,
        mutation: true,
      );
    }
    if (command.startsWith('set rxdelay ')) {
      final value = _strictDouble(command.substring(12));
      if (value == null || value < 0 || value > 20) {
        throw const CliFormatException('invalid RX delay');
      }
      return CliPhysicalCommand(
        command: command,
        refreshTuning: true,
        mutation: true,
      );
    }
    if (command.startsWith('set int.thresh ')) {
      final value = _strictInt(command.substring(15));
      if (value == null || value < 0 || value > 255) {
        throw const CliFormatException('invalid interference threshold');
      }
      return CliPhysicalCommand(command: command, mutation: true);
    }
    if (command.startsWith('set cad ')) {
      _requireOnOff(command.substring(8));
      return CliPhysicalCommand(command: command, mutation: true);
    }
    if (command.startsWith('set radio.rxgain ')) {
      _requireOnOff(command.substring(17));
      return CliPhysicalCommand(command: command, mutation: true);
    }
    if (command.startsWith('set agc.reset.interval ')) {
      final value = _strictBigInt(command.substring(23));
      if (value == null) {
        throw const CliFormatException('invalid AGC interval');
      }
      final clamped = value < BigInt.zero
          ? 0
          : value > BigInt.from(1020)
              ? 1020
              : value.toInt();
      return CliPhysicalCommand(
        command: 'set agc.reset.interval $clamped',
        mutation: true,
      );
    }
    if (command.startsWith('set txdelay ')) {
      _requireDelay(command.substring(12));
      return CliPhysicalCommand(command: command, mutation: true);
    }
    if (command.startsWith('set direct.txdelay ')) {
      _requireDelay(command.substring(19));
      return CliPhysicalCommand(command: command, mutation: true);
    }
    if (command.startsWith('set wifi.ssid ')) {
      final value = command.substring(14);
      if (utf8.encode(value).length > 32) {
        throw const CliFormatException('WiFi SSID too long');
      }
      return CliPhysicalCommand(command: command, mutation: true);
    }
    if (command.startsWith('set wifi.pwd ')) {
      final value = command.substring(13);
      if (utf8.encode(value).length > 63) {
        throw const CliFormatException('WiFi password too long');
      }
      return CliPhysicalCommand(command: command, mutation: true);
    }
    if (command.startsWith('set wifi.enabled ')) {
      final value = command.substring(17);
      if (value != '0' && value != '1') {
        throw const CliFormatException('WiFi enabled must be 0 or 1');
      }
      return CliPhysicalCommand(command: command, mutation: true);
    }
    throw const CliFormatException('unknown physical CLI command');
  }

  static void _validateRadio(String args) {
    final parts = args.split(',');
    if (parts.length != 4) {
      throw const CliFormatException('radio needs four components');
    }
    final mhz = _strictDouble(parts[0]);
    final khz = _strictDouble(parts[1]);
    final sf = _strictInt(parts[2]);
    final cr = _strictInt(parts[3]);
    if (mhz == null ||
        khz == null ||
        sf == null ||
        cr == null ||
        mhz < 150 ||
        mhz > 2500 ||
        khz < 7 ||
        khz > 500 ||
        sf < 5 ||
        sf > 12 ||
        cr < 5 ||
        cr > 8) {
      throw const CliFormatException('invalid radio parameters');
    }
  }

  static void _requireOnOff(String value) {
    if (value != 'on' && value != 'off') {
      throw const CliFormatException('expected on or off');
    }
  }

  static void _requireDelay(String value) {
    final delay = _strictDouble(value);
    if (delay == null || delay < 0 || delay > 2) {
      throw const CliFormatException('invalid TX delay');
    }
  }

  static final RegExp _integerPattern = RegExp(r'^[+-]?[0-9]+$');
  static final RegExp _numberPattern =
      RegExp(r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$');

  static int? _strictInt(String value) =>
      _integerPattern.hasMatch(value) ? int.tryParse(value) : null;

  static BigInt? _strictBigInt(String value) =>
      _integerPattern.hasMatch(value) ? BigInt.tryParse(value) : null;

  static double? _strictDouble(String value) {
    if (!_numberPattern.hasMatch(value)) return null;
    final parsed = double.tryParse(value);
    if (parsed == null || !parsed.isFinite) return null;
    return parsed;
  }
}

/// Remote CLI policy scaffolding shared with T14.
///
/// Permission (contact flag 0x10) and authentication are decided by the
/// incoming-text dispatch layer. This only fixes the target policy: physical
/// administration is never available remotely, while virtual commands may be
/// executed after permission checks.
class CliRemotePolicy {
  const CliRemotePolicy._();

  static String? denialFor(CliInvocation invocation) {
    switch (invocation.target) {
      case CliTarget.virtual:
        return null;
      case CliTarget.physical:
      case CliTarget.lifecycle:
        return 'Error: physical administration disabled';
      case CliTarget.disabled:
        return 'Error: disabled';
      case CliTarget.unknown:
        return 'Unknown command';
    }
  }
}
