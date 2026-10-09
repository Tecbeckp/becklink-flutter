import 'dart:async';

import '../http/api_client.dart';
import '../http/api_client_closed_exception.dart';
import '../http/api_endpoint.dart';
import '../logging/sdk_logger.dart';
import '../models/becklink_error_code.dart';
import '../models/becklink_exception.dart';
import '../storage/event_batch_outcome.dart';
import '../storage/event_queue.dart';
import '../storage/queued_event.dart';

/// Sends the event queue to `POST /v1/sdk/events` (requirements §29 step 7,
/// §29.1, contract section 8.4) every flush interval (remote config, 15 s by
/// default), when the queue reaches 20 events, when the app goes to the
/// background and when it returns. Internal to the SDK.
///
/// Retries with backoff happen inside one flush (`ApiClient`, up to 24 hours
/// for events); triggers that come meanwhile join the running flush. After a
/// flush gave up, sending pauses until the app returns to the foreground
/// (contract section 11.2: "flush again on connectivity change or the next
/// foreground"; the SDK has no connectivity listener, so the foreground and
/// the explicit `flush()` take that role), or for the wait the service asked
/// for.
final class EventDelivery {
  /// Creates the delivery for [queue]; call [start] to begin.
  ///
  /// [sendingInstallId] returns the install ID while events may be sent
  /// (tracking on, first open completed, API key not refused), otherwise
  /// `null`; [requestContext] returns the request `context`, or `null` on a
  /// platform the SDK API does not support. [api] returns the current
  /// client, which `configure()` or `setTrackingEnabled(false)` may replace.
  EventDelivery({
    required EventQueue queue,
    required SdkLogger logger,
    required ApiClient Function() api,
    required String? Function() sendingInstallId,
    required Future<Map<String, Object?>?> Function() requestContext,
    DateTime Function()? now,
  })  : _queue = queue,
        _logger = logger,
        _api = api,
        _sendingInstallId = sendingInstallId,
        _requestContext = requestContext,
        _now = now ?? DateTime.now;

  /// Longest wait of the public `flush()`; sending continues in the
  /// background after it.
  static const Duration publicFlushWait = Duration(seconds: 30);

  /// Pause after a `429` without `Retry-After`; the backoff cap.
  static const Duration defaultRateLimitPause = Duration(minutes: 5);

  final EventQueue _queue;
  final SdkLogger _logger;
  final ApiClient Function() _api;
  final String? Function() _sendingInstallId;
  final Future<Map<String, Object?>?> Function() _requestContext;
  final DateTime Function() _now;

  Timer? _timer;
  Duration? _interval;
  StreamSubscription<void>? _thresholdSubscription;
  bool _pausedUntilForeground = false;
  DateTime? _blockedUntil;
  bool _stopped = false;

  /// Starts the interval timer and the threshold trigger.
  void start(Duration interval) {
    if (_stopped) return;
    _thresholdSubscription ??=
        _queue.onThresholdReached.listen((_) => trigger('threshold'));
    updateInterval(interval);
  }

