import 'dart:async';

import 'package:flutter/widgets.dart';

/// Follows the app's lifecycle for the SDK. Internal to the SDK.
///
/// - [firstForeground] completes once the app is visible (lifecycle
///   `resumed` or `inactive`, or its first frame was drawn). The SDK reads
///   the launch link and starts a session only then: a headless engine, such
///   as a push-messaging background isolate, never gets there, so it never
///   asks the native layer for a launch link (Android would wait for an
///   activity that never comes) and never sends a first open.
/// - [onBackground] runs once each time the app leaves the foreground
///   (`hidden` or `paused`), [onForeground] when it is `resumed` again,
///   with the time it spent in the background.
final class AppLifecycleWatcher with WidgetsBindingObserver {
  /// Creates a watcher; call [attach] to start it.
  AppLifecycleWatcher({
    required this.onForeground,
    required this.onBackground,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Called when the app returns to the foreground after [onBackground].
  final void Function(Duration backgroundFor) onForeground;

  /// Called when the app leaves the foreground.
  final void Function() onBackground;

  final DateTime Function() _now;
  final Completer<void> _firstForeground = Completer<void>();
  WidgetsBinding? _binding;
  DateTime? _backgroundSince;

  /// Completes once the app was in the foreground.
  Future<void> get firstForeground => _firstForeground.future;

  /// Whether the app was in the foreground at least once.
  bool get hasBeenInForeground => _firstForeground.isCompleted;

  /// Starts watching [binding]. Safe to call more than once.
  void attach(WidgetsBinding binding) {
    if (_binding != null) return;
    _binding = binding;
    binding.addObserver(this);
    final state = binding.lifecycleState;
    if (state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive) {
      _openGate();
    }
    // A visible app draws frames even when its embedding was told not to
    // report lifecycle states (an add-to-app option); a headless engine
    // never draws.
    unawaited(binding.waitUntilFirstFrameRasterized.then((_) => _openGate()));
  }

  /// Stops watching.
  void detach() {
    _binding?.removeObserver(this);
    _binding = null;
  }

  // Plain comparisons rather than an exhaustive switch: a state added by a
  // later Flutter (as `hidden` was in 3.13) must not break compiling this
  // package. `detached` and unknown states need nothing.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _openGate();
      final since = _backgroundSince;
      if (since != null) {
        _backgroundSince = null;
        onForeground(_now().difference(since));
      }
    } else if (state == AppLifecycleState.inactive) {
      // Also the step between paused and resumed, and on iOS the state of
      // an app at launch: visible, if not yet interactive.
      _openGate();
    } else if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused) {
      // hidden and paused both arrive on the way out; one background period
      // is reported once.
      if (_backgroundSince == null) {
        _backgroundSince = _now();
        onBackground();
      }
    }
  }

  void _openGate() {
    if (!_firstForeground.isCompleted) _firstForeground.complete();
  }
}
