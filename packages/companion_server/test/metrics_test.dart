import 'package:companion_server/companion_server.dart';
import 'package:test/test.dart';

void main() {
  test('tracks client sessions, traffic, and disconnect reasons', () {
    var now = DateTime.utc(2026, 1, 1);
    final metrics = CompanionMetrics(now: () => now);

    metrics.recordClientConnected('10.0.0.2');
    expect(metrics.clientConnected, isTrue);
    expect(metrics.clientConnections, 1);
    expect(metrics.currentClientAddress, '10.0.0.2');

    now = now.add(const Duration(seconds: 5));
    expect(metrics.currentClientDuration, const Duration(seconds: 5));

    metrics.commandReceived(2);
    metrics.replySent(80);
    metrics.pushSent(7);
    metrics.errorReplySent();
    metrics.unsupportedCommandReceived();
    metrics.appTargetVersionReceived(3);

    expect(metrics.commandsReceived, 1);
    expect(metrics.payloadBytesIn, 2);
    expect(metrics.repliesSent, 1);
    expect(metrics.pushesSent, 1);
    expect(metrics.payloadBytesOut, 87);
    expect(metrics.errorReplies, 1);
    expect(metrics.unsupportedCommands, 1);
    expect(metrics.appTargetVer, 3);

    metrics.clientDisconnected('idle timeout', idleTimeout: true);
    expect(metrics.clientConnected, isFalse);
    expect(metrics.clientDisconnects, 1);
    expect(metrics.idleTimeouts, 1);
    expect(metrics.lastDisconnectReason, 'idle timeout');

    metrics.recordClientConnected('10.0.0.3');
    metrics.clientEvicted();
    expect(metrics.clientDisconnects, 2);
    expect(metrics.evictions, 1);
    expect(metrics.lastDisconnectReason, 'evicted by a new client');

    metrics.recordClientConnected('10.0.0.4');
    metrics.clientDisconnected('socket error', error: true);
    expect(metrics.clientErrors, 1);
    expect(metrics.clientDisconnects, 3);
  });

  test('ignores duplicate disconnects when no client is attached', () {
    final metrics = CompanionMetrics();

    metrics.clientDisconnected('server stop');
    metrics.clientEvicted();

    expect(metrics.clientDisconnects, 0);
    expect(metrics.evictions, 0);
  });
}
