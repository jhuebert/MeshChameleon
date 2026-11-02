import 'package:mesh_protocol/mesh_protocol.dart';

import 'network_address.dart';
import 'session_store.dart';

/// Owns the persisted last-session settings: the saved device target, the
/// app-facing proxy port, auto-resume, and the intentional-shutdown flag.
///
/// Writes are best-effort: a failed save is logged and never turns an
/// already-attached radio into a failed connection. Callers publish the change
/// to the UI after the operation completes.
class SessionSettings {
  SessionSettings({
    required this.store,
    required this.onLog,
  });

  final SessionStore store;
  final void Function(String message) onLog;

  SessionConfig? _lastSession;
  bool _autoResume = false;
  bool _intentionallyOff = false;
  int port = defaultCompanionPort;

  SessionConfig? get lastSession => _lastSession;
  bool get autoResume => _autoResume;
  bool get intentionallyOff => _intentionallyOff;

  /// Restore persisted settings.
  ///
  /// A missing session clears the resume and shutdown flags but leaves the
  /// port at its current value.
  Future<void> load() async {
    final session = await store.load();
    _lastSession = session;
    if (session != null) {
      port = session.proxyPort;
      _autoResume = session.autoResume;
      _intentionallyOff = session.intentionallyOff;
    } else {
      _autoResume = false;
      _intentionallyOff = false;
    }
  }

  /// Remember a successfully attached session.
  ///
  /// An explicit connect also clears a previous intentional shutdown so the
  /// next launch resumes normally.
  Future<void> record(SessionConfig session) async {
    _lastSession = session;
    _intentionallyOff = false;
    await _save(session, 'Could not save the last session');
  }

  /// Change the app-facing proxy port.
  ///
  /// The in-memory port changes even when no session is saved yet; the last
  /// session is updated with the same port when present.
  Future<bool> setPort(int value) async {
    if (!isValidTcpPort(value)) return false;
    port = value;
    final current = _lastSession;
    if (current != null) {
      final updated = current.copyWith(proxyPort: value);
      _lastSession = updated;
      await _save(updated, 'Could not save the proxy port');
    }
    return true;
  }

  /// Toggle automatic session restore.
  Future<void> setAutoResume(bool value) async {
    _autoResume = value;
    final current = _lastSession;
    if (current != null) {
      final updated = current.copyWith(autoResume: value);
      _lastSession = updated;
      await _save(updated, 'Could not save the resume setting');
    }
  }

  /// Suppress automatic reconnect after a physical shutdown.
  ///
  /// The in-memory flag is set synchronously; the returned future completes
  /// once the flag is persisted.
  Future<void> markPoweredOff() async {
    _intentionallyOff = true;
    final current = _lastSession;
    if (current == null) return;
    final updated = current.copyWith(intentionallyOff: true);
    _lastSession = updated;
    await _save(updated, 'Could not persist intentional shutdown');
  }

  Future<void> _save(SessionConfig session, String failureMessage) async {
    try {
      await store.save(session);
    } catch (e) {
      onLog('$failureMessage: $e');
    }
  }
}
