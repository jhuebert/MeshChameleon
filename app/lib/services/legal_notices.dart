import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Asset paths for the project's legal text bundled with the app.
abstract final class LegalAssets {
  static const license = 'assets/legal/LICENSE.md';
  static const attribution = 'assets/legal/ATTRIBUTION.md';
}

/// Register the project's own legal notices with Flutter's license registry.
///
/// [LicensePage] shows registered licenses only; without this, the built-in
/// page would omit the MIT license and the adapted-source attribution that
/// ship with the app. Subsequent calls are no-ops.
Future<void> registerLegalNotices() async {
  if (_registered) return;
  _registered = true;

  Future<String> load(String path) async {
    try {
      return await rootBundle.loadString(path);
    } catch (_) {
      return 'Unavailable: could not read $path from the bundle.';
    }
  }

  final license = await load(LegalAssets.license);
  final attribution = await load(LegalAssets.attribution);
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['MeshChameleon'],
      license,
    );
    yield LicenseEntryWithLineBreaks(
      const ['MeshChameleon third-party notices'],
      attribution,
    );
  });
}

bool _registered = false;
