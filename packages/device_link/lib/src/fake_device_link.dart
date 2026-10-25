import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'errors.dart';
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
      link.deliver(snr, rssi, _consumeDirectRoute(packet));
    }
  }

  /// Model the final direct-route hop: a receiving endpoint sees the path hash
  /// count decremented. Trace uses its path field for SNR accumulation and is
  /// exempt. Flood routes accumulate paths and are left untouched.
  static Uint8List _consumeDirectRoute(Uint8List raw) {
    final packet = Packet.readFrom(raw);
    if (packet == null ||
        packet.payloadType == payloadTypeTrace ||
        !packet.isRouteDirect ||
        packet.pathHashCount == 0) {
      return packet?.writeTo() ?? raw;
    }
    final hashSize = packet.pathHashSize;
    final count = packet.pathHashCount - 1;
    final base = packet.pathLenByte & 0xC0;
    packet
      ..path = Uint8List.fromList(packet.path.sublist(hashSize))
      ..pathLenByte = base | count;
    return packet.writeTo();
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
    this.deviceNodeName = 'Fake companion',
    this.maxTxPower = 22,
    this.connectFailures = 0,
    this.devicePrivateKey,
    this.exportPrivateKeyDisabled = false,
    this.rebootDisconnects = false,
    this.shutdownDisconnects = true,
    Uint8List? allowedRepeatFreq,
  }) : allowedRepeatFreq = allowedRepeatFreq ?? Uint8List(0);

  final DeviceInfo deviceInfo_;
  final RadioParams radioParams_;

  /// Mutable so tests can model the battery ageing between reads.
  BatteryReading? batteryReading_;
  final double snr;
  final int rssi;
  final FakeRadioBus? bus;

  /// The 64-byte expanded key this simulated device exports, if any.
  final Uint8List? devicePrivateKey;

  /// When true, `CMD_EXPORT_PRIVATE_KEY` answers `RESP_CODE_DISABLED`.
  final bool exportPrivateKeyDisabled;

  /// Model the device dropping the link while rebooting.
  final bool rebootDisconnects;

  /// Model the device dropping the link after a successful poweroff.
  final bool shutdownDisconnects;

  /// Raw `CMD_GET_ALLOWED_REPEAT_FREQ` ranges returned by this simulator.
  final Uint8List allowedRepeatFreq;

  /// When true, the simulator also loops the transmitted frame back to itself.
  final bool echoSelf;
  final String deviceNodeName;

  /// Maximum TX power reported by the simulated device's `SELF_INFO`.
  final int maxTxPower;

  /// Number of initial [connect] calls that should fail (for backoff tests).
  int connectFailures;

  /// Injected lifecycle failures for tests.
  Object? rebootError;
  Object? shutdownError;

  final _stateController = StreamController<LinkState>.broadcast();
  LinkState _state = LinkState.disconnected;
  RawRxListener? _rawRxListener;
  // Both initialize lazily from the constructed parameter set, so reading
  // either before the other never observes an uninitialized field.
  late RadioParams _currentParams = radioParams_;
  late final RadioParams _initialParams = _currentParams;

  /// Every packet this link transmitted (for test assertions).
  final List<Uint8List> transmitted = [];

  /// Priority argument for each [sendRawPacket], parallel to [transmitted].
  final List<int> transmitPriorities = [];

  /// Names of every [RadioLink] method invoked on this fake, in order. Lets a
  /// test distinguish handshake/query calls from state-changing writes.
  final List<String> calls = [];

  /// Test hooks that hold a reply until completed, modelling device latency.
  Completer<void>? batteryAck;
  Object? batteryError;
  int batteryReads = 0;
  Completer<void>? rawTxAck;

  Completer<void>? radioParamsAck;
  Completer<void>? txPowerAck;
  Completer<void>? tuningAck;
  Completer<void>? selfInfoAck;
  Completer<void>? deviceInfoAck;
  Completer<void>? tuningParamsAck;

  /// Test hooks that make the corresponding operation fail.
  DeviceCommandError? radioParamsError;
  DeviceCommandError? txPowerError;
  DeviceCommandError? tuningError;
  DeviceCommandError? selfInfoError;
  DeviceCommandError? deviceInfoError;
  DeviceCommandError? tuningParamsError;

  /// Last optional client-repeat byte sent with [setRadioParams].
  bool? lastClientRepeat;

  Future<void> _wait(Completer<void>? ack) async {
    if (ack != null) await ack.future;
  }

  @override
  Stream<LinkState> get state => _stateController.stream;

  @override
  LinkState get currentState => _state;

  @override
  Future<void> connect() async {
    calls.add('connect');
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
    calls.add('disconnect');
    if (_state == LinkState.disconnected) return;
    bus?.detach(this);
    _state = LinkState.disconnected;
    _stateController.add(_state);
  }

  @override
  void setRawRxListener(RawRxListener? listener) {
    calls.add('setRawRxListener');
    _rawRxListener = listener;
  }

  @override
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]) async {
    calls.add('sendRawPacket');
    transmitted.add(Uint8List.fromList(packet));
    transmitPriorities.add(priority);
    bus?.transmit(this, packet, snr, rssi);
    if (echoSelf) deliver(snr, rssi, packet);
    await _wait(rawTxAck);
  }

  /// Deliver an over-air frame to this link as `LOG_RX_DATA`.
  void deliver(double frameSnr, int frameRssi, Uint8List packet) {
    _rawRxListener?.call(frameSnr, frameRssi, Uint8List.fromList(packet));
  }

  @override
  Future<DeviceInfo> deviceInfo() async {
    calls.add('deviceInfo');
    if (deviceInfoError != null) throw deviceInfoError!;
    await _wait(deviceInfoAck);
    return deviceInfo_;
  }

  @override
  Future<ParsedSelfInfo> selfInfo() async {
    calls.add('selfInfo');
    if (selfInfoError != null) throw selfInfoError!;
    await _wait(selfInfoAck);
    return ParsedSelfInfo(
      publicKey: Uint8List(32),
      radioParams: _currentParams,
      nodeName: deviceNodeName,
      txPowerDbm: _currentParams.txPowerDbm,
      maxTxPower: maxTxPower,
      latitude: 0,
      longitude: 0,
      advType: advTypeChat,
    );
  }

  @override
  Future<RadioParams> radioParams() async {
    calls.add('radioParams');
    return _currentParams;
  }

  @override
  Future<void> setRadioParams(RadioParams params, {bool? clientRepeat}) async {
    calls.add('setRadioParams');
    lastClientRepeat = clientRepeat;
    if (radioParamsError != null) throw radioParamsError!;
    await _wait(radioParamsAck);
    _currentParams = params;
  }

  @override
  Future<void> setTxPower(int dbm) async {
    calls.add('setTxPower');
    if (txPowerError != null) throw txPowerError!;
    await _wait(txPowerAck);
    _currentParams = RadioParams(
      frequencyHz: _currentParams.frequencyHz,
      bandwidthHz: _currentParams.bandwidthHz,
      spreadingFactor: _currentParams.spreadingFactor,
      codingRate: _currentParams.codingRate,
      txPowerDbm: dbm,
    );
  }

  @override
  Future<void> reboot() async {
    calls.add('reboot');
    if (rebootError != null) throw rebootError!;
    rebootRequests++;
    if (rebootDisconnects && _state == LinkState.connected) {
      bus?.detach(this);
      _state = LinkState.disconnected;
      _stateController.add(_state);
    }
  }

  @override
  Future<void> shutdown() async {
    calls.add('shutdown');
    cliCommands.add('poweroff');
    if (shutdownError != null) throw shutdownError!;
    shutdownRequests++;
    if (shutdownDisconnects && _state == LinkState.connected) {
      bus?.detach(this);
      _state = LinkState.disconnected;
      _stateController.add(_state);
    }
  }

  @override
  Future<TuningParams> tuningParams() async {
    calls.add('tuningParams');
    if (tuningParamsError != null) throw tuningParamsError!;
    await _wait(tuningParamsAck);
    return _tuning;
  }

  @override
  Future<void> setTuningParams(TuningParams params) async {
    calls.add('setTuningParams');
    if (tuningError != null) throw tuningError!;
    await _wait(tuningAck);
    _tuning = params;
  }

  @override
  Future<void> setPathHashMode(int mode) async {
    calls.add('setPathHashMode');
    pathHashMode = mode;
  }

  @override
  Future<String> runCliCommand(String command) async {
    calls.add('runCliCommand');
    cliCommands.add(command);
    return cliReply;
  }

  @override
  Future<Uint8List?> exportPrivateKey() async {
    calls.add('exportPrivateKey');
    exportPrivateKeyRequests++;
    if (exportPrivateKeyDisabled) return null;
    return devicePrivateKey;
  }

  @override
  Future<Uint8List> getAllowedRepeatFreq() async {
    calls.add('getAllowedRepeatFreq');
    return allowedRepeatFreq;
  }

  /// Number of `CMD_EXPORT_PRIVATE_KEY` requests received (for tests).
  int exportPrivateKeyRequests = 0;
  int rebootRequests = 0;
  int shutdownRequests = 0;

  TuningParams _tuning =
      const TuningParams(rxDelayBaseMs: 0, airtimeFactorMs: 0);

  /// Last path-hash mode set via [setPathHashMode].
  int pathHashMode = 0;

  /// Every CLI command received (for test assertions).
  final List<String> cliCommands = [];
  String cliReply = '';

  @override
  Future<BatteryReading?> battery() async {
    calls.add('battery');
    batteryReads++;
    if (batteryError != null) throw batteryError!;
    await _wait(batteryAck);
    return batteryReading_;
  }

  /// Original params before any `setRadioParams` call.
  RadioParams get initialRadioParams => _initialParams;
}
