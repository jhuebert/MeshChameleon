/// Owns the node's identity generation and lifecycle blocking state.
///
/// Collaborators receive snapshots of this guard's state instead of reading
/// several independent booleans from the facade. A token is only current when
/// it matches the generation and no lifecycle transition is blocking work.
class RuntimeGuard {
  int _generation = 0;
  bool _retired = false;
  bool _poweredOff = false;
  bool _resetting = false;
  bool _swapping = false;
  bool _paused = false;

  int get generation => _generation;
  bool get retired => _retired;
  bool get poweredOff => _poweredOff;
  bool get resetting => _resetting;
  bool get swapping => _swapping;
  bool get paused => _paused;

  /// Identity storage is paused or being replaced.
  bool get identityBlocked => _paused || _swapping;

  /// No semantic TX/RX or persistence work may proceed.
  bool get blocked => _retired || _poweredOff || _resetting || identityBlocked;

  /// Whether [token] still identifies the active identity generation.
  bool isCurrent(int token) => !blocked && token == _generation;

  void powerOn() => _poweredOff = false;

  void powerOff() => _poweredOff = true;

  void retire() => _retired = true;

  void beginSwap() => _swapping = true;

  void endSwap() => _swapping = false;

  void pause() => _paused = true;

  void resume() => _paused = false;

  void beginReset() => _resetting = true;

  void endReset() => _resetting = false;

  /// Advance the identity generation and return the new token.
  int bumpGeneration() => ++_generation;
}
