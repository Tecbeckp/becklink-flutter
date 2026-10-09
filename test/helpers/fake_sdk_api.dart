import 'dart:async';
import 'dart:convert';
import 'dart:io' show gzip;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

/// Base URL the fake SDK API answers on.
final Uri fakeBaseUrl = Uri.parse('https://api.becklink.test');

/// SDK API paths (contract section 8).
abstract final class SdkPaths {
  static const String init = '/v1/sdk/init';
  static const String firstOpen = '/v1/sdk/first-open';
  static const String open = '/v1/sdk/open';
  static const String events = '/v1/sdk/events';
  static const String links = '/v1/sdk/links';
}

/// One request the fake SDK API received.
final class ApiRequest {
  ApiRequest({
    required this.path,
    required this.headers,
    required this.bodyBytes,
  });

  /// The URL path, such as `/v1/sdk/first-open`.
  final String path;

  /// Header names in lower case.
  final Map<String, String> headers;

  /// The body as sent (gzip-compressed when `content-encoding` says so).
  final List<int> bodyBytes;

  /// The decoded JSON body.
  Map<String, Object?> get json {
    final bytes = headers['content-encoding'] == 'gzip'
        ? gzip.decode(bodyBytes)
        : bodyBytes;
    return jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
  }
}

/// Answers one request; may throw (for example an `http.ClientException`
/// for "no connection") or never complete.
typedef ApiResponder = FutureOr<http.Response> Function(ApiRequest request);

/// The SDK API as a `MockClient`: records every request and answers from
/// one-shot responders queued per path, then from the path's default.
///
/// The defaults answer like a healthy service: an organic first open, init
/// with config, `/open` resolving to a direct open, events accepted and a
/// created link.
final class FakeSdkApi {
  FakeSdkApi() {
    client = MockClient(_handle);
  }

  /// The HTTP client to hand to the SDK.
  late final http.Client client;

  /// Every request, in arrival order.
  final List<ApiRequest> requests = <ApiRequest>[];

  final Map<String, List<ApiResponder>> _queued =
      <String, List<ApiResponder>>{};
  final StreamController<ApiRequest> _arrivals =
      StreamController<ApiRequest>.broadcast(sync: true);

  late final Map<String, ApiResponder> _defaults = <String, ApiResponder>{
    SdkPaths.firstOpen: (_) => jsonResponse(organicAnswerJson()),
    SdkPaths.init: (_) =>
        jsonResponse(<String, Object?>{'config': configJson()}),
    SdkPaths.open: (request) => jsonResponse(
          openAnswerJson(url: request.json['url']! as String),
        ),
    SdkPaths.events: (request) => jsonResponse(
          eventsReceiptJson(
            accepted: (request.json['events']! as List<Object?>).length,
          ),
          status: 202,
        ),
    SdkPaths.links: (_) => jsonResponse(createdLinkJson(), status: 201),
  };

  /// Answers every later request to [path] with [responder].
  void respond(String path, ApiResponder responder) =>
      _defaults[path] = responder;

  /// Answers the next request to [path] with [responder], before the
  /// default; several calls queue in order.
  void enqueue(String path, ApiResponder responder) =>
      _queued.putIfAbsent(path, () => <ApiResponder>[]).add(responder);

  /// The requests to [path] so far.
  List<ApiRequest> to(String path) =>
      requests.where((request) => request.path == path).toList();

  /// Completes with the next request to [path] that arrives after this call.
  Future<ApiRequest> next(String path, {Duration? timeout}) => _arrivals.stream
      .firstWhere((request) => request.path == path)
      .timeout(timeout ?? const Duration(seconds: 10));

  /// Completes once [count] requests to [path] arrived in total.
  Future<void> waitFor(String path, int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (to(path).length < count) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
          'Expected $count requests to $path, got ${to(path).length}',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  /// Stops reporting arrivals.
  Future<void> close() => _arrivals.close();

  Future<http.Response> _handle(http.Request request) async {
    final recorded = ApiRequest(
      path: request.url.path,
      headers: <String, String>{
        for (final header in request.headers.entries)
          header.key.toLowerCase(): header.value,
      },
      bodyBytes: request.bodyBytes,
    );
    requests.add(recorded);
    if (!_arrivals.isClosed) _arrivals.add(recorded);
    final queue = _queued[recorded.path];
    final responder = queue != null && queue.isNotEmpty
        ? queue.removeAt(0)
        : _defaults[recorded.path];
    if (responder == null) {
      return jsonResponse(
        problemJson(404, 'not_found'),
        status: 404,
        contentType: 'application/problem+json',
      );
    }
    return responder(recorded);
  }
}

/// A JSON answer encoded as UTF-8 bytes.
http.Response jsonResponse(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const <String, String>{},
  String contentType = 'application/json',
}) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: <String, String>{'content-type': contentType, ...headers},
    );

/// An RFC 9457 problem body (contract section 10.1).
Map<String, Object?> problemJson(
  int status,
  String code, {
  String? detail,
  String? requestId,
  List<Map<String, Object?>>? errors,
}) =>
    <String, Object?>{
      'type': 'https://docs.becklinks.com/errors/$code',
      'title': 'Problem $code',
      'status': status,
      'code': code,
      'detail': detail,
      'request_id': requestId,
      if (errors != null) 'errors': errors,
    };

/// A problem answer with [status] and [code].
http.Response problemResponse(
  int status,
  String code, {
  String? detail,
  String? requestId,
  List<Map<String, Object?>>? errors,
  Map<String, String> headers = const <String, String>{},
}) =>
    jsonResponse(
      problemJson(
        status,
        code,
        detail: detail,
        requestId: requestId,
        errors: errors,
      ),
      status: status,
      headers: headers,
      contentType: 'application/problem+json',
    );

/// A responder for "no connection".
ApiResponder get offline =>
    (_) => throw http.ClientException('Connection refused');

/// A responder that never answers.
ApiResponder get hang => (_) => Completer<http.Response>().future;
