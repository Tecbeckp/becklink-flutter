import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpClient, IOException, gzip;
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../json/json_reader.dart';
import '../json/json_value.dart';
import '../logging/sdk_logger.dart';
import '../models/api_call.dart';
import '../models/becklink_exception.dart';
import '../sdk_info.dart';
import '../util/uuid.dart';
import 'api_client_closed_exception.dart';
import 'api_endpoint.dart';
import 'api_failure.dart';
import 'api_problem.dart';
import 'api_response.dart';
import 'retry_policy.dart';

/// Base URL of the SDK API in production (contract section 2).
final Uri productionBaseUrl = Uri.parse('https://api.becklinks.com');

/// Receives a record of every attempt an [ApiClient] makes.
typedef ApiCallObserver = void Function(BeckLinkApiCall call);

/// The SDK's only way to call the Beck Link SDK API (`/v1/sdk/*`).
///
/// Sends JSON with the contract's headers, gzips event batches, enforces a
/// deadline per attempt, retries what the contract calls retryable with
/// exponential backoff and full jitter, and turns every failure into a
/// `BeckLinkException` (contract sections 4, 5, 10 and 11). One client
/// belongs to one `configure()`; [close] cancels everything it is doing.
/// Every attempt is reported to the optional [ApiCallObserver] (for
/// `BeckLink.onApiCall`) with the same fields the log gets.
///
/// Never logs the API key, request bodies, idempotency keys or response
/// bodies; only paths, sizes, statuses, durations and request IDs. Callers
/// log the final failure: only they know what it means for the app.
/// Internal to the SDK.
final class ApiClient {
  /// Creates a client that authenticates with the publishable [apiKey].
  ///
  /// [httpClient] defaults to a `dart:io` client with the contract's 10 s
  /// connect timeout; a client passed in is not closed by [close].
  /// [baseUrl] (default [productionBaseUrl]) comes from tests or from
  /// `configure(apiBaseUrl:)` for staging and local development; anything
  /// but HTTPS is refused unless the host is this machine. [now] and
  /// [random] replace the clock and the jitter source in tests.
  /// [compressEvents] turns off gzip for event batches, so tests can read
  /// the body. [allowPrivateNetworkHttp] also accepts plain HTTP to a
  /// private network address (see [checkBaseUrl]); debug builds only.
  /// [onCall] receives a record of every attempt.
  ///
  /// Throws an [ArgumentError] when [apiKey] or [baseUrl] cannot be used.
  ApiClient({
    required String apiKey,
    required SdkLogger logger,
    http.Client? httpClient,
    Uri? baseUrl,
    RetryPolicy retryPolicy = const RetryPolicy(),
    DateTime Function()? now,
    Random? random,
    bool compressEvents = true,
    bool allowPrivateNetworkHttp = false,
    ApiCallObserver? onCall,
  })  : _headers = _headersFor(_checkApiKey(apiKey)),
        _baseUrl = checkBaseUrl(
          baseUrl ?? productionBaseUrl,
          allowPrivateNetworkHttp: allowPrivateNetworkHttp,
        ),
        _onCall = onCall,
        _logger = logger,
        _client = httpClient ?? _defaultHttpClient(),
        _ownsClient = httpClient == null,
        _retryPolicy = retryPolicy,
        _now = now ?? DateTime.now,
        _random = random ?? Random(),
        _compressEvents = compressEvents;

  /// Connect timeout of every call (contract section 11.2).
  static const Duration connectTimeout = Duration(seconds: 10);

  /// Largest response body read; no SDK API answer comes close, so anything
  /// bigger is not one. Also bounds the memory a misbehaving proxy can use.
  static const int maxResponseBytes = 1024 * 1024;

  static final _visibleAscii = RegExp(r'^[\x21-\x7e]+$');
  static final _idempotencyKeyFormat = RegExp(r'^[\x21-\x7e]{1,255}$');
  static final _requestIdFormat = RegExp(r'^[\x21-\x7e]{1,128}$');

