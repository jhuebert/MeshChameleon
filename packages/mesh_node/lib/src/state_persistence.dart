import 'dart:async';
import 'dart:io';

import 'package:companion_server/companion_server.dart';
import 'package:mesh_protocol/mesh_protocol.dart';

import 'node_store.dart';
import 'serial_queue.dart';

/// Serialises durable node-state mutations and publication.
///
/// A save failure leaves live state untouched; an identity-generation check
/// before and after the save prevents a completion from the previous identity
/// from publishing over a successful switch.
class StatePersistence {
  StatePersistence({
    required this.store,
    required this.storageQuotaBytes,
    required this.snapshot,
    required this.publish,
    required this.isRetired,
    required this.isResetting,
    required this.isCurrent,
    required this.onStateChanged,
  });

  final NodeStore? store;
  final int storageQuotaBytes;
  final NodeState Function() snapshot;
  final void Function(NodeState state) publish;
  final bool Function() isRetired;
  final bool Function() isResetting;
  final bool Function(int generation) isCurrent;
  final void Function() onStateChanged;

  final SerialQueue _queue = SerialQueue();

  Future<void> get idle => _queue.idle;

  /// Run [action] on the same serial queue used for state publication.
  Future<T> run<T>(Future<T> Function() action) => _queue.run(action);

  int get storageUsedBytes => snapshot().storageBytes;

  /// Save a candidate, then publish it. A save failure leaves node state
  /// untouched so the client sees an honest error.
  Future<void> commit(NodeState candidate, {int? identityGeneration}) {
    if (isRetired()) {
      return Future<void>.error(const CompanionOperationError(
        errCodeBadState,
        message: 'mesh node has been retired',
      ));
    }
    if (isResetting()) {
      return Future<void>.error(const CompanionOperationError(
        errCodeBadState,
        message: 'virtual reset in progress',
      ));
    }
    return _queue.run(() async {
      if (identityGeneration != null && !isCurrent(identityGeneration)) {
        return;
      }
      await _save(candidate);
      if (identityGeneration != null && !isCurrent(identityGeneration)) {
        return;
      }
      publish(candidate);
      onStateChanged();
    });
  }

  /// Flush pending writes, then durably replace and publish [state].
  Future<void> replace(NodeState state) async {
    await _queue.run(() async {
      await store?.flush();
      await _save(state);
      publish(state);
    });
    onStateChanged();
  }

  /// Fire-and-forget persistence for internal state updates. Client-facing
  /// durable mutations use the awaitable [commit] path instead.
  void persist() {
    if (isRetired()) return;
    unawaited(_persistCurrent());
  }

  Future<void> _persistCurrent() async {
    if (isRetired()) return;
    try {
      await _queue.run(() async {
        await _save(snapshot());
      });
    } on CompanionOperationError {
      // Reported through the mutation that triggered persistence.
    }
  }

  Future<void> flush() async => store?.flush();

  Future<void> _save(NodeState state) async {
    final s = store;
    _checkQuota(state);
    if (s == null) return;
    try {
      await s.save(state);
    } on NodeStorageQuotaError {
      throw CompanionOperationError(
        errCodeTableFull,
        message: 'virtual storage quota exceeded',
      );
    } on FileSystemException catch (e) {
      throw CompanionOperationError(
        errCodeFileIoError,
        message: 'persistence failed: ${e.message}',
      );
    } catch (e) {
      throw CompanionOperationError(
        errCodeFileIoError,
        message: 'persistence failed',
      );
    }
  }

  void _checkQuota(NodeState candidate) {
    final bytes = candidate.storageBytes;
    if (bytes <= storageQuotaBytes) return;
    final current = snapshot().storageBytes;
    // Allow shrinking mutations of legacy over-quota state.
    if (bytes <= current) return;
    throw const CompanionOperationError(
      errCodeTableFull,
      message: 'virtual storage quota exceeded',
    );
  }
}
