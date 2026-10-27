/// Mutable, session-only traffic counters for [CompanionServer].
///
/// The app owns one instance for the lifetime of the process so restarting the
/// proxy does not lose the totals. Nothing here is persisted.
class CompanionMetrics {
  CompanionMetrics({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  int clientConnections = 0;
  int clientDisconnects = 0;
  int evictions = 0;
  int idleTimeouts = 0;
  int clientErrors = 0;
  int writeErrors = 0;
  int commandsReceived = 0;
  int repliesSent = 0;
  int pushesSent = 0;
  int payloadBytesIn = 0;
  int payloadBytesOut = 0;
  int errorReplies = 0;
  int unsupportedCommands = 0;

  /// Protocol version from the most recent DEVICE_QUERY / APP_START.
  int? appTargetVer;

  DateTime? currentClientSince;
  DateTime? lastClientConnectedAt;
  DateTime? lastClientDisconnectedAt;
  String? currentClientAddress;
  String? lastDisconnectReason;

  bool get clientConnected => currentClientSince != null;

  Duration get currentClientDuration => currentClientSince == null
      ? Duration.zero
      : _now().difference(currentClientSince!);

  void recordClientConnected(String? address) {
    clientConnections++;
    currentClientSince = _now();
    lastClientConnectedAt = currentClientSince;
    currentClientAddress = address;
  }

  /// A new client replaced the previous one. The server destroys the old
  /// socket without going through its normal disconnect path.
  void clientEvicted() {
    if (currentClientSince == null) return;
    clientDisconnects++;
    evictions++;
    currentClientSince = null;
    currentClientAddress = null;
    lastClientDisconnectedAt = _now();
    lastDisconnectReason = 'evicted by a new client';
  }

  void clientDisconnected(
    String reason, {
    bool error = false,
    bool idleTimeout = false,
  }) {
    if (currentClientSince == null) return;
    clientDisconnects++;
    if (error) clientErrors++;
    if (idleTimeout) idleTimeouts++;
    currentClientSince = null;
    currentClientAddress = null;
    lastClientDisconnectedAt = _now();
    lastDisconnectReason = reason;
  }

  void commandReceived(int payloadBytes) {
    commandsReceived++;
    payloadBytesIn += payloadBytes;
  }

  void replySent(int payloadBytes) {
    repliesSent++;
    payloadBytesOut += payloadBytes;
  }

  void pushSent(int payloadBytes) {
    pushesSent++;
    payloadBytesOut += payloadBytes;
  }

  void errorReplySent() => errorReplies++;

  void unsupportedCommandReceived() => unsupportedCommands++;

  void writeFailed() => writeErrors++;

  void appTargetVersionReceived(int version) => appTargetVer = version;
}