  // Plain HTTP only reaches a server on this machine: the host itself, or
  // the Android emulator's alias for it. Everything else must be HTTPS
  // (contract section 2, SEC-001).
  static const _localHosts = <String>{
    'localhost',
    '127.0.0.1',
    '::1',
    '10.0.2.2',
  };

  final Map<String, String> _headers;
  final Uri _baseUrl;
  final ApiCallObserver? _onCall;
  final SdkLogger _logger;
  final http.Client _client;
  final bool _ownsClient;
  final RetryPolicy _retryPolicy;
  final DateTime Function() _now;
  final Random _random;
  final bool _compressEvents;
  final Random _idRandom = Random.secure();

  /// Callbacks that abort in-flight attempts and pending waits on [close].
  final Set<void Function()> _closeHooks = <void Function()>{};

  bool _closed = false;
  bool _keyRejected = false;

  /// Whether [close] has run.
  bool get isClosed => _closed;

  /// Whether the service refused the API key (`401`). From then on every
  /// call fails at once with `invalid_key` without a request, until the SDK
  /// is configured again with a new client (contract section 11.2: a
  /// revoked key should not be hammered).
  bool get isKeyRejected => _keyRejected;

  /// Sends [body] to [endpoint], retrying within [budget] (default: the
  /// endpoint's), and returns what [read] makes of the successful answer.
  ///
  /// [idempotencyKey] is only for endpoints that require one (`open`,
  /// `links`); when omitted there, a new UUID is used. The same key and the
  /// same bytes are sent on every retry.
  ///
  /// Throws a `BeckLinkException` when the request fails for good (also
  /// when the encoded [body] is over the endpoint's size limit, as the
  /// service would answer `413`), an [ApiClientClosedException] when [close]
  /// runs first, and an [ArgumentError] when [body] holds non-JSON values or
  /// [idempotencyKey] is unusable or not accepted by [endpoint].
  Future<T> post<T>(
    ApiEndpoint endpoint, {
    required Map<String, Object?> body,
    required ResponseReader<T> read,
    String? idempotencyKey,
    RetryBudget? budget,
  }) async {
    _checkOpen();
    final request = _encode(endpoint, body, idempotencyKey);
    final limits = budget ?? endpoint.budget;
    final maxElapsed = limits.maxElapsed;
    final deadline = maxElapsed == null ? null : _now().add(maxElapsed);
    for (var attempt = 1;; attempt++) {
      if (_keyRejected) throw _keyRejectedException;
      final outcome = await _attempt(
        request,
        read,
        attempt,
        _attemptTimeout(endpoint, deadline),
      );
      switch (outcome) {
        case _Succeeded<T>(:final value):
          return value;
        case _Failed<T>(:final failure):
          if (failure.rejectsKey) _keyRejected = true;
          final delay = _delayBeforeRetry(failure, attempt, limits, deadline);
          if (delay == null) {
            _logger.info(
              '${request.label} failed after $attempt attempt(s)',
              failure.exception,
            );
            throw failure.exception;
          }
          _logger.info(
            '${request.label} attempt $attempt failed, retrying in '
            '${_seconds(delay)}',
            failure.exception,
          );
          await _sleep(delay);
      }
    }
  }

  /// Aborts in-flight requests and pending retry waits (their calls throw
  /// [ApiClientClosedException]) and refuses new calls. Closes the HTTP
  /// client when this client created it. Safe to call more than once.
  void close() {
    if (_closed) return;
    _closed = true;
    final hooks = List<void Function()>.of(_closeHooks);
    _closeHooks.clear();
    for (final hook in hooks) {
      hook();
    }
    if (_ownsClient) _client.close();
  }

  void _checkOpen() {
    if (_closed) throw const ApiClientClosedException();
  }

