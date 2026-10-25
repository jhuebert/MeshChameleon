import 'dart:typed_data';

import 'package:mesh_node/mesh_node.dart';

/// In-process virtual mesh shared by the live identity runtimes.
///
/// Every outbound packet is mirrored to every other live node. No destination
/// lookup, route rewrite, or RF suppression happens here.
class LocalMeshRouter implements LocalPeerRouter {
  LocalMeshRouter({
    required Iterable<MeshNode> Function() liveNodes,
    Uint8List? Function()? blockedPeer,
    void Function(String message)? onLog,
  })  : _liveNodes = liveNodes,
        _blockedPeer = blockedPeer,
        _onLog = onLog;

  final Iterable<MeshNode> Function() _liveNodes;
  final Uint8List? Function()? _blockedPeer;
  final void Function(String message)? _onLog;

  @override
  bool isBlockedPeer(Uint8List publicKey) {
    final blocked = _blockedPeer?.call();
    return blocked != null && _bytesEqual(blocked, publicKey);
  }

  @override
  Future<void> mirrorOutbound(
    Uint8List packet, {
    required Uint8List fromPublicKey,
  }) async {
    for (final node in _liveNodes().toList()) {
      if (_bytesEqual(node.identity.publicKey, fromPublicKey)) continue;
      try {
        await node.receiveLocal(packet);
      } catch (e) {
        _onLog?.call('Local mirror to one identity failed: $e');
      }
    }
  }
}

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
