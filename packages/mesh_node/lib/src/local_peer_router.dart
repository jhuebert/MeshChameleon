import 'dart:typed_data';

/// In-process delivery path between virtual identities sharing one radio.
///
/// The router mirrors every packet a live identity transmits to every other
/// live runtime. It intentionally has no destination lookup: recipients apply
/// their normal decrypt/dedup/filter logic, exactly as if they had received the
/// frame over the air.
abstract class LocalPeerRouter {
  /// True when [publicKey] is the attached radio's own companion identity.
  ///
  /// That identity cannot be reached through the raw-radio path, so direct
  /// sends must be rejected instead of silently disappearing.
  bool isBlockedPeer(Uint8List publicKey);

  /// Deliver the exact outbound [packet] bytes to every live local identity
  /// except the sender identified by [fromPublicKey].
  ///
  /// Failures are isolated per peer and never fail the RF transmission.
  Future<void> mirrorOutbound(
    Uint8List packet, {
    required Uint8List fromPublicKey,
  });
}
