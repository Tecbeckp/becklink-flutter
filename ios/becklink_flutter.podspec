#
# CocoaPods integration for apps that have not switched to Swift Package Manager.
# Validate with `pod lib lint becklink_flutter.podspec` before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'becklink_flutter'
  s.version          = '0.1.1'
  s.summary          = 'Deep links, deferred deep links and attribution for Flutter apps with Beck Link.'
  s.description      = <<-DESC
Deep links, deferred deep links and attribution for Flutter apps with Beck Link.
                       DESC
  s.homepage         = 'https://becklinks.com'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Beck Link'
  s.source           = { :path => '.' }
  s.source_files     = 'becklink_flutter/Sources/becklink_flutter/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.9'

  # Apple requires SDKs to ship their own privacy manifest.
  s.resource_bundles = { 'becklink_flutter_privacy' => ['becklink_flutter/Sources/becklink_flutter/PrivacyInfo.xcprivacy'] }
end
