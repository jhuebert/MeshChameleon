import 'dart:math' as math;

/// Standard LoRa time-on-air in microseconds for a frame of [payloadBytes].
///
/// Uses the Semtech formula:
///
///   Tsym = 2^SF / BW
///   lowDataRateOptimize (DE) = 1 if Tsym > 16 ms else 0
///   payloadSymbols = max(ceil((8*PL - 4*SF + 28 + 16*CRC - 20*IH)
///                             / (4*(SF - 2*DE))) * CR, 0)
///   ToA = (preamble + 4.25) * Tsym + (8 + payloadSymbols) * Tsym
///
/// [codingRate] is in the firmware/RadioLib 5..8 domain (5 = 4/5 … 8 = 4/8).
/// This mirrors `meshcore-open`'s `utils/lora_airtime.dart` and is used to
/// approximate the firmware's TX/RX airtime counters.
int loraTimeOnAirMicros({
  required int payloadBytes,
  required int spreadingFactor,
  required int bandwidthHz,
  required int codingRate,
  int preambleSymbols = 8,
  bool crc = true,
  bool explicitHeader = true,
}) {
  assert(spreadingFactor >= 5 && spreadingFactor <= 12);
  assert(bandwidthHz > 0);
  assert(codingRate >= 5 && codingRate <= 8);

  final pl = math.max(payloadBytes, 0);
  final sf = spreadingFactor;

  // Symbol time in milliseconds.
  final tsymMs = (1 << sf) / (bandwidthHz / 1000.0);

  // Low data rate optimisation is mandated when a symbol lasts over 16 ms.
  final de = tsymMs > 16.0 ? 1 : 0;
  final ih = explicitHeader ? 0 : 1;

  final numerator = 8 * pl - 4 * sf + 28 + 16 * (crc ? 1 : 0) - 20 * ih;
  final denominator = 4 * (sf - 2 * de);
  final payloadSymbols = math.max(
    (numerator / denominator).ceil() * codingRate,
    0,
  );

  final preambleMs = (preambleSymbols + 4.25) * tsymMs;
  final payloadMs = (8 + payloadSymbols) * tsymMs;
  return ((preambleMs + payloadMs) * 1000).round();
}
