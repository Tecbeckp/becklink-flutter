# R8 rules merged into every app that uses becklink_flutter.

# Flutter creates the plugin from GeneratedPluginRegistrant, which the embedding loads by
# reflection; keep the entry point so release builds can always register it.
-keep class app.becklink.flutter.BeckLinkPlugin { public <init>(); }

# Nothing else needs keeping: the native layer uses no reflection, the channel names and map keys
# are string constants, and the installreferrer library talks to the Play Store through an AIDL
# proxy that identifies itself by a string descriptor and transaction codes, so R8 may rename and
# shrink every other class.