  _EncodedRequest _encode(
    ApiEndpoint endpoint,
    Map<String, Object?> body,
    String? idempotencyKey,
  ) {
    if (!isJsonValue(body)) {
      throw ArgumentError(
        'must contain only JSON values: null, String, bool, finite num, '
            'List, and Map with String keys',
        'body',
      );
    }
    final bytes = utf8.encode(jsonEncode(body));
    // Checked before compression because the service measures the body
    // after decompression (contract section 5).
    if (bytes.length > endpoint.maxBodyBytes) {
      throw BeckLinkException.invalidRequest(
        message: 'The request body is ${bytes.length} bytes, over the '
            '${endpoint.maxBodyBytes}-byte limit of POST ${endpoint.path}.',
      );
    }
    final key = _idempotencyKeyFor(endpoint, idempotencyKey);
    final compress = _compressEvents && endpoint.acceptsGzip;
    return _EncodedRequest(
      path: endpoint.path,
      label: 'POST ${endpoint.path}',
      url: _baseUrl.replace(path: endpoint.path),
      headers: Map<String, String>.unmodifiable(<String, String>{
        ..._headers,
        if (compress) 'Content-Encoding': 'gzip',
        if (key != null) 'Idempotency-Key': key,
      }),
      body: compress ? gzip.encode(bytes) : bytes,
      compressed: compress,
    );
  }

  String? _idempotencyKeyFor(ApiEndpoint endpoint, String? key) {
    if (!endpoint.requiresIdempotencyKey) {
      if (key != null) {
        throw ArgumentError(
          'is not accepted by POST ${endpoint.path}; its body carries a '
              'natural key',
          'idempotencyKey',
        );
      }
      return null;
    }
    if (key == null) return uuidV4(_idRandom);
    if (!_idempotencyKeyFormat.hasMatch(key)) {
      throw ArgumentError(
        'must be 1 to 255 visible ASCII characters',
        'idempotencyKey',
      );
    }
    return key;
  }

  Duration _attemptTimeout(ApiEndpoint endpoint, DateTime? deadline) {
    if (deadline == null) return endpoint.attemptTimeout;
    final remaining = deadline.difference(_now());
    return remaining < endpoint.attemptTimeout
        ? remaining
        : endpoint.attemptTimeout;
  }

  /// The wait before the next attempt, or `null` to give up.
  Duration? _delayBeforeRetry(
    ApiFailure failure,
    int attempt,
    RetryBudget limits,
    DateTime? deadline,
  ) {
    if (!failure.retryable) return null;
    final maxAttempts = limits.maxAttempts;
    if (maxAttempts != null && attempt >= maxAttempts) return null;
    final retryAfter = failure.retryAfter;
    // Retrying sooner than Retry-After is not allowed, and holding a call
    // open longer than the backoff cap is not useful: the caller gets the
    // exception with retryAfter and schedules the work itself.
    if (retryAfter != null && retryAfter > _retryPolicy.maxDelay) return null;
    var delay = _retryPolicy.backoff(attempt - 1, _random);
    if (retryAfter != null && retryAfter > delay) delay = retryAfter;
    if (deadline != null && !_now().add(delay).isBefore(deadline)) return null;
    return delay;
  }

