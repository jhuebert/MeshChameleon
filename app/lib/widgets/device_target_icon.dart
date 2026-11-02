import 'package:flutter/material.dart';

import '../services/session_store.dart';

/// Icon representing a saved device transport.
IconData deviceTargetIcon(DeviceTargetKind? kind) => switch (kind) {
      DeviceTargetKind.ble => Icons.bluetooth_connected,
      DeviceTargetKind.tcp => Icons.lan,
      DeviceTargetKind.simulated => Icons.science_outlined,
      null => Icons.devices_other,
    };
