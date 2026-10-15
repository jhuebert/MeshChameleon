import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'radio_link.dart';

/// An in-memory shared radio bus. Fake links attached to the same bus receive
/// one another's transmissions, modelling over-air delivery.
class FakeRadioBus {
  final List<FakeDeviceLink> _links = [];
  final List<void Function(FakeDeviceLink from, Uint8List packet)> _taps = [];

  void attach(FakeDeviceLink link) => _links.add(link);
  void detach(FakeDeviceLink link) => _links.remove(link);

  /// Observe every transmission (for assertions in tests).
  void addTap(void Function(FakeDeviceLink from, Uint8List packet) tap) =>
      _taps.add(tap);

  void transmit(FakeDeviceLink from, Uint8List packet, double snr, int rssi) {
    for (final tap in _taps) {
      tap(from, packet);
    }
    for (final link in _links) {
      if (identical(link, from)) continue;
      link.deliver(snr, rssi, packet);
    }
  }
}

/// A stock-companion simulator implementing [RadioLink] entirely in memory.
///
/// It answers `DEVICE_QUERY`/`APP_START`/battery requests with configurable
/// values and treats every `CMD_SEND_RAW_PACKET` as a transmission on the
/// attached [FakeRadioBus], which delivers it to peers as `LOG_RX_DATA`.
class FakeDeviceLink implements RadioLink {
  FakeDeviceLink({
    this.deviceInfo_ = const DeviceInfo(),
    this.radioParams_ = const RadioParams(
      frequencyHz: 915000000,
      bandwidthHz: 250000,
      spreadingFactor: 10,
      codingRate: 5,
    ),
    this.batteryReading_ = const BatteryReading(
      millivolts: 4000,
      storageUsedKb: 12,
      storageTotalKb: 1024,
    ),
    this.snr = 6.0,
    this.rssi = -70,
    this.bus,
    this.echoSelf = false,
    this.connectFailures = 0,
    this.devicePrivateKey,
    this.exportPrivateKeyDisabled = false,
  });

  final DeviceInfo deviceInfo_;
  final RadioParams radioParams_;
  final BatteryReading batteryReading_;
  final double snr;
  final int rssi;
  final FakeRadioBus? bus;

  /// The 64-byte expanded key this simulated device exports, if any.
  final Uint8List? devicePrivateKey;

  /// When true, `CMD_EXPORT_PRIVATE_KEY` answers `RESP_CODE_DISABLED`.
  final bool exportPrivateKeyDisabled;

  /// When true, the simulator also loops the transmitted frame back to itself.
  final bool echoSelf;

  /// Number of initial [connect] calls that should fail (for backoff tests).
  int connectFailures;

  final _stateController = StreamController<LinkState>.broadcast();
  LinkState _state = LinkState.disconnected;
  RawRxListener? _rawRxListener;
  late RadioParams _currentParams;
  late final RadioParams _initialParams = _currentParams = radioParams_;

  /// Every packet this link transmitted (for test assertions).
  final List<Uint8List> transmitted = [];

  @override
  Stream<LinkState> get state => _stateController.stream;

  @override
  LinkState get currentState => _state;

  @override
  Future<void> connect() async {
    if (_state == LinkState.connected) return;
    if (connectFailures > 0) {
      connectFailures--;
      throw StateError('simulated connect failure');
    }
    _state = LinkState.connected;
    _stateController.add(_state);
    bus?.attach(this);
  }

  @override
  Future<void> disconnect() async {
    if (_state == LinkState.disconnected) return;
    bus?.detach(this);
    _state = LinkState.disconnected;
    _stateController.add(_state);
  }

  @override
  void setRawRxListener(RawRxListener? listener) => _rawRxListener = listener;

  @override
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]) async {
    transmitted.add(Uint8List.fromList(packet));
    bus?.transmit(this, packet, snr, rssi);
    if (echoSelf) deliver(snr, rssi, packet);
  }

  /// Deliver an over-air frame to this link as `LOG_RX_DATA`.
  void deliver(double frameSnr, int frameRssi, Uint8List packet) {
    _rawRxListener?.call(frameSnr, frameRssi, Uint8List.fromList(packet));
  }

  @override
  Future<DeviceInfo> deviceInfo() async => deviceInfo_;

  @override
  Future<RadioParams> radioParams() async => _currentParams;

  @override
  Future<void> setRadioParams(RadioParams params) async {
    _currentParams = params;
  }

  @override
  Future<void> setTxPower(int dbm) async {}

  @override
  Future<TuningParams> tuningParams() async => _tuning;

  @override
  Future<void> setTuningParams(TuningParams params) async {
    _tuning = params;
  }

  @override
  Future<void> setPathHashMode(int mode) async {
    pathHashMode = mode;
  }

  @override
  Future<void> runCliCommand(String command) async {
    cliCommands.add(command);
  }

  @override
  Future<Uint8List?> exportPrivateKey() async {
    exportPrivateKeyRequests++;
    if (exportPrivateKeyDisabled) return null;
    return devicePrivateKey;
  }

  /// Number of `CMD_EXPORT_PRIVATE_KEY` requests received (for tests).
  int exportPrivateKeyRequests = 0;

  TuningParams _tuning = const TuningParams(rxDelayBaseMs: 0, airtimeFactorMs: 0);

  /// Last path-hash mode set via [setPathHashMode].
  int pathHashMode = 0;

  /// Every CLI command received (for test assertions).
  final List<String> cliCommands = [];

  @override
  Future<BatteryReading?> battery() async => batteryReading_;

  /// Original params before any `setRadioParams` call.
  RadioParams get initialRadioParams => _initialParams;
}
