import 'package:mesh_protocol/mesh_protocol.dart';

/// The kind of failure from a physical companion command.
enum DeviceCommandErrorKind {
  /// The device replied `RESP_CODE_ERR` with a numeric error code.
  device,

  /// The device replied `RESP_CODE_DISABLED`.
  disabled,

  /// The physical protocol version does not support the operation.
  unsupported,

  /// No reply arrived before the link timeout.
  timeout,

  /// The link is disconnected or was disconnected during the request.
  disconnected,

  /// The reply was truncated, malformed, or not the expected response.
  malformed,
}

/// A typed physical-command failure.
///
/// [mayHaveApplied] distinguishes a definite device rejection (`false`) from a
/// timeout/disconnect/malformed reply where the operation may have reached the
/// device (`true`). Callers must not automatically retry writes whose outcome
/// is uncertain.
class DeviceCommandError implements Exception {
  const DeviceCommandError(this.kind, {this.code, this.message});

  const DeviceCommandError.device(int code, {String? message})
      : this(DeviceCommandErrorKind.device, code: code, message: message);

  const DeviceCommandError.disabled({String? message})
      : this(DeviceCommandErrorKind.disabled, message: message);

  const DeviceCommandError.unsupported({String? message})
      : this(DeviceCommandErrorKind.unsupported, message: message);

  const DeviceCommandError.timeout({String? message})
      : this(DeviceCommandErrorKind.timeout, message: message);

  const DeviceCommandError.disconnected({String? message})
      : this(DeviceCommandErrorKind.disconnected, message: message);

  const DeviceCommandError.malformed({String? message})
      : this(DeviceCommandErrorKind.malformed, message: message);

  final DeviceCommandErrorKind kind;

  /// Device `ERR_CODE_*` for [DeviceCommandErrorKind.device].
  final int? code;

  /// Diagnostic text. Must never contain secrets.
  final String? message;

  bool get isDisabled => kind == DeviceCommandErrorKind.disabled;

  /// True when the write may have reached the device despite the error.
  bool get mayHaveApplied =>
      kind == DeviceCommandErrorKind.timeout ||
      kind == DeviceCommandErrorKind.disconnected ||
      kind == DeviceCommandErrorKind.malformed;

  /// Companion protocol error code corresponding to this failure.
  int get clientErrorCode => switch (kind) {
        DeviceCommandErrorKind.device => code ?? errCodeBadState,
        DeviceCommandErrorKind.disabled => 15,
        DeviceCommandErrorKind.unsupported => 1,
        DeviceCommandErrorKind.timeout ||
        DeviceCommandErrorKind.disconnected ||
        DeviceCommandErrorKind.malformed =>
          4,
      };

  @override
  String toString() {
    final parts = <String>[kind.name];
    if (code != null) parts.add('code=$code');
    if (message != null) parts.add(message!);
    return 'DeviceCommandError(${parts.join(', ')})';
  }
}
