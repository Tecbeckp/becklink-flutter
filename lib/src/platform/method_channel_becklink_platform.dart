import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logging/sdk_logger.dart';
import '../util/single_line.dart';
import '../util/uuid.dart';
import 'becklink_platform.dart';
import 'device_context.dart';
import 'install_id_seed_result.dart';
import 'install_referrer_result.dart';
import 'pasteboard_click_url.dart';
import 'platform_link.dart';

/// Name of the method channel that carries every call (T2 decision).
const String methodChannelName = 'app.becklink.flutter/methods';

/// Name of the event channel that carries links received while the app
/// runs.
const String linkChannelName = 'app.becklink.flutter/links';

/// How long each kind of native call may take before the SDK gives up and
/// uses the fallback. Deadlines guard against a call that never completes;
/// they are not latency targets, since `configure()` never waits for them.
@immutable
final class PlatformTimeouts {
  /// Creates the deadlines; the defaults suit production.
  const PlatformTimeouts({
    this.lookup = const Duration(seconds: 10),
    this.installReferrer = const Duration(seconds: 15),
    this.pasteboard = const Duration(seconds: 60),
  });

  /// Local lookups: launch link, storage directory, Keychain, device
  /// context, and starting or stopping the link stream. Native work takes
  /// milliseconds, but the platform thread can be busy while the app
  /// starts.
  final Duration lookup;

  /// Reading the install referrer: binding Play's service and one IPC call.
  /// Longer than the native layer's own 10 s deadline, so the native answer
  /// wins when both are close.
  final Duration installReferrer;

  /// Reading the pasteboard, which can wait for the user to answer the
  /// system's paste prompt.
  final Duration pasteboard;
}

/// [BeckLinkPlatform] over the `app.becklink.flutter/*` platform channels,
/// implemented by the plugin's Kotlin and Swift layers as described in
/// `doc/platform-channel.md`.
///
/// Use one instance per isolate: the link stream installs the event
/// channel's only message handler. Internal to the SDK.
final class MethodChannelBeckLinkPlatform implements BeckLinkPlatform {
  /// Creates the bridge. Does no platform work.
  ///
  /// [binaryMessenger] defaults to the Flutter binding's messenger, which
  /// must exist before the first call. [timeouts] and [now] (the clock for
  /// links whose native receive time is missing) replace the defaults in
  /// tests.
  MethodChannelBeckLinkPlatform({
    required SdkLogger logger,
    BinaryMessenger? binaryMessenger,
    PlatformTimeouts timeouts = const PlatformTimeouts(),
    DateTime Function()? now,
  })  : _logger = logger,
        _methods = MethodChannel(methodChannelName, _codec, binaryMessenger),
        _linkChannel = MethodChannel(linkChannelName, _codec, binaryMessenger),
        _timeouts = timeouts,
        _now = now ?? DateTime.now;

  static const MethodCodec _codec = StandardMethodCodec();

  final SdkLogger _logger;
  final MethodChannel _methods;

  /// The event channel's control side (`listen`/`cancel`); events arrive
  /// through the message handler set on its name.
  final MethodChannel _linkChannel;

  final PlatformTimeouts _timeouts;
  final DateTime Function() _now;

  bool _missingPluginReported = false;

  // Lives as long as this instance (in apps: the process), so it is never
  // closed; the event channel's own StreamController is not either.
  late final StreamController<PlatformLink> _linkEvents =
      StreamController<PlatformLink>.broadcast(
    onListen: _startLinkEvents,
    onCancel: _stopLinkEvents,
  );

  @override
  Future<PlatformLink?> getInitialLink() async {
    const method = 'getInitialLink';
    final reply = await _invoke(_methods, method, timeout: _timeouts.lookup);
    if (reply is! _Answered || reply.value == null) return null;
    final link = readPlatformLink(reply.value, now: _now);
    if (link == null) _reportMalformed(method);
    return link;
  }

