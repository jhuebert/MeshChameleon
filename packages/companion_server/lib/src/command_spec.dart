import 'dart:async';
import 'dart:typed_data';

/// A command handler receives the payload after the command byte.
typedef CommandHandler = FutureOr<void> Function(Uint8List data);

/// Declarative description of one companion command.
///
/// The server checks [minDataLength] once before invoking [handler], so
/// handlers only need to validate semantic constraints (field ranges, path
/// widths, and required embedded structures).
class CommandSpec {
  const CommandSpec(this.minDataLength, this.handler);

  /// Minimum payload length after the command byte.
  final int minDataLength;

  /// Handler for a payload that satisfies [minDataLength].
  final CommandHandler handler;
}
