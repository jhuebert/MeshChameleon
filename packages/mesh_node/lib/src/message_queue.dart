import 'package:mesh_protocol/mesh_protocol.dart';

/// FIFO of inbound messages waiting for `CMD_SYNC_NEXT_MESSAGE`.
class MessageQueue {
  MessageQueue({required this.maxQueueSize});

  final int maxQueueSize;
  final List<QueuedMessage> _messages = [];

  List<QueuedMessage> get messages => _messages;

  int get length => _messages.length;

  int get directCount => _messages.where((m) => !m.isChannel).length;

  int get channelCount => _messages.where((m) => m.isChannel).length;

  /// The oldest message, cloned for delivery.
  QueuedMessage? peek() => _messages.isEmpty ? null : _messages.first.clone();

  /// Cloned queue with the oldest message removed.
  List<QueuedMessage> candidateWithoutFirst() => [
        for (final m in _messages.skip(1)) m.clone(),
      ];

  /// Cloned queue with [message] appended, dropping oldest entries on overflow.
  List<QueuedMessage> candidateWith(QueuedMessage message) {
    final candidate = [
      for (final m in _messages) m.clone(),
      message.clone(),
    ];
    while (candidate.length > maxQueueSize) {
      candidate.removeAt(0); // drop oldest on overflow
    }
    return candidate;
  }

  void replace(Iterable<QueuedMessage> messages) {
    _messages
      ..clear()
      ..addAll(messages);
  }

  void removeFirst() {
    if (_messages.isNotEmpty) _messages.removeAt(0);
  }
}
