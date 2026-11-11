import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

import 'battery_service.dart';
import 'phone_location.dart';

/// Builds the CayenneLPP payload shared by remote replies and self telemetry.
///
/// Identity-generation checks belong to the caller: this collaborator has no
/// access to the runtime guard.
class TelemetryAssembler {
  TelemetryAssembler({
    required BatteryService battery,
    required NodePrefs prefs,
    required bool Function() gpsEnabled,
    required VirtualLocationFix? Function() locationFix,
    required Future<int?> Function()? readPhoneBatteryPercent,
    this.phoneBatteryTimeout = const Duration(seconds: 1),
  })  : _battery = battery,
        _prefs = prefs,
        _gpsEnabled = gpsEnabled,
        _locationFix = locationFix,
        _readPhoneBatteryPercent = readPhoneBatteryPercent;

  final BatteryService _battery;
  final NodePrefs _prefs;
  final bool Function() _gpsEnabled;
  final VirtualLocationFix? Function() _locationFix;
  final Future<int?> Function()? _readPhoneBatteryPercent;
  final Duration phoneBatteryTimeout;

  /// Assemble voltage, optional GPS, and optional phone percentage.
  Future<Uint8List> build(int permissions) async {
    final millivolts = await _battery.refresh(force: true);
    final w = BufferWriter()
      ..writeBytes(
        encodeSelfVoltageTelemetry(
          millivolts,
        ),
      );

    if ((permissions & telemPermLocation) != 0 &&
        _gpsEnabled() &&
        (_prefs.latitude != 0 || _prefs.longitude != 0)) {
      final fix = _locationFix();
      w.writeBytes(
        encodeTelemetryGps(
          telemChannelSelf,
          _prefs.latitude,
          _prefs.longitude,
          fix?.altitudeMeters,
        ),
      );
    }

    if ((permissions & telemPermBase) != 0) {
      final percent = await _readPhonePercent();
      if (percent != null) {
        w.writeBytes(encodeTelemetryPercentage(telemChannelSelf, percent));
      }
    }
    return w.toBytes();
  }

  Future<int?> _readPhonePercent() async {
    final read = _readPhoneBatteryPercent;
    if (read == null) return null;
    try {
      return await read().timeout(phoneBatteryTimeout);
    } catch (_) {
      return null;
    }
  }
}
