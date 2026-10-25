import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'radio_link.dart';

/// One physical [RadioLink] shared by several virtual node runtimes.
///
/// The hub owns the single raw-RX registration on the base link, fans every
/// frame out to all subscribed views, and serializes raw transmissions so two
/// identities can never have overlapping `sendRawPacket` calls. Each identity
/// receives a stable [RadioLinkView] from [viewFor].
class SharedRadioHub {
  SharedRadioHub(
    this.base, {
    this.batteryFreshFor = const Duration(seconds: 10),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final RadioLink base;

  /// Successful battery samples are reused for this long, matching the node's
  /// `BatteryService` freshness window.
  final Duration batteryFreshFor;

  final DateTime Function() _now;
  final Map<String, _SharedRadioLinkView> _views = {};
  final List<_SharedRadioLinkView> _subscribed = [];
  bool _attached = false;
  bool _disposed = false;

  BatteryReading? _batteryCache;
  DateTime? _batteryCachedAt;
  Future<BatteryReading?>? _batteryInFlight;
  Future<void> _txTail = Future<void>.value();

  /// Return the stable view for [identityId]. The view delegates lifecycle,
  /// configuration, and state to the shared base link.
  RadioLink viewFor(String identityId) => _views.putIfAbsent(
        identityId,
        () => _SharedRadioLinkView(this, identityId),
      );

  /// Register the hub as the base link's raw-RX listener.
  void attach() {
    if (_disposed) throw StateError('SharedRadioHub has been disposed');
    _attached = true;
    base.setRawRxListener(_dispatch);
  }

  /// Clear the base listener. Views and their subscriptions are retained so a
  /// reconnect can call [attach] again without rebuilding the runtimes.
  Future<void> detach() async {
    _attached = false;
    base.setRawRxListener(null);
    _batteryCache = null;
    _batteryCachedAt = null;
    _batteryInFlight = null;
    await _txTail;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _attached = false;
    _subscribed.clear();
    _views.clear();
    base.setRawRxListener(null);
  }

  bool get isAttached => _attached;

  void _subscribe(_SharedRadioLinkView view) {
    if (!_subscribed.contains(view)) _subscribed.add(view);
  }

  void _unsubscribe(_SharedRadioLinkView view) => _subscribed.remove(view);

  void _dispatch(double snr, int rssi, Uint8List raw) {
    if (!_attached || _disposed) return;
    // Copy before iteration: a listener may remove itself while handling the
    // frame, and one failure must not starve the identities after it.
    for (final view in List<_SharedRadioLinkView>.of(_subscribed)) {
      final listener = view._listener;
      if (listener == null) continue;
      try {
        listener(snr, rssi, Uint8List.fromList(raw));
      } catch (_) {
        // Listener isolation is intentional; the node owns its diagnostics.
      }
    }
  }

  Future<void> _send(Uint8List packet, int priority) {
    final completer = Completer<void>();
    _txTail = _txTail.then((_) async {
      try {
        await base.sendRawPacket(packet, priority);
        completer.complete();
      } catch (e, s) {
        completer.completeError(e, s);
      }
    });
    return completer.future;
  }

  Future<BatteryReading?> _battery() {
    final cachedAt = _batteryCachedAt;
    final cache = _batteryCache;
    if (cachedAt != null &&
        cache != null &&
        _now().difference(cachedAt) < batteryFreshFor) {
      return Future<BatteryReading?>.value(cache);
    }
    final pending = _batteryInFlight;
    if (pending != null) return pending;

    late Future<BatteryReading?> future;
    future = base.battery().then((reading) {
      if (reading != null) {
        _batteryCache = reading;
        _batteryCachedAt = _now();
      }
      return reading;
    }).whenComplete(() {
      if (identical(_batteryInFlight, future)) _batteryInFlight = null;
    });
    _batteryInFlight = future;
    return future;
  }
}

/// A per-identity [RadioLink] facade over [SharedRadioHub].
class _SharedRadioLinkView implements RadioLink {
  _SharedRadioLinkView(this._hub, this.identityId);

  final SharedRadioHub _hub;
  final String identityId;
  RawRxListener? _listener;

  @override
  void setRawRxListener(RawRxListener? listener) {
    _listener = listener;
    if (listener == null) {
      _hub._unsubscribe(this);
    } else {
      _hub._subscribe(this);
    }
  }

  @override
  Future<void> connect() =>
      throw UnsupportedError('the device session owns the shared link');

  @override
  Future<void> disconnect() =>
      throw UnsupportedError('the device session owns the shared link');

  @override
  Stream<LinkState> get state => _hub.base.state;

  @override
  LinkState get currentState => _hub.base.currentState;

  @override
  Future<void> sendRawPacket(Uint8List packet, [int priority = 0]) =>
      _hub._send(packet, priority);

  @override
  Future<DeviceInfo> deviceInfo() => _hub.base.deviceInfo();

  @override
  Future<ParsedSelfInfo> selfInfo() => _hub.base.selfInfo();

  @override
  Future<RadioParams> radioParams() => _hub.base.radioParams();

  @override
  Future<void> setRadioParams(RadioParams params, {bool? clientRepeat}) =>
      _hub.base.setRadioParams(params, clientRepeat: clientRepeat);

  @override
  Future<void> setTxPower(int dbm) => _hub.base.setTxPower(dbm);

  @override
  Future<void> reboot() => _hub.base.reboot();

  @override
  Future<void> shutdown() => _hub.base.shutdown();

  @override
  Future<BatteryReading?> battery() => _hub._battery();

  @override
  Future<TuningParams> tuningParams() => _hub.base.tuningParams();

  @override
  Future<void> setTuningParams(TuningParams params) =>
      _hub.base.setTuningParams(params);

  @override
  Future<void> setPathHashMode(int mode) => _hub.base.setPathHashMode(mode);

  @override
  Future<String> runCliCommand(String command) =>
      _hub.base.runCliCommand(command);

  @override
  Future<Uint8List> getAllowedRepeatFreq() =>
      _hub.base.getAllowedRepeatFreq();
}
