import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

/// Map a physical command failure to a companion-protocol operation error.
CompanionOperationError operationError(DeviceCommandError e) =>
    CompanionOperationError(
      e.clientErrorCode,
      message: e.message,
      disabled: e.isDisabled,
      uncertain: e.mayHaveApplied,
    );

/// Map a physical command read failure, where no write was attempted.
CompanionOperationError queryError(DeviceCommandError e) =>
    CompanionOperationError(e.clientErrorCode, message: e.message);

CompanionOperationError illegalArgument(String message) =>
    CompanionOperationError(errCodeIllegalArg, message: message);
