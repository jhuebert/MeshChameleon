import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/legal_notices.dart';

void main() {
  testWidgets('project and adapted-source notices are registered',
      (tester) async {
    await registerLegalNotices();
    await registerLegalNotices();
    final entries = await LicenseRegistry.licenses.toList();
    expect(entries.where((entry) => entry.packages.contains('MeshChameleon')),
        hasLength(1));
    expect(
      entries.where((entry) =>
          entry.packages.contains('MeshChameleon third-party notices')),
      hasLength(1),
    );
    expect(entries.expand((entry) => entry.paragraphs).map((p) => p.text),
        contains(contains('Copyright (c) 2026 Jason Huebert')));
  });
}
