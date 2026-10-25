import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

void main() {
  test('app pubspec version matches the core product-version constant', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match = RegExp(
      r'^version:\s*([0-9]+\.[0-9]+\.[0-9]+)',
      multiLine: true,
    ).firstMatch(pubspec);

    expect(match, isNotNull, reason: 'app/pubspec.yaml has a version');
    expect(match!.group(1), productVersion);
  });
}
