/// A phone-sourced GPS fix held in memory and applied to a virtual node.
class VirtualLocationFix {
  const VirtualLocationFix({
    required this.latitude,
    required this.longitude,
    this.altitudeMeters,
    required this.capturedAt,
  });

  final double latitude;
  final double longitude;

  /// Altitude above the WGS-84 ellipsoid when the platform reported one.
  final double? altitudeMeters;

  /// Wall-clock time the fix was captured.
  final DateTime capturedAt;
}
