# becklink_flutter (renamed)

This package is now called **[becklinks_flutter](https://pub.dev/packages/becklinks_flutter)**.
`becklink_flutter` 0.2.1 only re-exports it, so existing apps keep working after `flutter pub upgrade`.

To move over, change `pubspec.yaml` and your imports:

```yaml
dependencies:
  becklinks_flutter: ^0.3.0
```

```dart
import 'package:becklinks_flutter/becklinks_flutter.dart';
```

The API is unchanged. Documentation: https://docs.becklinks.com/flutter-sdk
