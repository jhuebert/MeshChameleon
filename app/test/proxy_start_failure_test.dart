import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/proxy_controller.dart';

void main() {
  SocketException addressInUse() => SocketException(
        'Failed to create server socket',
        osError: const OSError('Address already in use', 48),
        port: 5000,
      );

  test('an occupied port on macOS explains the AirPlay Receiver conflict', () {
    final message =
        describeProxyStartFailure(addressInUse(), 5000, isMacOS: true);
    expect(message, contains('Proxy port 5000 is already in use'));
    expect(message, contains('AirPlay Receiver'));
    expect(message, contains('System Settings'));
    expect(message, contains('choose another port in Settings'));
  });

  test('an occupied port elsewhere points to the port setting', () {
    final message =
        describeProxyStartFailure(addressInUse(), 5000, isMacOS: false);
    expect(message, contains('Proxy port 5000 is already in use'));
    expect(message, isNot(contains('AirPlay Receiver')));
    expect(message, contains('Choose another port in Settings'));
  });

  test('unrelated bind failures keep the generic message', () {
    final message = describeProxyStartFailure(StateError('boom'), 5000);
    expect(message, contains('Failed to start proxy:'));
    expect(message, contains('boom'));
  });
}
