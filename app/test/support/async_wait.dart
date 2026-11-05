import 'package:flutter_test/flutter_test.dart';

/// Pumps frames and lets real async work run until [done] is true.
///
/// Widget tests run in a fake-async zone, so file I/O and the app's real
/// futures only progress inside [WidgetTester.runAsync]. Polling the condition
/// the test is about to assert on waits exactly as long as the work takes; a
/// fixed delay is a race on a loaded machine.
Future<void> pumpUntil(
  WidgetTester tester,
  bool Function() done, {
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  do {
    if (!DateTime.now().isBefore(deadline)) {
      throw TestFailure(
        'Timed out after ${timeout.inSeconds}s waiting for async work',
      );
    }
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    // Advance one frame so route and snackbar transitions can finish; a bare
    // pump() would leave the fake clock frozen and they would never complete.
    await tester.pump(const Duration(milliseconds: 16));
  } while (!done());
}
