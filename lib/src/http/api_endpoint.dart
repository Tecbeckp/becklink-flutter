import 'retry_policy.dart';

/// The SDK API endpoints with the per-endpoint rules of the SDK API
/// contract: body limit (section 5), gzip (section 5), `Idempotency-Key`
/// (section 6), client timeout and retry budget (section 11.2).
enum ApiEndpoint {
  /// `POST /v1/sdk/init`: session start; 3 attempts, then the session goes
  /// without it.
  init(
    path: '/v1/sdk/init',
    maxBodyBytes: 8 * 1024,
    attemptTimeout: Duration(seconds: 10),
    budget: RetryBudget(maxAttempts: 3),
  ),

  /// `POST /v1/sdk/first-open`: retried until it succeeds; after 24 hours of
  /// failures the caller pauses it until the next launch.
  firstOpen(
    path: '/v1/sdk/first-open',
    maxBodyBytes: 8 * 1024,
    attemptTimeout: Duration(seconds: 10),
    budget: RetryBudget(maxElapsed: Duration(hours: 24)),
  ),

  /// `POST /v1/sdk/open`: 5 attempts within the running process.
  open(
    path: '/v1/sdk/open',
    maxBodyBytes: 8 * 1024,
    attemptTimeout: Duration(seconds: 10),
    budget: RetryBudget(maxAttempts: 5),
    requiresIdempotencyKey: true,
  ),

  /// `POST /v1/sdk/events`: gzip-compressed batches, retried until they
  /// succeed; after 24 hours of failures the queue is kept for later.
  events(
    path: '/v1/sdk/events',
    maxBodyBytes: 512 * 1024,
    attemptTimeout: Duration(seconds: 30),
    budget: RetryBudget(maxElapsed: Duration(hours: 24)),
    acceptsGzip: true,
  ),

  /// `POST /v1/sdk/links`: 3 attempts and at most 30 seconds in total, since
  /// the app is waiting for the link.
  links(
    path: '/v1/sdk/links',
    maxBodyBytes: 16 * 1024,
    attemptTimeout: Duration(seconds: 15),
    budget: RetryBudget(maxAttempts: 3, maxElapsed: Duration(seconds: 30)),
    requiresIdempotencyKey: true,
  );

  const ApiEndpoint({
    required this.path,
    required this.maxBodyBytes,
    required this.attemptTimeout,
    required this.budget,
    this.requiresIdempotencyKey = false,
    this.acceptsGzip = false,
  });

  /// Absolute path below the API base URL.
  final String path;

  /// Largest request body the server accepts, measured before compression
  /// (the server measures after decompression).
  final int maxBodyBytes;

  /// Client deadline for one attempt, from sending the request until the
  /// whole response body has arrived.
  final Duration attemptTimeout;

  /// Default retry budget of one logical request.
  final RetryBudget budget;

  /// Whether the request must carry an `Idempotency-Key`, reused on every
  /// retry. The other endpoints have natural keys (`first_open_id`,
  /// `event_id`) and ignore the header.
  final bool requiresIdempotencyKey;

  /// Whether the server accepts a gzip-compressed body.
  final bool acceptsGzip;
}