  Future<_Outcome<T>> _attempt<T>(
    _EncodedRequest encoded,
    ResponseReader<T> read,
    int attempt,
    Duration timeout,
  ) async {
    _checkOpen();
    if (timeout <= Duration.zero) return _Failed<T>(attemptTimeout());

    // One trigger serves both the per-attempt deadline and close(): it
    // aborts the socket (package:http AbortableRequest) and also ends the
    // wait below, for HTTP clients that ignore abort triggers.
    final abort = Completer<void>();
    _AbortReason? reason;
    void trigger(_AbortReason why) {
      if (abort.isCompleted) return;
      reason = why;
      abort.complete();
    }

    void onClose() => trigger(_AbortReason.closed);
    final timer = Timer(timeout, () => trigger(_AbortReason.timeout));
    _closeHooks.add(onClose);
    final request = http.AbortableRequest(
      'POST',
      encoded.url,
      abortTrigger: abort.future,
    )
      ..headers.addAll(encoded.headers)
      ..bodyBytes = encoded.body;

    _logger.debug(
      '${encoded.label} attempt $attempt: ${encoded.body.length} bytes'
      '${encoded.compressed ? ' (gzip)' : ''}',
    );
    final startedAt = _now();
    final watch = Stopwatch()..start();
    final _RawResponse raw;
    try {
      raw = await Future.any(<Future<_RawResponse>>[
        _exchange(request),
        abort.future.then<_RawResponse>((_) => throw const _Aborted()),
      ]);
    } catch (error) {
      switch (reason) {
        case _AbortReason.closed:
          throw const ApiClientClosedException();
        case _AbortReason.timeout:
          final failure = attemptTimeout();
          _report(encoded, attempt, startedAt, watch, failure: failure);
          return _Failed<T>(failure);
        case null:
          break;
      }
      if (error is _ResponseTooLarge) {
        final failure = unreadableResponse(statusCode: error.statusCode);
        _report(
          encoded,
          attempt,
          startedAt,
          watch,
          statusCode: error.statusCode,
          failure: failure,
        );
        return _Failed<T>(failure);
      }
      if (error is http.ClientException || error is IOException) {
        _logger.debug('${encoded.label} got no answer', error);
        final failure = connectionFailure();
        _report(encoded, attempt, startedAt, watch, failure: failure);
        return _Failed<T>(failure);
      }
      rethrow;
    } finally {
      timer.cancel();
      _closeHooks.remove(onClose);
    }
    final outcome = _interpret(raw, read);
    _report(
      encoded,
      attempt,
      startedAt,
      watch,
      statusCode: raw.statusCode,
      requestId: raw.requestId,
      replayed: raw.replayed,
      failure: switch (outcome) {
        _Succeeded<T>() => null,
        _Failed<T>(:final failure) => failure,
      },
    );
    _logger.debug(
      '${encoded.label} answered HTTP ${raw.statusCode} in '
      '${watch.elapsedMilliseconds} ms'
      '${raw.requestId == null ? '' : ', request ID ${raw.requestId}'}',
    );
    return outcome;
  }

  Future<_RawResponse> _exchange(http.BaseRequest request) async {
    final response = await _client.send(request);
    final builder = BytesBuilder(copy: false);
    // The verdict on an oversized body must not wait for the stream to finish
    // cancelling: a client can take a while to close the connection (or, in
    // tests, never do so until the attempt timeout). So the body is read with
    // a listener, and the cancel is fired and forgotten.
    final finished = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = response.stream.listen(
      (chunk) {
        if (finished.isCompleted) return;
        builder.add(chunk);
        if (builder.length > maxResponseBytes) {
          unawaited(subscription.cancel().then<void>((_) {}, onError: (_) {}));
          finished.completeError(_ResponseTooLarge(response.statusCode));
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!finished.isCompleted) finished.completeError(error, stackTrace);
      },
      onDone: () {
        if (!finished.isCompleted) finished.complete();
      },
      cancelOnError: true,
    );
    await finished.future;
    return _RawResponse(
      statusCode: response.statusCode,
      // package:http's IOClient already lower-cases names; other clients
      // (tests) may not.
      headers: <String, String>{
        for (final header in response.headers.entries)
          header.key.toLowerCase(): header.value,
      },
      body: builder.takeBytes(),
    );
  }

