import 'dart:collection';

import 'package:mesh_protocol/mesh_protocol.dart';

/// FIFO of inbound messages waiting for `CMD_SYNC_NEXT_MESSAGE`.
class MessageQueue {
  MessageQueue({required this.maxQueueSize});

  final int maxQueueSize;
  final List<QueuedMessage> _messages = [];

  /// Queued messages in delivery order (read-only).
  List<QueuedMessage> get messages => UnmodifiableListView(_messages);

  int get length => _messages.length;

  int get directCount => _messages.where((m) => !m.isChannel).length;

  int get channelCount => _messages.where((m) => m.isChannel).length;

  void replace(Iterable<QueuedMessage> messages) {
    _messages
      ..clear()
      ..addAll(messages);
  }
}
