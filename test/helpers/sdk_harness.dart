import 'dart:io';
import 'dart:math';

import 'package:becklink_flutter/src/becklink.dart';
import 'package:becklink_flutter/src/http/retry_policy.dart';
import 'package:becklink_flutter/src/logging/sdk_logger.dart';
import 'package:becklink_flutter/src/models/log_level.dart';
import 'package:becklink_flutter/src/storage/event_queue.dart';
import 'package:becklink_flutter/src/storage/file_storage_directory.dart';
import 'package:becklink_flutter/src/storage/sdk_state_store.dart';
import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:flutter_test/flutter_test.dart';

import 'fake_platform.dart';
import 'fake_sdk_api.dart';
import 'fixtures.dart';
import 'test_support.dart';

/// One device for `BeckLink` tests: a storage folder that survives
/// "restarts", the fake SDK API, a hand-moved clock and the log.
///
/// Each [start] is one app process: a new `BeckLink` (through
/// `BeckLink.withDependencies`) and a new [FakePlatform] on the same
/// storage, so a test can kill and relaunch the app.
final class SdkHarness {
  SdkHarness({this.targetPlatform = TargetPlatform.android})
      : storage = Directory.systemTemp.createTempSync('becklink_sdk_test_');

  /// The platform the SDK reports to the service.
  final TargetPlatform targetPlatform;

  /// The SDK's storage folder on this "device".
  final Directory storage;

  final FakeSdkApi api = FakeSdkApi();
  final LogCapture logs = LogCapture();
  final TestClock clock = TestClock();

  /// The native layers of the current process.
  late FakePlatform platform;

  /// The SDK of the current process.
  late BeckLink sdk;

  bool _running = false;
  static int _seed = 1;

  /// Starts a new process; [setUpPlatform] adjusts its native layers (the
  /// launch link, the Keychain seed, the install referrer, …) before the
  /// SDK sees them. Disposes the previous process first.
  Future<BeckLink> start({
    void Function(FakePlatform platform)? setUpPlatform,
  }) async {
    await stop();
    final process = FakePlatform(
      storagePath: storage.path,
      saveSeedResult: targetPlatform == TargetPlatform.iOS,
    );
    setUpPlatform?.call(process);
    platform = process;
    sdk = BeckLink.withDependencies(
      platform: process,
      httpClient: api.client,
      baseUrl: fakeBaseUrl,
      logSink: logs.add,
      targetPlatform: targetPlatform,
      now: clock.now,
      // A new seed per process: the same seed would repeat the IDs of the
      // previous process.
      random: Random(_seed++),
      retryPolicy: const RetryPolicy(
        baseDelay: Duration(milliseconds: 1),
        maxDelay: Duration(milliseconds: 5),
      ),
      compressEvents: false,
    );
    _running = true;
    return sdk;
  }

  /// Starts a process and configures its SDK.
  Future<BeckLink> launch({
    String apiKey = testKey,
    bool enablePasteboard = false,
    Duration firstOpenTimeout = const Duration(seconds: 5),
    bool handlePlatformLinks = true,
    void Function(FakePlatform platform)? setUpPlatform,
  }) async {
    final started = await start(setUpPlatform: setUpPlatform);
    await started.configure(
      apiKey: apiKey,
      logLevel: LogLevel.debug,
      enablePasteboard: enablePasteboard,
      firstOpenTimeout: firstOpenTimeout,
      handlePlatformLinks: handlePlatformLinks,
    );
    return started;
  }

  /// A later launch: a first process registers the install (the first open
  /// completes with the fake API's answer), then a new process starts.
  Future<BeckLink> launchRegistered({
    Duration firstOpenTimeout = const Duration(seconds: 5),
    void Function(FakePlatform platform)? setUpPlatform,
  }) async {
    final first = await launch();
    await first.getAttribution();
    return launch(
      firstOpenTimeout: firstOpenTimeout,
      setUpPlatform: setUpPlatform,
    );
  }

  /// Ends the current process: the SDK stops and its writes finish.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await sdk.dispose();
    await platform.dispose();
  }

  /// Ends the current process and deletes the device's storage.
  Future<void> dispose() async {
    await stop();
    await api.close();
    // Windows keeps a just-written file locked for a moment (antivirus, the
    // indexer), so a delete can fail with errno 32: try a few times and leave
    // the folder to the OS temp cleanup if it stays locked. The folder holds
    // test data only.
    for (var attempt = 0; storage.existsSync() && attempt < 5; attempt++) {
      try {
        await storage.delete(recursive: true);
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  /// The state stored on the device, read the way the SDK reads it. Call
  /// after [stop], so every write has finished.
  Future<SdkStateStore> storedState() => SdkStateStore.open(
        directory: FileStorageDirectory(storage),
        logger: SdkLogger(level: LogLevel.none),
        now: clock.now,
      );

  /// The event queue stored on the device. Call after [stop]; close it
  /// when done.
  Future<EventQueue> storedQueue() => EventQueue.open(
        directory: FileStorageDirectory(storage),
        logger: SdkLogger(level: LogLevel.none),
        now: clock.now,
      );
}

/// A new device for the current test, disposed when the test ends.
SdkHarness newDevice([TargetPlatform targetPlatform = TargetPlatform.android]) {
  final device = SdkHarness(targetPlatform: targetPlatform);
  addTearDown(device.dispose);
  return device;
}