  _Outcome<T> _interpret<T>(_RawResponse raw, ResponseReader<T> read) {
    final status = raw.statusCode;
    final json = _decodeJson(raw);
    if (status < 200 || status > 299) {
      final problem = ApiProblem.tryParse(json);
      return _Failed<T>(
        classifyErrorResponse(
          statusCode: status,
          problem: problem,
          requestId: raw.requestId ?? _usableRequestId(problem?.requestId),
          retryAfter: parseRetryAfter(raw.headers['retry-after'], _now()),
        ),
      );
    }
    if (json is! Map<String, Object?>) {
      return _Failed<T>(
        unreadableResponse(statusCode: status, requestId: raw.requestId),
      );
    }
    final response = ApiResponse(
      statusCode: status,
      body: JsonReader(json),
      requestId: raw.requestId,
      replayed: raw.replayed,
    );
    try {
      return _Succeeded<T>(read(response));
    } on FormatException catch (error) {
      // MalformedJsonException messages name only a JSON Pointer, never a
      // value, so they are safe to put into the exception.
      return _Failed<T>(
        incompatibleResponse(
          statusCode: status,
          reason: error.message,
          requestId: raw.requestId,
        ),
      );
    }
  }

  /// Tells the observer about one attempt.
  void _report(
    _EncodedRequest encoded,
    int attempt,
    DateTime startedAt,
    Stopwatch watch, {
    int? statusCode,
    String? requestId,
    bool replayed = false,
    ApiFailure? failure,
  }) {
    final observer = _onCall;
    if (observer == null) return;
    observer(
      BeckLinkApiCall(
        method: 'POST',
        path: encoded.path,
        attempt: attempt,
        startedAt: startedAt,
        duration: watch.elapsed,
        statusCode: statusCode,
        requestId: requestId ?? failure?.exception.requestId,
        idempotentReplayed: replayed,
        errorCode: failure?.exception.code,
      ),
    );
  }

  /// A wait that [close] ends early with [ApiClientClosedException].
  Future<void> _sleep(Duration delay) {
    final done = Completer<void>();
    late final void Function() onClose;
    final timer = Timer(delay, () {
      _closeHooks.remove(onClose);
      done.complete();
    });
    onClose = () {
      timer.cancel();
      done.completeError(const ApiClientClosedException());
    };
    _closeHooks.add(onClose);
    return done.future;
  }

  static const BeckLinkException _keyRejectedException =
      BeckLinkException.invalidKey(
    message: 'The Beck Link API rejected the API key earlier in this '
        'session. SDK API calls stay paused until the app restarts or '
        'configure() runs again with a valid publishable key.',
    statusCode: 401,
  );

  static String _checkApiKey(String apiKey) {
    // The key goes into a header; the value itself is never put into the
    // error, because it is a credential.
    if (!_visibleAscii.hasMatch(apiKey)) {
      throw ArgumentError(
        'must be non-empty visible ASCII without spaces',
        'apiKey',
      );
    }
    return apiKey;
  }

  /// [url] when the SDK may use it as the SDK API origin: an `https`
  /// origin, or an `http` origin on this machine (`localhost`, `127.0.0.1`,
  /// `::1`, or `10.0.2.2`, the Android emulator's alias for the host
  /// computer). With [allowPrivateNetworkHttp] (debug builds only) `http` is
  /// also accepted for a private network address (`10.x`, `172.16–31.x`,
  /// `192.168.x`) or a `.local` name, so a phone can reach a development
  /// server on the same Wi-Fi.
  ///
  /// Throws an [ArgumentError] otherwise, and for anything with a path,
  /// query, fragment or user info.
  static Uri checkBaseUrl(Uri url, {bool allowPrivateNetworkHttp = false}) {
    final secure = url.scheme == 'https';
    final host = url.host.toLowerCase();
    final local = url.scheme == 'http' &&
        (_localHosts.contains(host) ||
            (allowPrivateNetworkHttp && _isPrivateNetworkHost(host)));
    final originOnly = url.host.isNotEmpty &&
        (url.path.isEmpty || url.path == '/') &&
        !url.hasQuery &&
        !url.hasFragment &&
        url.userInfo.isEmpty;
    if ((!secure && !local) || !originOnly) {
      throw ArgumentError.value(
        url,
        'baseUrl',
        allowPrivateNetworkHttp
            ? 'must be an https origin, or an http origin on this machine '
                'or a private network'
            : 'must be an https origin, or an http origin on this machine',
      );
    }
    return url;
  }

