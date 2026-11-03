import 'package:companion_server/companion_server.dart';

import 'identity_index.dart';
import 'identity_manager.dart';

/// Identity catalog operations, separated from the app composition root.
///
/// The controller owns the busy/notify/log sequence for each mutation and
/// leaves manager creation and loading to the owner. Read-only catalog state
/// stays on the owner's manager; this class only mutates it.
class IdentityController {
  IdentityController({
    required this.ensureManager,
    required this.currentManager,
    required this.isBusy,
    required this.setBusy,
    required this.notify,
    required this.log,
    required this.updateNotification,
    required this.proxyServer,
  });

  final Future<IdentityManager> Function() ensureManager;
  final IdentityManager? Function() currentManager;
  final bool Function() isBusy;
  final void Function(bool busy) setBusy;
  final void Function() notify;
  final void Function(String message) log;
  final Future<void> Function() updateNotification;
  final CompanionServer? Function() proxyServer;

  Future<String> suggestName() async {
    final manager = await ensureManager();
    return manager.suggestName();
  }

  /// Create an additional identity. It is inactive; the active selection does
  /// not change.
  Future<IdentityRecord?> create({String? name}) async {
    if (isBusy()) return null;
    if (currentManager()?.databaseError != null) return null;
    setBusy(true);
    notify();
    try {
      final manager = await ensureManager();
      final record = await manager.create(name: name);
      log('Created identity ${record.name}');
      await updateNotification();
      return record;
    } catch (e) {
      log('Could not create identity: $e');
      return null;
    } finally {
      setBusy(false);
      notify();
    }
  }

  /// Make [id] the identity served to the MeshCore app.
  Future<bool> activate(String id) async {
    if (isBusy()) return false;
    final manager = currentManager();
    if (manager == null) return false;
    if (manager.activeId == id) return true;
    setBusy(true);
    notify();
    try {
      final runningServer = proxyServer();
      final ok = await manager.activate(
        id,
        switchBridge: runningServer?.switchBridge,
      );
      if (ok) {
        final name = manager.activeSummary?.name ?? id;
        log('Activated identity $name');
        await updateNotification();
      }
      return ok;
    } catch (e) {
      log('Identity activation failed: $e');
      return false;
    } finally {
      setBusy(false);
      notify();
    }
  }

  /// Enable or disable an identity. The active identity cannot be disabled.
  Future<bool> setEnabled(String id, bool enabled) async {
    if (isBusy()) return false;
    final manager = currentManager();
    if (manager == null) return false;
    setBusy(true);
    notify();
    try {
      final ok = await manager.setEnabled(id, enabled);
      if (ok) {
        final summary = manager.summaries.firstWhere(
          (identity) => identity.id == id,
        );
        log('${enabled ? 'Enabled' : 'Disabled'} identity ${summary.name}');
        await updateNotification();
      }
      return ok;
    } catch (e) {
      log('Could not ${enabled ? 'enable' : 'disable'} identity: $e');
      return false;
    } finally {
      setBusy(false);
      notify();
    }
  }

  /// Delete an inactive identity. The manager and repository enforce the
  /// active/last-identity rules.
  Future<bool> delete(String id) async {
    if (isBusy()) return false;
    final manager = currentManager();
    if (manager == null) return false;
    setBusy(true);
    notify();
    try {
      await manager.delete(id);
      log('Deleted one identity');
      await updateNotification();
      return true;
    } catch (e) {
      log('Could not delete identity: $e');
      return false;
    } finally {
      setBusy(false);
      notify();
    }
  }

  /// Clear contacts, channels, messages, advert paths, and non-name prefs for
  /// one identity while keeping its key and current name.
  Future<bool> clearLocalData(String id) async {
    if (isBusy()) return false;
    final manager = currentManager();
    if (manager == null) return false;
    setBusy(true);
    notify();
    try {
      final wasActive = manager.activeId == id;
      await manager.clearLocalData(id);
      final server = proxyServer();
      if (wasActive && (server?.hasClient ?? false)) {
        await server!.disconnectClient(reason: 'local data cleared');
      }
      log('Cleared local data for one identity');
      return true;
    } catch (e) {
      log('Could not clear local identity data: $e');
      return false;
    } finally {
      setBusy(false);
      notify();
    }
  }
}
