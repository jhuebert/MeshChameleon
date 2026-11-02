import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('device errors expose kind, code, and client error code', () {
    const device = DeviceCommandError.device(errCodeIllegalArg);
    expect(device.kind, DeviceCommandErrorKind.device);
    expect(device.code, errCodeIllegalArg);
    expect(device.clientErrorCode, errCodeIllegalArg);
    expect(device.isDisabled, isFalse);
    expect(device.mayHaveApplied, isFalse);

    const unknown = DeviceCommandError(DeviceCommandErrorKind.device);
    expect(unknown.clientErrorCode, errCodeBadState);
  });

  test('disabled errors map to the one-byte DISABLED response', () {
    const error = DeviceCommandError.disabled(message: 'off');
    expect(error.isDisabled, isTrue);
    expect(error.clientErrorCode, respCodeDisabled);
    expect(error.mayHaveApplied, isFalse);
  });

  test('uncertain errors must not be retried automatically', () {
    for (final error in [
      const DeviceCommandError.timeout(),
      const DeviceCommandError.disconnected(),
      const DeviceCommandError.malformed(),
    ]) {
      expect(error.mayHaveApplied, isTrue, reason: error.kind.name);
      expect(error.clientErrorCode, errCodeBadState);
      expect(error.isDisabled, isFalse);
    }
  });

  test('toString includes the kind and optional details', () {
    expect(
      const DeviceCommandError.timeout().toString(),
      contains(DeviceCommandErrorKind.timeout.name),
    );
    expect(
      const DeviceCommandError.device(6, message: 'rejected').toString(),
      allOf(contains('code=6'), contains('rejected')),
    );
    expect(
      const DeviceCommandError(DeviceCommandErrorKind.malformed,
              code: 3, message: 'short reply')
          .toString(),
      allOf(contains('malformed'), contains('code=3'), contains('short reply')),
    );
  });
}