  @override
  Stream<PlatformLink> get links => _linkEvents.stream;

  @override
  Future<String?> getStorageDirectory() async {
    const method = 'getStorageDirectory';
    final reply = await _invoke(_methods, method, timeout: _timeouts.lookup);
    if (reply is! _Answered) return null;
    final path = reply.value;
    // Android and iOS paths are POSIX; checked by hand so the check does
    // not depend on the operating system the tests run on.
    if (path is! String || !path.startsWith('/')) {
      _reportMalformed(method);
      return null;
    }
    return path;
  }

  @override
  Future<InstallIdSeedResult> getInstallIdSeed() async {
    const method = 'getInstallIdSeed';
    final reply = await _invoke(_methods, method, timeout: _timeouts.lookup);
    switch (reply) {
      case _Answered(:final value):
        if (value == null) return const InstallIdSeedAbsent();
        if (value is String) return InstallIdSeedFound(value);
        _reportMalformed(method);
        return const InstallIdSeedUnavailable();
      case _Unanswered(cause: _NoAnswer.missingPlugin):
        return const InstallIdSeedAbsent();
      case _Unanswered(cause: _NoAnswer.platformError || _NoAnswer.timeout):
        return const InstallIdSeedUnavailable();
    }
  }

  @override
  Future<bool> saveInstallIdSeed(String installId) async {
    final normalized = normalizeUuid(installId);
    if (normalized == null) {
      // No ArgumentError.value: the message must not carry the ID.
      throw ArgumentError('must be a UUID', 'installId');
    }
    const method = 'saveInstallIdSeed';
    final reply = await _invoke(
      _methods,
      method,
      arguments: <String, Object?>{'install_id': normalized},
      timeout: _timeouts.lookup,
    );
    if (reply is! _Answered) return false;
    final stored = reply.value;
    if (stored is! bool) {
      _reportMalformed(method);
      return false;
    }
    return stored;
  }

  @override
  Future<InstallReferrerResult> getInstallReferrer() async {
    const method = 'getInstallReferrer';
    final reply = await _invoke(
      _methods,
      method,
      timeout: _timeouts.installReferrer,
    );
    switch (reply) {
      case _Answered(:final value):
        final result = readInstallReferrer(value);
        if (result != null) return result;
        _reportMalformed(method);
        return const InstallReferrerUnavailable(
          InstallReferrerFailure.platformError,
        );
      case _Unanswered(:final cause):
        return InstallReferrerUnavailable(switch (cause) {
          _NoAnswer.missingPlugin => InstallReferrerFailure.notApplicable,
          _NoAnswer.platformError => InstallReferrerFailure.platformError,
          _NoAnswer.timeout => InstallReferrerFailure.timeout,
        });
    }
  }

  @override
  Future<String?> readPasteboardUrl({
    required List<String> allowedHosts,
  }) async {
    final hosts = checkPasteboardHosts(allowedHosts);
    const method = 'readPasteboardUrl';
    final reply = await _invoke(
      _methods,
      method,
      arguments: <String, Object?>{'allowed_hosts': hosts},
      timeout: _timeouts.pasteboard,
    );
    if (reply is! _Answered || reply.value == null) return null;
    final url = reply.value;
    if (url is! String || !isPasteboardClickUrl(url, hosts)) {
      // A native bug; the text itself stays out of the log.
      _logger.error(
        'Native call $method answered with text that is not a click URL of '
        'an allowed host; it was discarded',
      );
      return null;
    }
    return url;
  }

  @override
  Future<DeviceContext> getDeviceContext() async {
    const method = 'getDeviceContext';
    final reply = await _invoke(_methods, method, timeout: _timeouts.lookup);
    if (reply is! _Answered) return DeviceContext.unknown;
    final context = readDeviceContext(reply.value);
    if (context != null) return context;
    _reportMalformed(method);
    return DeviceContext.unknown;
  }

