import 'dart:typed_data';

import 'package:companion_server/companion_server.dart';
import 'package:device_link/device_link.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'cli.dart';
import 'mesh_errors.dart';
import 'serial_queue.dart';

/// The attached physical radio's configuration and capability cache.
///
/// All physical writes are serialised here so a fresh repeat query, write ACK,
/// and readback cannot interleave with the next transaction. Read failures keep
/// the last known cache and mark it unverified; a write whose outcome is
/// uncertain is never retried automatically.
class PhysicalRadio {
  PhysicalRadio({
    required this.link,
    required this.prefs,
    required PhysicalCapabilities capabilities,
    required this.onPersist,
    required this.onConfigChanged,
  }) : _capabilities = capabilities;

  final RadioLink link;
  final NodePrefs prefs;
  final void Function() onPersist;
  final void Function() onConfigChanged;

  final _configQueue = SerialQueue();

  PhysicalCapabilities _capabilities;
  bool _cacheUncertain = false;
  bool _cacheVerified = true;
  bool _requiresReboot = false;
  bool _hasTuningCache = false;
  bool _tuningCacheVerified = false;
  bool _needsReconcile = false;
  String? _diagnostic;
  int _lastNoiseFloorDbm = 0;

  PhysicalCapabilities get capabilities => _capabilities;

  /// A write/timeout left the physical radio cache uncertain; do not retry the
  /// write automatically. Reconcile with a settings read or reconnect.
  bool get cacheUncertain => _cacheUncertain;

  /// The last confirmed radio cache came from a successful readback.
  bool get cacheVerified => _cacheVerified;

  /// A physical CLI `set radio` saved firmware prefs; a reboot is required for
  /// the active radio to match the saved values.
  bool get requiresReboot => _requiresReboot;

  bool get tuningCacheVerified => _tuningCacheVerified;

  /// Last physical-operation diagnostic (never contains secrets).
  String? get diagnostic => _diagnostic;

  int get lastNoiseFloorDbm => _lastNoiseFloorDbm;

  Future<void> get idle => _configQueue.idle;

  void setDiagnostic(String? value) => _diagnostic = value;

  void markRebooted() => _requiresReboot = false;

  void adoptCapabilities(PhysicalCapabilities capabilities) {
    _capabilities = capabilities;
    prefs.maxTxPower = capabilities.maxTxPower;
    onPersist();
  }

  Future<void> setRadioParams(
    int freqHz,
    int bwHz,
    int sf,
    int cr, {
    bool? clientRepeat,
  }) {
    return _configQueue.run(() async {
      if (freqHz < 150000000 || freqHz > 2500000000) {
        throw illegalArgument('frequency outside 150000-2500000 kHz');
      }
      if (bwHz < 7000 || bwHz > 500000) {
        throw illegalArgument('bandwidth outside 7000-500000 Hz');
      }
      if (sf < 5 || sf > 12 || cr < 5 || cr > 8) {
        throw illegalArgument('invalid spreading factor or coding rate');
      }

      var repeat = clientRepeat;
      if (_capabilities.firmwareVerCode < 9) {
        if (repeat != null) {
          throw const CompanionOperationError(
            errCodeUnsupportedCmd,
            message: 'client repeat requires physical firmware v9+',
          );
        }
      } else if (repeat == null) {
        // Preserve the current physical repeat: query it fresh and send an
        // explicit 0/1 byte. If the query fails, do not write.
        try {
          final info = await link.deviceInfo();
          if (info.clientRepeat != 0 && info.clientRepeat != 1) {
            throw illegalArgument('invalid physical client repeat');
          }
          repeat = info.clientRepeat == 1;
          _capabilities = _capabilities.copyWith(
            firmwareVerCode: info.firmwareVerCode,
            clientRepeat: info.clientRepeat,
            pathHashMode: info.pathHashMode,
          );
        } on DeviceCommandError catch (e) {
          // No write was attempted, so this is a query failure, not an
          // uncertain mutation.
          throw queryError(e);
        }
      }

      final params = RadioParams(
        frequencyHz: freqHz,
        bandwidthHz: bwHz,
        spreadingFactor: sf,
        codingRate: cr,
        txPowerDbm: prefs.txPowerDbm,
      );
      try {
        await link.setRadioParams(params, clientRepeat: repeat);
      } on DeviceCommandError catch (e) {
        if (e.mayHaveApplied) {
          _cacheUncertain = true;
          _cacheVerified = false;
          _needsReconcile = true;
        }
        _diagnostic = e.message ?? e.toString();
        throw operationError(e);
      }

      // The write was acknowledged: commit the confirmed requested values and
      // then attempt exactly one readback.
      prefs.frequencyHz = freqHz;
      prefs.bandwidthHz = bwHz;
      prefs.spreadingFactor = sf;
      prefs.codingRate = cr;
      if (repeat != null) {
        _capabilities = _capabilities.copyWith(clientRepeat: repeat ? 1 : 0);
      }
      _cacheUncertain = false;
      _cacheVerified = false;
      _diagnostic = null;
      onPersist();
      await _readBackSelfInfo();
    });
  }

