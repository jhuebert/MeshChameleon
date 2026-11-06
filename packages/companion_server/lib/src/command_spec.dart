import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

/// A command handler receives the payload after the command byte.
typedef CommandHandler = FutureOr<void> Function(Uint8List data);

/// Declarative description of one companion command.
///
/// The server checks [minDataLength] once before invoking [handler], so
/// handlers only need to validate semantic constraints (field ranges, path
/// widths, and required embedded structures).
class CommandSpec {
  const CommandSpec(
    this.minDataLength,
    this.handler, {
    this.shortErrorCode = errCodeIllegalArg,
  });

  /// Minimum payload length after the command byte.
  final int minDataLength;

  /// Reply used when the payload is shorter than [minDataLength]. Stock
  /// firmware falls through to `ERR_CODE_UNSUPPORTED_CMD` for commands whose
  /// dispatch branch carries a minimum length.
  final int shortErrorCode;

  /// Handler for a payload that satisfies [minDataLength].
  final CommandHandler handler;
}