  static bool _isPrivateNetworkHost(String host) {
    if (host.endsWith('.local') && host.length > '.local'.length) return true;
    final parts = host.split('.');
    if (parts.length != 4) return false;
    final octets = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return false;
      octets.add(value);
    }
    final a = octets[0];
    final b = octets[1];
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168);
  }

  static Map<String, String> _headersFor(String apiKey) =>
      Map<String, String>.unmodifiable(<String, String>{
        'Authorization': 'Bearer $apiKey',
        'Content-Type': 'application/json',
        'Accept': 'application/json, application/problem+json',
        'User-Agent': '$sdkName/$sdkVersion',
        'X-SDK-Name': sdkName,
        'X-SDK-Version': sdkVersion,
      });

  static http.Client _defaultHttpClient() =>
      IOClient(HttpClient()..connectionTimeout = connectTimeout);

  /// The decoded JSON body, or `null` when it is empty, not JSON, or
  /// labelled as something else (a captive portal's HTML page).
  static Object? _decodeJson(_RawResponse raw) {
    final contentType = raw.headers['content-type'];
    if (contentType != null && !_isJsonMediaType(contentType)) return null;
    if (raw.body.isEmpty) return null;
    try {
      return utf8.decoder.fuse(json.decoder).convert(raw.body);
    } on FormatException {
      return null;
    }
  }

  static bool _isJsonMediaType(String contentType) {
    final type = contentType.split(';').first.trim().toLowerCase();
    return type == 'application/json' ||
        (type.startsWith('application/') && type.endsWith('+json'));
  }

  /// [value] when it can be shown as a request ID, otherwise `null`; the
  /// value comes from the network and ends up in messages and logs.
  static String? _usableRequestId(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return _requestIdFormat.hasMatch(trimmed) ? trimmed : null;
  }

  static String _seconds(Duration duration) =>
      '${(duration.inMilliseconds / 1000).toStringAsFixed(1)} s';
}

/// A request encoded once and sent unchanged on every attempt.
final class _EncodedRequest {
  _EncodedRequest({
    required this.path,
    required this.label,
    required this.url,
    required this.headers,
    required this.body,
    required this.compressed,
  });

  /// `/v1/sdk/…`.
  final String path;

  /// `POST /v1/sdk/…`, for logs.
  final String label;
  final Uri url;
  final Map<String, String> headers;
  final List<int> body;
  final bool compressed;
}

final class _RawResponse {
  _RawResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
  })  : requestId = ApiClient._usableRequestId(headers['x-request-id']),
        replayed =
            headers['idempotent-replayed']?.trim().toLowerCase() == 'true';

  final int statusCode;

  /// `Idempotent-Replayed: true` (contract section 6).
  final bool replayed;

  /// Header names in lower case.
  final Map<String, String> headers;
  final Uint8List body;
  final String? requestId;
}

sealed class _Outcome<T> {
  const _Outcome();
}

final class _Succeeded<T> extends _Outcome<T> {
  const _Succeeded(this.value);

  final T value;
}

final class _Failed<T> extends _Outcome<T> {
  const _Failed(this.failure);

  final ApiFailure failure;
}

enum _AbortReason { timeout, closed }

/// Ends the wait for an attempt whose abort trigger fired.
final class _Aborted implements Exception {
  const _Aborted();
}

/// The response body passed [ApiClient.maxResponseBytes].
final class _ResponseTooLarge implements Exception {
  const _ResponseTooLarge(this.statusCode);

  final int statusCode;
}
