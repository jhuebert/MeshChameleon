/// Lifecycle of the physical device link.
///
/// [connected] means the physical link is up; [reconnecting] and [waiting] are
/// recovery states where the MeshCore client may still be served or has been
/// disconnected deliberately.
enum DeviceLinkPhase {
  idle,
  connecting,
  connected,
  reconnecting,
  waiting,
  disconnecting,
}