  Future<void> setTxPower(int dbm) {
    return _configQueue.run(() async {
      if (dbm < -9) {
        throw illegalArgument('TX power below -9 dBm');
      }
      if (dbm > _capabilities.maxTxPower) {
        throw illegalArgument(
          'TX power $dbm exceeds physical maximum ${_capabilities.maxTxPower}',
        );
      }
      try {
        await link.setTxPower(dbm);
      } on DeviceCommandError catch (e) {
        if (e.mayHaveApplied) {
          _cacheUncertain = true;
          _cacheVerified = false;
          _needsReconcile = true;
        }
        _diagnostic = e.message ?? e.toString();
        throw operationError(e);
      }
      prefs.txPowerDbm = dbm;
      _cacheUncertain = false;
      _cacheVerified = false;
      _diagnostic = null;
      onPersist();
      await _readBackSelfInfo();
    });
  }

  /// One bounded SELF_INFO readback after a confirmed physical write. Failure is
  /// diagnostic only: the write was acknowledged, so the caller still succeeds
  /// with the requested values marked unverified.
  Future<void> _readBackSelfInfo({bool markReconcile = true}) async {
    try {
      final info = await link.selfInfo();
      _applyRadioParams(info.radioParams);
      prefs.maxTxPower = info.maxTxPower;
      _capabilities = _capabilities.copyWith(maxTxPower: info.maxTxPower);
      _cacheUncertain = false;
      _cacheVerified = true;
      _needsReconcile = false;
      _diagnostic = null;
      onPersist();
    } on DeviceCommandError catch (e) {
      _cacheVerified = false;
      _needsReconcile = markReconcile;
      _diagnostic = e.message ?? e.toString();
    }
    onConfigChanged();
  }

  void _applyRadioParams(RadioParams params) {
    prefs
      ..frequencyHz = params.frequencyHz
      ..bandwidthHz = params.bandwidthHz
      ..spreadingFactor = params.spreadingFactor
      ..codingRate = params.codingRate
      ..txPowerDbm = params.txPowerDbm;
  }

  void _applyTuningParams(TuningParams params) {
    prefs
      ..rxDelayBaseMs = params.rxDelayBaseMs
      ..airtimeFactorMs = params.airtimeFactorMs;
  }

  /// Adopt the connected device's actual radio parameters as the node's own
  /// without re-configuring the device (used at attach/reconnect time).
  ///
  /// Only RF/TX values belong to the physical radio. Path-hash mode, name,
  /// location and other preferences are virtual state and are deliberately not
  /// adopted here.
  void syncRadioParams(RadioParams params) {
    _applyRadioParams(params);
    _cacheUncertain = false;
    _cacheVerified = true;
    _needsReconcile = false;
    _diagnostic = null;
    onPersist();
  }

  Future<TuningParams> getTuningParams() {
    return _configQueue.run(() async {
      if (_needsReconcile) {
        _needsReconcile = false;
        await _readBackSelfInfo(markReconcile: false);
      }
      try {
        final params = await link.tuningParams();
        _applyTuningParams(params);
        _hasTuningCache = true;
        _tuningCacheVerified = true;
        _diagnostic = null;
        onPersist();
        onConfigChanged();
        return params;
      } on DeviceCommandError catch (e) {
        if (_hasTuningCache) {
          _tuningCacheVerified = false;
          _diagnostic = e.message ?? e.toString();
          return TuningParams(
            rxDelayBaseMs: prefs.rxDelayBaseMs,
            airtimeFactorMs: prefs.airtimeFactorMs,
          );
        }
        throw queryError(e);
      }
    });
  }

