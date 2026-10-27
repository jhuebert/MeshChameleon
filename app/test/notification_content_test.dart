import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/app_state.dart';

void main() {
  test(
      'notification title describes the state and does not repeat the app name',
      () {
    final content = buildNotificationContent(
      identityCount: 1,
      activeName: 'MeshChameleon',
      deviceConnected: true,
      proxyStatus: ProxyStatus.running,
      port: 5000,
    );

    expect(content.title, 'Proxy running');
    expect(content.text, '1 identity · device linked · serving :5000');
    expect(content.title, isNot(contains('MeshChameleon')));
    expect(content.text, isNot(contains('MeshChameleon')));
  });

  test('the default identity name is omitted even with multiple identities',
      () {
    final content = buildNotificationContent(
      identityCount: 2,
      activeName: 'MeshChameleon',
      deviceConnected: true,
      proxyStatus: ProxyStatus.running,
      port: 5000,
    );

    expect(content.text, '2 identities · device linked · serving :5000');
  });

  test('a custom active identity name is shown', () {
    final content = buildNotificationContent(
      identityCount: 2,
      activeName: 'Alpha',
      deviceConnected: true,
      proxyStatus: ProxyStatus.stopped,
      port: 5000,
    );

    expect(content.title, 'Device linked');
    expect(
        content.text, '2 identities · Alpha · device linked · server stopped');
  });

  test('stopped proxy and disconnected device use neutral copy', () {
    final content = buildNotificationContent(
      identityCount: 0,
      activeName: null,
      deviceConnected: false,
      proxyStatus: ProxyStatus.stopped,
      port: 5000,
    );

    expect(content.title, 'MeshChameleon idle');
    expect(content.text, 'no identity · no device · server stopped');
  });
}
