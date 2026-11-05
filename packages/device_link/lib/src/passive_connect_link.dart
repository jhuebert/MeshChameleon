/// A radio link that can wait for the operating system to restore a connection.
///
/// BLE implements this with an OS-level `autoConnect` request: the request stays
/// registered while the companion is out of range and completes when it is seen
/// again. A transport without passive support simply does not implement this
/// interface.
abstract interface class PassiveConnectLink {
  /// Ask the OS to connect when the device is next seen.
  ///
  /// Returns once the request is registered, not once connected. Repeated calls
  /// are idempotent while a request is already armed.
  Future<void> startPassiveConnect();

  /// Remove the request and cancel any pending connection attempt.
  Future<void> stopPassiveConnect();
}

/// A radio link with a connection attempt that can be abandoned immediately.
///
/// BLE uses this to skip the platform operation queue when the user cancels or
/// disconnects while a connect is still in flight.
abstract interface class CancelableConnect {
  Future<void> cancelInFlightConnect();
}