  Future<void> setTuningParams(int rxDelayBaseMs, int airtimeFactorMs) {
    return _configQueue.run(() async {
      final params = TuningParams(
        rxDelayBaseMs: rxDelayBaseMs,
        airtimeFactorMs: airtimeFactorMs,
      );
      try {
        await link.setTuningParams(params);
      } on DeviceCommandError catch (e) {
        if (e.mayHaveApplied) {
          _cacheUncertain = true;
          _cacheVerified = false;
          _needsReconcile = true;
        }
        _diagnostic = e.message ?? e.toString();
        throw operationError(e);
      }

      _applyTuningParams(params);
      _hasTuningCache = true;
      _tuningCacheVerified = false;
      _diagnostic = null;
      onPersist();
      try {
        final readBack = await link.tuningParams();
        _applyTuningParams(readBack);
        _tuningCacheVerified = true;
        onPersist();
      } on DeviceCommandError catch (e) {
        _tuningCacheVerified = false;
        _needsReconcile = true;
        _diagnostic = e.message ?? e.toString();
      }
      onConfigChanged();
    });
  }

  /// Run an allowlisted physical CLI command inside the config transaction and
  /// refresh the caches it may have changed.
  Future<String> runPhysicalCli(CliPhysicalCommand spec) {
    return _configQueue.run(() async {
      final text = await link.runCliCommand(spec.command);
      await _refreshPhysicalCliCaches(spec, text);
      return text;
    });
  }

  /// Record a physical CLI failure without retrying an uncertain write.
  void recordPhysicalCliFailure(DeviceCommandError e, CliPhysicalCommand spec) {
    _diagnostic = e.message ?? e.toString();
    if (e.mayHaveApplied) {
      if (spec.refreshRadio) {
        _cacheUncertain = true;
        _cacheVerified = false;
      }
      if (spec.refreshTuning) {
        _tuningCacheVerified = false;
      }
      _needsReconcile = true;
    }
  }

  void recordCliOperationFailure(CompanionOperationError e) {
    _diagnostic = e.message;
  }

  bool _cliTextIsError(String text) =>
      text.contains('Error') ||
      text.contains('ERROR') ||
      text.contains('Unknown command');

  Future<void> _refreshPhysicalCliCaches(
    CliPhysicalCommand spec,
    String reply,
  ) async {
    if (spec.savedRadio && !_cliTextIsError(reply)) {
      _requiresReboot = true;
    }
    if (spec.refreshRadio) {
      await _readBackSelfInfo();
    }
    if (spec.refreshTuning) {
      await _refreshTuningCacheDirect();
    }
    if (spec.refreshRadio || spec.refreshTuning) {
      onConfigChanged();
    }
  }

  /// Bounded tuning readback for the physical CLI transaction. Unlike
  /// [getTuningParams], this must not recursively take the config lock.
  Future<void> _refreshTuningCacheDirect() async {
    try {
      final params = await link.tuningParams();
      _applyTuningParams(params);
      _hasTuningCache = true;
      _tuningCacheVerified = true;
      _diagnostic = null;
      onPersist();
    } on DeviceCommandError catch (e) {
      _tuningCacheVerified = false;
      _needsReconcile = true;
      _diagnostic = e.message ?? e.toString();
    }
  }

  Future<Uint8List> getAllowedRepeatFreq() async {
    try {
      return await link.getAllowedRepeatFreq();
    } on DeviceCommandError catch (e) {
      throw queryError(e);
    }
  }

  /// Adopt a shared physical snapshot without touching the device.
  ///
  /// Used to keep inactive identities' `SELF_INFO`/tuning values consistent
  /// with the active identity after attach, reconnect, or a confirmed write.
  void syncPhysicalState({
    RadioParams? params,
    TuningParams? tuning,
    PhysicalCapabilities? capabilities,
  }) {
    if (params != null) {
      _applyRadioParams(params);
      _cacheUncertain = false;
      _cacheVerified = true;
      _needsReconcile = false;
    }
    if (tuning != null) {
      _applyTuningParams(tuning);
      _hasTuningCache = true;
      _tuningCacheVerified = true;
    }
    if (capabilities != null) _capabilities = capabilities;
    _diagnostic = null;
    onPersist();
  }

  /// Refresh the relayed physical noise floor, keeping the last known value when
  /// the device link is briefly unavailable.
  Future<int> refreshNoiseFloor() async {
    if (link.currentState != LinkState.connected) return _lastNoiseFloorDbm;
    try {
      _lastNoiseFloorDbm = (await link.radioStats()).noiseFloorDbm;
    } catch (_) {
      // Keep the last known physical value rather than reporting 0.
    }
    return _lastNoiseFloorDbm;
  }
}
