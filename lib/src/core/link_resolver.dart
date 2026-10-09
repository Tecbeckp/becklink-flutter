import 'dart:async';

import '../http/api_client.dart';
import '../http/api_client_closed_exception.dart';
import '../http/api_endpoint.dart';
import '../logging/sdk_logger.dart';
import '../models/becklink_error_code.dart';
import '../models/becklink_exception.dart';
import '../models/link_event.dart';
import '../platform/platform_link.dart';
import 'link_url_rules.dart';

/// Who is opening a link, as `POST /v1/sdk/open` needs it (contract section
/// 8.3): with tracking off, or before an install ID exists, the link is only
/// resolved and nothing is recorded.
typedef OpenRequester = ({String? installId, String? userId});

/// Resolves a link URL the app received into the `LinkEvent` the app gets
/// (`POST /v1/sdk/open`, §29.4), within a deadline. Internal to the SDK.
final class LinkResolver {
  /// Creates a resolver.
  ///
  /// [api] returns the current client; [requestContext] the request
  /// `context`, or `null` on a platform the SDK API does not support (then
  /// every link gets the event built on the device); [requester] the
  /// install and user ID to send, both `null` while tracking is off.
  LinkResolver({
    required ApiClient Function() api,
    required SdkLogger logger,
    required Future<Map<String, Object?>?> Function() requestContext,
    required OpenRequester Function() requester,
    required bool isIos,
  })  : _api = api,
        _logger = logger,
        _requestContext = requestContext,
        _requester = requester,
        _isIos = isIos;

  final ApiClient Function() _api;
  final SdkLogger _logger;
  final Future<Map<String, Object?>?> Function() _requestContext;
  final OpenRequester Function() _requester;
  final bool _isIos;

  /// The event for [link] (whose URL is [url]), at the latest after
  /// [deadline]:
  ///
  /// - the service's `link_event` when it answers in time;
  /// - `null` when the service says the URL is not an active link
  ///   (`link_not_found`: disabled, expired or unknown);
  /// - otherwise (no answer in time, offline, any other failure) the event
  ///   built on the device from the URL (contract section 7.3 "Offline").
  ///
  /// The request goes on after [deadline], so the service still records the
  /// open, but its late answer is dropped: the app already got an event for
  /// this delivery. Never throws.
  Future<LinkEvent?> resolve(
    PlatformLink link,
    BeckLinkUrl url, {
    required Duration deadline,
  }) {
    final result = Completer<LinkEvent?>();
    final timer = Timer(deadline, () {
      if (result.isCompleted) return;
      _logger.info(
        'The link was not resolved within ${deadline.inMilliseconds} ms; '
        'delivering it without link data',
      );
      result.complete(offlineEvent(link, url));
    });
    void finish(LinkEvent? event) {
      timer.cancel();
      if (!result.isCompleted) {
        result.complete(event);
      } else {
        _logger.debug('A late link resolution was dropped');
      }
    }

    unawaited(
      _open(link, url).then(
        finish,
        // Only an SDK bug gets here; the link must still reach the app, and
        // nothing may surface as an unhandled error.
        onError: (Object error) {
          _logger.error('Resolving a link failed unexpectedly', error);
          finish(offlineEvent(link, url));
        },
      ),
    );
    return result.future;
  }

  /// The event built on the device for [link] (see [offlineLinkEvent]).
  LinkEvent offlineEvent(PlatformLink link, BeckLinkUrl url) =>
      offlineLinkEvent(url, receivedAt: link.receivedAt, isIos: _isIos);

  Future<LinkEvent?> _open(PlatformLink link, BeckLinkUrl url) async {
    final context = await _requestContext();
    if (context == null || !url.fitsRequest) return offlineEvent(link, url);
    final requester = _requester();
    final installId = requester.installId;
    try {
      return await _api().post(
        ApiEndpoint.open,
        body: <String, Object?>{
          'url': url.received,
          'opened_at': link.receivedAt.toIso8601String(),
          'tracking_enabled': installId != null,
          if (installId != null) 'install_id': installId,
          if (installId != null) 'user_id': requester.userId,
          'context': context,
        },
        read: (response) => readLinkEvent(response.body.object('link_event')),
      );
    } on BeckLinkException catch (error) {
      switch (error.code) {
        case BeckLinkErrorCode.linkNotFound:
          _logger.info(
              'The link is not active in this project environment', error);
          return null;
        case BeckLinkErrorCode.invalidKey:
        case BeckLinkErrorCode.invalidRequest:
          _logger.error(
            'The link could not be resolved; delivering it without link data',
            error,
          );
        case BeckLinkErrorCode.network:
        case BeckLinkErrorCode.timeout:
        case BeckLinkErrorCode.rateLimited:
        case BeckLinkErrorCode.notConfigured:
        case BeckLinkErrorCode.trackingDisabled:
          _logger.info(
            'The link could not be resolved; delivering it without link data',
            error,
          );
      }
      return offlineEvent(link, url);
    } on ApiClientClosedException {
      return offlineEvent(link, url);
    }
  }
}
