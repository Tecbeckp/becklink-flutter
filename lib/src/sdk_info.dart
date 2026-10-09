/// Identity of this SDK as the Beck Link SDK API sees it (`X-SDK-Name` and
/// `X-SDK-Version`, contract section 4.1). Internal to the SDK.
library;

/// The package name, sent as `X-SDK-Name`.
const String sdkName = 'becklink_flutter';

/// The SemVer of this SDK, sent as `X-SDK-Version`.
///
/// Must equal `version` in pubspec.yaml: the server decides which enum
/// values it may send by this value (contract section 13), so a stale value
/// could deliver values this SDK version does not know.
const String sdkVersion = '0.1.1';
