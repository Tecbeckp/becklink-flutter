import 'dart:async';

import 'package:becklink_flutter/src/platform/becklink_platform.dart';
import 'package:becklink_flutter/src/platform/device_context.dart';
import 'package:becklink_flutter/src/platform/install_id_seed_result.dart';
import 'package:becklink_flutter/src/platform/install_referrer_result.dart';
import 'package:becklink_flutter/src/platform/platform_link.dart';

/// The native layers of one app process, as the SDK sees them through
/// `BeckLinkPlatform`, with the behaviour `doc/platform-channel.md`
/// promises: the launch link is handed out once, links that arrive before
/// the SDK listens are buffered, and every call records what it was asked.
final class FakePlatform implements BeckLinkPlatform {
  FakePlatform({
    this.storagePath,
    this.initialLink,
    this.seed = const InstallIdSeedAbsent(),
    this.saveSeedResult = false,
    InstallReferrerResult? referrer,
    this.pasteboardUrl,
  }) : referrer = referrer ??
            const InstallReferrerUnavailable(
              InstallReferrerFailure.notApplicable,
            );

  /// What `getStorageDirectory` answers; `null` keeps the SDK in memory.
  String? storagePath;

  /// When set, `getStorageDirectory` waits for it before answering.
  Completer<void>? storageGate;

  /// The launch link, handed out by the first `getInitialLink` call only.
  PlatformLink? initialLink;

  /// What `getInstallIdSeed` answers (the iOS Keychain).
  InstallIdSeedResult seed;

  /// What `saveInstallIdSeed` answers: `true` on iOS, `false` on Android.
  bool saveSeedResult;

  /// What `getInstallReferrer` answers.
  InstallReferrerResult referrer;

  /// What `readPasteboardUrl` answers.
  String? pasteboardUrl;

  /// What `getDeviceContext` answers.
  DeviceContext deviceContext = const DeviceContext(
    osVersion: '15',
    appVersion: '1.2.3',
    appBuild: '45',
    deviceModel: 'Pixel 8',
    locale: 'en-US',
  );

  /// Install IDs passed to `saveInstallIdSeed`, in order.
  final List<String> savedSeeds = <String>[];

  /// The `allowedHosts` of every `readPasteboardUrl` call.
  final List<List<String>> pasteboardReads = <List<String>>[];

  int initialLinkCalls = 0;
  int seedReads = 0;
  int referrerReads = 0;
  int deviceContextReads = 0;

  // Single-subscription: like the native layer, it keeps links until the
  // SDK listens.
  final StreamController<PlatformLink> _links =
      StreamController<PlatformLink>();

  /// The operating system hands [link] to the running app.
  void deliverLink(PlatformLink link) => _links.add(link);

  /// Ends the link stream; call when the test's "process" ends.
  Future<void> dispose() async {
    // Not awaited: a single-subscription stream nobody listened to (the SDK
    // was never configured) completes its close() only once listened to.
    unawaited(_links.close());
  }

  @override
  Future<PlatformLink?> getInitialLink() async {
    initialLinkCalls++;
    final link = initialLink;
    initialLink = null;
    return link;
  }

  @override
  Stream<PlatformLink> get links => _links.stream;

  @override
  Future<String?> getStorageDirectory() async {
    final gate = storageGate;
    if (gate != null) await gate.future;
    return storagePath;
  }

  @override
  Future<InstallIdSeedResult> getInstallIdSeed() async {
    seedReads++;
    return seed;
  }

  @override
  Future<bool> saveInstallIdSeed(String installId) async {
    savedSeeds.add(installId);
    return saveSeedResult;
  }

  @override
  Future<InstallReferrerResult> getInstallReferrer() async {
    referrerReads++;
    return referrer;
  }

  @override
  Future<String?> readPasteboardUrl({
    required List<String> allowedHosts,
  }) async {
    pasteboardReads.add(allowedHosts);
    return pasteboardUrl;
  }

  @override
  Future<DeviceContext> getDeviceContext() async {
    deviceContextReads++;
    return deviceContext;
  }

  @override
  bool get isDebugBuild => true;
}
