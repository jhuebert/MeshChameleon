import 'dart:typed_data';

import 'package:device_link/device_link.dart';
import 'package:mesh_node/mesh_node.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'identity_index.dart';

/// Non-secret presentation data for one identity card.
class IdentitySummary {
  const IdentitySummary({
    required this.id,
    required this.name,
    required this.publicKey,
    required this.createdAt,
    required this.active,
    required this.live,
    required this.keyAvailable,
    required this.channelCount,
    required this.contactCount,
    required this.queuedDirect,
    required this.queuedChannel,
    this.unavailableReason,
  });

  final String id;
  final String name;
  final Uint8List publicKey;
  final int createdAt;
  final bool active;
  final bool live;
  final bool keyAvailable;
  final int channelCount;
  final int contactCount;
  final int queuedDirect;
  final int queuedChannel;
  final String? unavailableReason;

  /// First 4 public-key bytes (8 hex characters).
  String get prefixHex => bytesToHex(
        publicKey.sublist(0, publicKey.length < 4 ? publicKey.length : 4),
      ).toUpperCase();

  int get queuedTotal => queuedDirect + queuedChannel;
}

/// Live objects for one identity while a device is attached.
class IdentityRuntime {
  IdentityRuntime(this.record);

  IdentityRecord record;
  LocalIdentity? identity;
  MeshNode? node;
  NodeStore? store;
  RadioLink? linkView;
  String? unavailableReason;

  bool get live => node != null;
  bool get keyAvailable => identity != null;

  void clear() {
    node = null;
    identity = null;
    store = null;
    linkView = null;
  }
}
