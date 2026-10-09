import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../demo_state.dart';
import '../../widgets/setup_card.dart';
import 'action_sections.dart';
import 'log_section.dart';
import 'state_sections.dart';

/// Everything the SDK reported, and buttons to exercise it, in three tabs:
/// state, actions and logs. Reachable only from inside the app, never from
/// a link.
class DebugScreen extends StatelessWidget {
  const DebugScreen({super.key, required this.demo});

  final DemoState demo;

  @override
  Widget build(BuildContext context) => DefaultTabController(
    length: 3,
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Debug'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Configure',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => context.go('/config'),
          ),
        ],
        bottom: const TabBar(
          tabs: <Widget>[
            Tab(icon: Icon(Icons.insights_outlined), text: 'State'),
            Tab(icon: Icon(Icons.play_circle_outline), text: 'Actions'),
            Tab(icon: Icon(Icons.receipt_long_outlined), text: 'Logs'),
          ],
        ),
      ),
      body: TabBarView(
        children: <Widget>[
          _Tab(
            children: <Widget>[
              ListenableBuilder(
                listenable: demo,
                builder: (context, _) => SetupCard(setup: demo.setup),
              ),
              SdkStateSection(demo: demo),
              InitSection(demo: demo),
              FirstOpenSection(demo: demo),
              AttributionSection(demo: demo),
              LastOpenSection(demo: demo),
              IncomingLinksSection(demo: demo),
            ],
          ),
          _Tab(
            children: <Widget>[
              LinkToolsSection(demo: demo),
              EventsSection(demo: demo),
              CreateLinkSection(demo: demo),
              PrivacySection(demo: demo),
              // Compiled out of profile and release builds.
              if (kDebugMode) ResetInstallSection(demo: demo),
              ReportSection(demo: demo),
            ],
          ),
          _Tab(
            children: <Widget>[
              ReportSection(demo: demo),
              ActivitySection(demo: demo),
              LogSection(demo: demo),
            ],
          ),
        ],
      ),
    ),
  );
}

/// One tab's sections. Kept alive and built at once, so text typed into a
/// section survives scrolling and switching tabs.
class _Tab extends StatefulWidget {
  const _Tab({required this.children});

  final List<Widget> children;

  @override
  State<_Tab> createState() => _TabState();
}

class _TabState extends State<_Tab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final (index, child) in widget.children.indexed) ...<Widget>[
            if (index > 0) const SizedBox(height: 8),
            child,
          ],
        ],
      ),
    );
  }
}
