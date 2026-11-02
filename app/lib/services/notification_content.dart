import 'identity_repository.dart';
import 'proxy_status.dart';

/// Persistent-notification title and text.
///
/// The title deliberately describes the state instead of repeating the product
/// name: Android already renders the app label above the notification, and the
/// first identity is also named [defaultIdentityName]. Keeping the name out of
/// both fields means it appears only once.
class NotificationContent {
  const NotificationContent({required this.title, required this.text});

  final String title;
  final String text;

  String get key => '$title\n$text';
}

/// Build the foreground-service notification copy.
NotificationContent buildNotificationContent({
  required int identityCount,
  String? activeName,
  required bool deviceConnected,
  required ProxyStatus proxyStatus,
  required int port,
}) {
  final showActiveName = activeName != null &&
      activeName.isNotEmpty &&
      activeName != defaultIdentityName;
  final identityPart = identityCount == 0
      ? 'no identity'
      : '$identityCount '
          '${identityCount == 1 ? 'identity' : 'identities'}'
          '${showActiveName ? ' · $activeName' : ''}';
  final linkPart = deviceConnected ? 'device linked' : 'no device';
  final serverPart =
      proxyStatus == ProxyStatus.running ? 'serving :$port' : 'server stopped';
  final title = proxyStatus == ProxyStatus.running
      ? 'Proxy running'
      : deviceConnected
          ? 'Device linked'
          : 'MeshChameleon idle';
  return NotificationContent(
    title: title,
    text: '$identityPart · $linkPart · $serverPart',
  );
}
