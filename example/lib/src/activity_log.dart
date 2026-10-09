import 'dart:async';
import 'dart:collection';

import 'package:becklink_flutter/becklink_flutter.dart';
import 'package:flutter/foundation.dart';

/// What an [ActivityEntry] records.
enum ActivityKind {
  /// One attempt of an SDK API request (`BeckLink.onApiCall`).
  request,

  /// A link the app received on `onLink`.
  link,

  /// Something done from this app's screens.
  action,
}

/// One timestamped line of the debug timeline.
@immutable
class ActivityEntry {
  const ActivityEntry({
    required this.time,
    required this.kind,
    required this.title,
    this.detail,
    this.isError = false,
    this.call,
  });

  /// When it happened, in local time.
  final DateTime time;
  final ActivityKind kind;
  final String title;
  final String? detail;
  final bool isError;

  /// The request record, for [ActivityKind.request].
  final BeckLinkApiCall? call;

  Map<String, Object?> toJson() => <String, Object?>{
    'time': time.toUtc().toIso8601String(),
    'kind': kind.name,
    'title': title,
    if (detail != null) 'detail': detail,
    if (isError) 'error': true,
    if (call != null) 'request': call!.toJson(),
  };
}

/// The debug timeline: SDK requests (with status, request ID and
/// `Idempotent-Replayed`), incoming links and the actions taken in this
/// app. Never holds API keys: request records carry none, and actions log
/// only masked values.
class ActivityLog extends ChangeNotifier {
  ActivityLog({this.capacity = 300});

  /// Most entries kept; older ones are dropped.
  final int capacity;

  final ListQueue<ActivityEntry> _entries = ListQueue<ActivityEntry>();
  bool _notifyScheduled = false;

  /// The kept entries, newest first.
  List<ActivityEntry> get newestFirst => _entries.toList().reversed.toList();

  /// The newest request to [path] (for example `/v1/sdk/init`), if any.
  BeckLinkApiCall? lastCallTo(String path) {
    for (final entry in _entries.toList().reversed) {
      final call = entry.call;
      if (call != null && call.path == path) return call;
    }
    return null;
  }

  void addCall(BeckLinkApiCall call) {
    final status = call.statusCode?.toString() ?? 'no answer';
    final parts = <String>[
      '${call.duration.inMilliseconds} ms',
      if (call.attempt > 1) 'attempt ${call.attempt}',
      if (call.requestId != null) 'request ${call.requestId}',
      if (call.idempotentReplayed) 'Idempotent-Replayed: true',
      if (call.errorCode != null) call.errorCode!.wireValue,
    ];
    _add(
      ActivityEntry(
        time: DateTime.now(),
        kind: ActivityKind.request,
        title: '${call.method} ${call.path} → $status',
        detail: parts.join(' · '),
        isError: !call.succeeded,
        call: call,
      ),
    );
  }

  void addLink(LinkEvent event) => _add(
    ActivityEntry(
      time: DateTime.now(),
      kind: ActivityKind.link,
      title: '${event.isDeferred ? 'Deferred link' : 'Link'} ${event.path}',
      detail:
          '${event.url} · ${event.matchMethod.wireValue} · '
          '${event.confidence.wireValue}',
    ),
  );

  void addAction(String title, {String? detail, bool isError = false}) => _add(
    ActivityEntry(
      time: DateTime.now(),
      kind: ActivityKind.action,
      title: title,
      detail: detail,
      isError: isError,
    ),
  );

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  void _add(ActivityEntry entry) {
    _entries.addLast(entry);
    while (_entries.length > capacity) {
      _entries.removeFirst();
    }
    // Records can arrive while a frame is being built; telling listeners
    // after the current work never marks a widget dirty mid-build.
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      notifyListeners();
    });
  }
}
