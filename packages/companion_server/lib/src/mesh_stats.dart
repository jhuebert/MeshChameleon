/// Typed companion statistics returned by `CMD_GET_STATS`.
///
/// The same type carries the core, radio, and packet counter sets; handlers
/// read only the fields for the requested stats type. Defaults describe an
/// idle node rather than an unknown one.
class MeshStats {
  const MeshStats({
    this.batteryMv = 0,
    this.uptimeSecs = 0,
    this.errors = 0,
    this.queueLen = 0,
    this.noiseFloor = 0,
    this.lastRssi = 0,
    this.lastSnrScaled = 0,
    this.txAirSecs = 0,
    this.rxAirSecs = 0,
    this.recv = 0,
    this.sent = 0,
    this.floodTx = 0,
    this.directTx = 0,
    this.floodRx = 0,
    this.directRx = 0,
    this.recvErrors = 0,
  });

  /// `STATS_TYPE_CORE`.
  final int batteryMv;
  final int uptimeSecs;
  final int errors;
  final int queueLen;

  /// `STATS_TYPE_RADIO`.
  final int noiseFloor;
  final int lastRssi;
  final int lastSnrScaled;
  final int txAirSecs;
  final int rxAirSecs;

  /// `STATS_TYPE_PACKETS`.
  final int recv;
  final int sent;
  final int floodTx;
  final int directTx;
  final int floodRx;
  final int directRx;
  final int recvErrors;
}
