import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mesh_protocol/mesh_protocol.dart';

export 'framed_client.dart' show FramedClient, StreamQueue;

/// A serial-framed TCP client for companion-protocol tests.
class FramedClient {
  FramedClient(this._socket) {
    _socket.listen((data) {
      for (final frame in _codec.ingest(data)) {
        _controller.add(frame);
      }
    });
  }

  final Socket _socket;
  final SerialFrameCodec _codec = SerialFrameCodec.bidirectional();
  final StreamController<Uint8List> _controller =
      StreamController<Uint8List>.broadcast();
  late final StreamQueue<Uint8List> frames = StreamQueue(_controller.stream);

  void send(List<int> payload) =>
      sendFrame(payload, prefix: frameInboundPrefix);

  void sendFrame(List<int> payload, {required int prefix}) {
    _socket.add(_codec.encodeFrame(payload, prefix: prefix));
  }

  /// Wait for the next frame, throwing when [timeout] elapses.
  Future<Uint8List> next({
    bool pushes = false,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final frame = await frames.nextWithin(timeout);
    if (frame == null) {
      throw TimeoutException('no frame within $timeout', timeout);
    }
    return frame;
  }

  /// Wait until a frame starts with [code]; return false on timeout.
  Future<bool> awaitCode(int code, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) return false;
      final frame = await frames.nextWithin(remaining);
      if (frame == null) return false;
      if (frame.isNotEmpty && frame[0] == code) return true;
    }
  }

  Future<void> close() async {
    await _controller.close();
    await _socket.close();
  }
}

/// Minimal stream queue used to await the next framed payload.
class StreamQueue<T> {
  StreamQueue(Stream<T> stream) {
    _subscription = stream.listen(_add);
  }

  late final StreamSubscription<T> _subscription;
  final List<T> _buffer = [];
  final List<Completer<T>> _waiters = [];

  Future<T> next() {
    if (_buffer.isNotEmpty) return Future.value(_buffer.removeAt(0));
    final completer = Completer<T>();
    _waiters.add(completer);
    return completer.future;
  }

  /// Returns null when no value arrives within [timeout].
  Future<T?> nextWithin(Duration timeout) async {
    if (_buffer.isNotEmpty) return _buffer.removeAt(0);
    final completer = Completer<T>();
    _waiters.add(completer);
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _waiters.remove(completer);
      return null;
    }
  }

  void _add(T value) {
    if (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (!waiter.isCompleted) waiter.complete(value);
    } else {
      _buffer.add(value);
    }
  }

  Future<void> cancel() => _subscription.cancel();
}
