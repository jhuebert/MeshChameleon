import 'dart:async';

import 'radio_link.dart';

/// Connect [link], retrying transient failures with exponential backoff.
///
/// BLE connects in particular fail sporadically (`GATT_CONNECTION_TIMEOUT`,
/// `GATT_ERROR 133`), so the app tolerates a few retries before giving up. Each
/// retry waits [initialDelay], doubling up to [maxDelay]. The last failure is
/// rethrown once [maxAttempts] is exhausted.
Future<void> connectWithBackoff(
  RadioLink link, {
  int maxAttempts = 3,
  Duration initialDelay = const Duration(seconds: 1),
  Duration maxDelay = const Duration(seconds: 30),
  void Function(String message)? onLog,
  bool Function()? shouldCancel,
}) async {
  var delay = initialDelay;
  for (var attempt = 1;; attempt++) {
    if (shouldCancel?.call() ?? false) {
      throw StateError('connection cancelled');
    }
    try {
      await link.connect();
      if (shouldCancel?.call() ?? false) {
        await link.disconnect();
        throw StateError('connection cancelled');
      }
      return;
    } catch (e) {
      if (shouldCancel?.call() ?? false) rethrow;
      if (attempt >= maxAttempts) rethrow;
      onLog?.call(
          'device connect attempt $attempt failed: $e; retrying in ${delay.inMilliseconds}ms');
      await Future<void>.delayed(delay);
      final doubled = delay * 2;
      delay = doubled > maxDelay ? maxDelay : doubled;
    }
  }
}
