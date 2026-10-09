import 'dart:async';
import 'dart:collection';

/// A broadcast stream that keeps what is added while nobody listens and
/// hands it to the next listener (FL-004: callbacks are buffered until a
/// listener subscribes), so a link that opened the app is not lost because
/// the app subscribed a moment after it arrived.
///
/// Keeps at most [capacity] values, dropping the oldest. While at least one
/// listener is subscribed, values go out at once, as with any broadcast
/// stream. Internal to the SDK.
final class BufferedBroadcast<T> {
  /// Creates a stream that buffers up to [capacity] values.
  BufferedBroadcast({required this.capacity})
      : assert(capacity > 0, 'capacity must be positive');

  /// Most values kept while nobody listens.
  final int capacity;

  final Queue<T> _pending = Queue<T>();

  // Asynchronous delivery, like every broadcast stream the app usually sees:
  // a listener never runs inside the SDK's own call stack.
  late final StreamController<T> _controller =
      StreamController<T>.broadcast(onListen: _deliverPending);

  /// The stream the app listens to.
  Stream<T> get stream => _controller.stream;

  /// Sends [value] to the current listeners, or keeps it for the next one.
  void add(T value) {
    if (_controller.isClosed) return;
    if (_controller.hasListener) {
      _controller.add(value);
      return;
    }
    _pending.add(value);
    while (_pending.length > capacity) {
      _pending.removeFirst();
    }
  }

  /// Ends the stream and drops buffered values.
  Future<void> close() {
    _pending.clear();
    return _controller.close();
  }

  // Runs when the first listener subscribes, which the controller has
  // already registered, so the buffered values reach it.
  void _deliverPending() {
    while (_pending.isNotEmpty) {
      _controller.add(_pending.removeFirst());
    }
  }
}
