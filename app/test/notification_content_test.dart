import 'package:flutter_test/flutter_test.dart';
import 'package:meshchameleon/services/device_link_phase.dart';
import 'package:meshchameleon/services/notification_content.dart';
import 'package:meshchameleon/services/proxy_status.dart';

void main() {
  test(
      'notification title describes the state and does not repeat the app name',
      () {
    final content = buildNotificationContent(
      identityCount: 1,
      activeName: 'MeshChameleon',
      devicePhase: DeviceLinkPhase.connected,
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
      devicePhase: DeviceLinkPhase.connected,
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
      devicePhase: DeviceLinkPhase.connected,
      deviceConnected: true,
      proxyStatus: ProxyStatus.stopped,
      port: 5000,
    );

    expect(content.title, 'Device linked');
    expect(
        content.text, '2 identities · Alpha · device linked · server stopped');
  });

  test('connecting, reconnecting, and waiting have distinct titles', () {
    NotificationContent build(DeviceLinkPhase phase, ProxyStatus proxy) =>
        buildNotificationContent(
          identityCount: 2,
          activeName: 'Alpha',
          devicePhase: phase,
          deviceConnected: phase == DeviceLinkPhase.connected,
          proxyStatus: proxy,
          port: 5000,
        );

    final connecting = build(DeviceLinkPhase.connecting, ProxyStatus.stopped);
    expect(connecting.title, 'Connecting to companion');
    expect(
        connecting.text, '2 identities · Alpha · no device · server stopped');

    final reconnecting =
        build(DeviceLinkPhase.reconnecting, ProxyStatus.running);
    expect(reconnecting.title, 'Reconnecting to companion');
    expect(
        reconnecting.text, '2 identities · Alpha · no device · serving :5000');

    final waiting = build(DeviceLinkPhase.waiting, ProxyStatus.stopped);
    expect(waiting.title, 'Waiting for companion');
    expect(waiting.text, '2 identities · Alpha · no device · server stopped');
  });

  test('stopped proxy and disconnected device use neutral copy', () {
    final content = buildNotificationContent(
      identityCount: 0,
      activeName: null,
      devicePhase: DeviceLinkPhase.idle,
      deviceConnected: false,
      proxyStatus: ProxyStatus.stopped,
      port: 5000,
    );

    expect(content.title, 'MeshChameleon idle');
    expect(content.text, 'no identity · no device · server stopped');
  });
}
