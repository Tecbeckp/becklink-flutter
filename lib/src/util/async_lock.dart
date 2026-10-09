/// Runs asynchronous actions one at a time, in the order they were
/// submitted.
///
/// Storage uses it so that only one write to a file is ever in progress:
/// two overlapping writes could otherwise leave the older content as the
/// last one on disk. Internal to the SDK.
final class AsyncLock {
  Future<void> _last = Future<void>.value();

  /// Runs [action] once every action submitted before it has finished, and
  /// returns its result.
  ///
  /// The place in line is taken synchronously, when this method is called,
  /// so call order is execution order. A failing action does not block the
  /// ones after it. [action] must not wait for another action on the same
  /// lock: that action would wait for [action] in turn, forever.
  Future<T> synchronized<T>(Future<T> Function() action) {
    final result = _last.then<T>((_) => action());
    // The caller gets the failure through [result]; the chain only needs
    // to know that the action is over.
    _last = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  /// Completes once every action submitted so far has finished.
  Future<void> whenIdle() => synchronized<void>(() async {});
}
