import 'package:flutter/widgets.dart';

import 'src/app.dart';
import 'src/config/config_store.dart';
import 'src/config/debug_config.dart';
import 'src/demo_state.dart';
import 'src/sdk_log_buffer.dart';
import 'src/sdk_setup.dart';

/// Optional build-time defaults, used only until a configuration is saved
/// on the Configure screen; never committed:
/// `flutter run --dart-define=BECKLINK_KEY=pk_test_… --dart-define=BECKLINK_API=http://192.168.1.20:4100`.
const String _defaultKey = String.fromEnvironment('BECKLINK_KEY');
const String _defaultApi = String.fromEnvironment(
  'BECKLINK_API',
  defaultValue: DebugConfig.productionApiBaseUrl,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Before configure(), so the Debug screen also shows the SDK's first lines.
  final logs = SdkLogBuffer()..captureDebugPrint();
  final store = await ConfigStore.open();
  final saved = await store.load();
  final config =
      saved ??
      DebugConfig.initial.copyWith(
        apiKey: _defaultKey,
        apiBaseUrl: _defaultApi,
      );
  final demo = DemoState(
    setup: const SdkKeyMissing(),
    logs: logs,
    initialLogLevel: config.logLevel,
    configStore: store,
    config: config,
  );
  // configure() returns at once and does its work in the background, so the
  // app's first frame is never held up. It runs before runApp, as the SDK's
  // README asks, so the launch link is handled like in a real app.
  if (config.isComplete) await demo.applyConfig(config, save: false);
  runApp(ExampleApp(demo: demo));
}
