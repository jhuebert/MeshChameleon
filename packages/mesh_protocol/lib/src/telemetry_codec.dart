import 'dart:typed_data';

import 'buffer.dart';
import 'constants.dart';

/// Encode the local node's CayenneLPP voltage entry: `channel | 0x74 | u16 BE`.
///
/// The value is millivolts divided by 10 (0.01 V units) and clamped to the
/// representable unsigned range.
Uint8List encodeSelfVoltageTelemetry(int millivolts) => (BufferWriter()
      ..writeByte(telemChannelSelf)
      ..writeByte(0x74) // CayenneLPP voltage, 0.01 V
      ..writeUInt16Be((millivolts / 10).round().clamp(0, 0xFFFF)))
    .toBytes();