  // Dart's compile-time mode rather than a native flag: it cannot be
  // changed at run time, needs no plugin, and release builds tree-shake the
  // code it guards.
  @override
  bool get isDebugBuild => kDebugMode;

  /// Calls [method] on [channel] and turns every platform failure into an
  /// [_Unanswered] reply, logged without arguments or answers.
  Future<_Reply> _invoke(
    MethodChannel channel,
    String method, {
    required Duration timeout,
    Map<String, Object?>? arguments,
  }) async {
    try {
      final value = await channel
          .invokeMethod<Object>(method, arguments)
          .timeout(timeout);
      return _Answered(value);
    } on MissingPluginException {
      _reportMissingPlugin();
      return const _Unanswered(_NoAnswer.missingPlugin);
    } on PlatformException catch (error) {
      _logger.error(
        'Native call $method failed with code '
        '${singleLine(error.code, maxLength: 64)}',
      );
      return const _Unanswered(_NoAnswer.platformError);
    } on TimeoutException {
      _logger.error(
        'Native call $method gave no answer within '
        '${timeout.inMilliseconds} ms',
      );
      return const _Unanswered(_NoAnswer.timeout);
    }
  }

  // Mirrors EventChannel.receiveBroadcastStream, which reports a missing
  // plugin through FlutterError.reportError: apps often send that to their
  // crash reporter, and the stream would end or carry errors. Here failures
  // are logged, and the stream neither ends nor errs.
  void _startLinkEvents() {
    _linkChannel.binaryMessenger
        .setMessageHandler(linkChannelName, _onLinkMessage);
    unawaited(_invoke(_linkChannel, 'listen', timeout: _timeouts.lookup));
  }

  void _stopLinkEvents() {
    _linkChannel.binaryMessenger.setMessageHandler(linkChannelName, null);
    unawaited(_invoke(_linkChannel, 'cancel', timeout: _timeouts.lookup));
  }

  Future<ByteData?> _onLinkMessage(ByteData? message) async {
    const source = 'link event';
    // A null message is end-of-stream, which the native layer never sends;
    // links that might follow must still arrive, so the stream stays open.
    if (message == null) {
      _logger.debug('The native layer ended the link stream; ignored');
      return null;
    }
    final Object? event;
    try {
      event = _codec.decodeEnvelope(message);
    } on PlatformException catch (error) {
      _logger.error(
        'The native link stream reported an error with code '
        '${singleLine(error.code, maxLength: 64)}',
      );
      return null;
    } on FormatException {
      _reportMalformed(source);
      return null;
    }
    final link = readPlatformLink(event, now: _now);
    if (link == null) {
      _reportMalformed(source);
    } else {
      _linkEvents.add(link);
    }
    return null;
  }

  void _reportMissingPlugin() {
    if (_missingPluginReported) return;
    _missingPluginReported = true;
    _logger.error(
      'The becklink_flutter native plugin is not registered in this Flutter '
      'engine: incoming links, storage, install referrer, pasteboard, '
      'Keychain and device details are unavailable',
    );
  }

  void _reportMalformed(String source) => _logger.error(
        'Native $source answered in a shape this SDK version does not '
        'understand; ignored',
      );
}

/// The outcome of one native call.
sealed class _Reply {
  const _Reply();
}

/// The native layer answered with [value].
final class _Answered extends _Reply {
  const _Answered(this.value);

  final Object? value;
}

/// The native layer gave no usable answer.
final class _Unanswered extends _Reply {
  const _Unanswered(this.cause);

  final _NoAnswer cause;
}

/// Why a native call gave no usable answer.
enum _NoAnswer {
  /// No handler for the channel: plugin not registered in this engine, or
  /// a platform without a native layer.
  missingPlugin,

  /// The native layer answered with an error.
  platformError,

  /// No answer within the deadline.
  timeout,
}
