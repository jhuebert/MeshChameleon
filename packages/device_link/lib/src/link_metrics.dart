import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'errors.dart';
import 'radio_link.dart';

/// Session-only counters for one logical device link.
///
/// Physical packet/byte counts are unique: [MeteredRadioLink] is installed
/// below [SharedRadioHub], so frames are counted once before they fan out to
/// the live identities.
class LinkMetrics {
  LinkMetrics({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;

  int connectAttempts = 0;
  int connectSuccesses = 0;
  int connectFailures = 0;
  int disconnects = 0;
  int unexpectedDrops = 0;

  int rawTxPackets = 0;
  int rawTxBytes = 0;
  int rawTxFailures = 0;
  int rawRxPackets = 0;
  int rawRxBytes = 0;

  int deviceRequests = 0;
  int deviceRequestFailures = 0;
  int deviceTimeouts = 0;

  DateTime? connectedSince;
  Duration _completedConnected = Duration.zero;

  double? lastRssi;
  double? lastSnr;
  String? lastError;

  bool get connected => connectedSince != null;

  Duration get currentSessionDuration => connectedSince == null
      ? Duration.zero
      : _now().difference(connectedSince!);

  Duration get totalConnected =>
      _completedConnected +
      (connectedSince == null
          ? Duration.zero
          : _now().difference(connectedSince!));

  void connectionAttempt() => connectAttempts++;

  void connectionSucceeded() {
    connectSuccesses++;
    connectedSince ??= _now();
    lastError = null;
  }

  void connectionFailed(Object error) {
    connectFailures++;
    _recordError(error);
  }

  void disconnected({bool unexpected = false}) {
    final wasConnected = connectedSince != null;
    if (wasConnected) {
      _completedConnected += _now().difference(connectedSince!);
      connectedSince = null;
      disconnects++;
    }
    if (unexpected) {
      unexpectedDrops++;
      if (!wasConnected) disconnects++;
    }
  }

  void rawTx(int bytes) {
    rawTxPackets++;
    rawTxBytes += bytes;
  }

  void rawTxFailed(Object error) {
    rawTxFailures++;
    _recordError(error);
  }

  void rawRx(double snr, int rssi, int bytes) {
    rawRxPackets++;
    rawRxBytes += bytes;
    lastSnr = snr;
    lastRssi = rssi.toDouble();
  }

  void deviceRequest() => deviceRequests++;

  void deviceRequestFailed(Object error, {bool timeout = false}) {
    deviceRequestFailures++;
    if (timeout) deviceTimeouts++;
    _recordError(error);
  }

  void _recordError(Object error) => lastError = error.toString();
}

/// Transparent [RadioLink] decorator that feeds [LinkMetrics].
///
/// It forwards every operation unchanged and counts raw RX before the shared
/// hub fans a frame out to the identities. Use one metrics object per app
/// session and wrap every newly created transport.
class MeteredRadioLink implements RadioLink {
  MeteredRadioLink(this._inner, {LinkMetrics? metrics})
      : metrics = metrics ?? LinkMetrics();

  final RadioLink _inner;
  final LinkMetrics metrics;
  RawRxListener? _listener;

  @override
  Stream<LinkState> get state => _inner.state;

  @override
  LinkState get currentState => _inner.currentState;

  @override
  Future<void> connect() async {
    metrics.connectionAttempt();
    try {
      await _inner.connect();
      metrics.connectionSucceeded();
    } catch (e) {
      metrics.connectionFailed(e);
      rethrow;
    }
  }

  @override
  Future<void> disconnect() async {
    try {
      await _inner.disconnect();
    } finally {
      metrics.disconnected();
    }
  }

  @override
  void setRawRxListener(RawRxListener? listener) {
    _listener = listener;
    _inner.setRawRxListener(listener == null ? null : _onRawRx);
  }

  void _onRawRx(double snr, int rssi, Uint8List raw) {
    metrics.rawRx(snr, rssi, raw.length);
    _listener?.call(snr, rssi, raw);
  }

  @override
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]) async {
    metrics.deviceRequest();
    try {
      await _inner.sendRawPacket(packet, priority);
      metrics.rawTx(packet.length);
    } on DeviceCommandError catch (e) {
      metrics.deviceRequestFailed(e,
          timeout: e.kind == DeviceCommandErrorKind.timeout);
      metrics.rawTxFailed(e);
      rethrow;
    } catch (e) {
      metrics.deviceRequestFailed(e);
      metrics.rawTxFailed(e);
      rethrow;
    }
  }

  Future<T> _request<T>(Future<T> Function() action) async {
    metrics.deviceRequest();
    try {
      return await action();
    } on DeviceCommandError catch (e) {
      metrics.deviceRequestFailed(e,
          timeout: e.kind == DeviceCommandErrorKind.timeout);
      rethrow;
    } catch (e) {
      metrics.deviceRequestFailed(e);
      rethrow;
    }
  }

  @override
  Future<DeviceInfo> deviceInfo() => _request(_inner.deviceInfo);

  @override
  Future<ParsedSelfInfo> selfInfo() => _request(_inner.selfInfo);

  @override
  Future<RadioParams> radioParams() => _request(_inner.radioParams);

  @override
  Future<RadioStats> radioStats() => _request(_inner.radioStats);

  @override
  Future<void> setRadioParams(RadioParams params, {bool? clientRepeat}) =>
      _request(() => _inner.setRadioParams(params, clientRepeat: clientRepeat));

  @override
  Future<void> setTxPower(int dbm) => _request(() => _inner.setTxPower(dbm));

  @override
  Future<void> reboot() => _request(_inner.reboot);

  @override
  Future<void> shutdown() => _request(_inner.shutdown);

  @override
  Future<BatteryReading?> battery() => _request(_inner.battery);

  @override
  Future<TuningParams> tuningParams() => _request(_inner.tuningParams);

  @override
  Future<void> setTuningParams(TuningParams params) =>
      _request(() => _inner.setTuningParams(params));

  @override
  Future<void> setPathHashMode(int mode) =>
      _request(() => _inner.setPathHashMode(mode));

  @override
  Future<String> runCliCommand(String command) =>
      _request(() => _inner.runCliCommand(command));

  @override
  Future<Uint8List> getAllowedRepeatFreq() =>
      _request(_inner.getAllowedRepeatFreq);
}
