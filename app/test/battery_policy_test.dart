import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('manifest does not request the restricted battery permission', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
      manifest,
      isNot(contains('REQUEST_IGNORE_BATTERY_OPTIMIZATIONS')),
    );
  });
}