  /// Uses [interval] from now on (a new remote config).
  void updateInterval(Duration interval) {
    if (_stopped || interval == _interval) return;
    _interval = interval;
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => trigger('interval'));
  }

  /// The app returned to the foreground: a paused delivery may try again.
  void onForeground() {
    _pausedUntilForeground = false;
    trigger('foreground');
  }

  /// The app left the foreground: send what is queued while it still can.
  void onBackground() => trigger('background');

  /// Starts a flush unless the queue is empty, sending is paused or not
  /// allowed now. Never throws.
  void trigger(String reason) {
    if (_stopped || _queue.length == 0) return;
    if (_pausedUntilForeground || _isBlocked()) return;
    unawaited(_flush(reason));
  }

  /// The public `flush()`: sends now, ignoring a pause after an earlier
  /// failure but not a wait the service asked for, and returns after at
  /// most [publicFlushWait]. Never throws for network trouble.
  Future<void> flushNow() async {
    if (_stopped || _queue.length == 0 || _isBlocked()) return;
    _pausedUntilForeground = false;
    try {
      await _flush('flush()').timeout(publicFlushWait);
    } on TimeoutException {
      _logger.debug('flush() returned; sending continues in the background');
    }
  }

  /// Stops the timer and the threshold trigger. A running flush ends with
  /// its current batch.
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    await _thresholdSubscription?.cancel();
    _thresholdSubscription = null;
  }

  Future<void> _flush(String reason) async {
    if (_sendingInstallId() == null) return;
    try {
      final result = await _queue.flush(_send);
      _logger.debug(
        'Event flush ($reason): ${result.delivered} delivered, '
        '${result.dropped} dropped, ${result.remaining} still queued',
      );
    } catch (error) {
      // Only an SDK bug gets here; flushes run unawaited and must not
      // surface as unhandled errors in the app.
      _logger.error('Sending events failed unexpectedly', error);
    }
  }

  /// The queue's [EventBatchSender], which must not throw.
  Future<EventBatchOutcome> _send(List<QueuedEvent> batch) async {
    try {
      return await _sendOrThrow(batch);
    } catch (error) {
      _logger.error('Sending events failed unexpectedly', error);
      return const EventBatchDeferred();
    }
  }

  Future<EventBatchOutcome> _sendOrThrow(List<QueuedEvent> batch) async {
    final context = await _requestContext();
    final installId = _sendingInstallId();
    if (_stopped || context == null || installId == null) {
      return const EventBatchDeferred();
    }
    try {
      final receipt = await _api().post(
        ApiEndpoint.events,
        body: <String, Object?>{
          'install_id': installId,
          'context': context,
          'events': <Map<String, Object?>>[
            for (final event in batch) event.toJson(),
          ],
        },
        read: (response) => readEventBatchReceipt(response.body),
      );
      return EventBatchDelivered(receipt);
    } on BeckLinkException catch (error) {
      return _outcomeOf(error);
    } on ApiClientClosedException {
      // Reconfigured or tracking turned off: not a failure; the queue keeps
      // the batch (or was already cleared).
      return const EventBatchDeferred();
    }
  }

  EventBatchOutcome _outcomeOf(BeckLinkException error) {
    switch (error.code) {
      case BeckLinkErrorCode.invalidRequest:
        // The queue drops the batch and logs it at error level, so one bad
        // batch cannot block the ones after it (contract section 8.4).
        return EventBatchRefused(error.message);
      case BeckLinkErrorCode.rateLimited:
        final wait = error.retryAfter ?? defaultRateLimitPause;
        _blockedUntil = _now().add(wait);
        _logger.info(
          'Sending events was rate limited; they stay queued and are sent '
          'again in ${wait.inSeconds} s',
          error,
        );
      case BeckLinkErrorCode.network:
      case BeckLinkErrorCode.timeout:
        // The client retried for up to 24 hours, or the service named a wait
        // longer than the backoff cap.
        final wait = error.retryAfter;
        final String when;
        if (wait == null) {
          _pausedUntilForeground = true;
          when = 'when the app returns to the foreground';
        } else {
          _blockedUntil = _now().add(wait);
          when = 'in ${wait.inSeconds} s';
        }
        _logger.info(
          'Events could not be sent; they stay queued and are sent again '
          '$when',
          error,
        );
      case BeckLinkErrorCode.invalidKey:
        _pausedUntilForeground = true;
        _logger.error(
          'The Beck Link API refused the API key while sending events; they '
          'stay queued. Check that configure() gets the publishable key of '
          'this project environment',
          error,
        );
      case BeckLinkErrorCode.linkNotFound:
      case BeckLinkErrorCode.notConfigured:
      case BeckLinkErrorCode.trackingDisabled:
        // Not an answer the events endpoint gives; keep the events rather
        // than lose them over an SDK bug.
        _logger.error('Unexpected failure while sending events', error);
    }
    return const EventBatchDeferred();
  }

  bool _isBlocked() {
    final until = _blockedUntil;
    return until != null && _now().isBefore(until);
  }
}
