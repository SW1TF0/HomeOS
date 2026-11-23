import 'platform.dart';

/// iPhone and iPad. Only iOS fixes go here.
class IosProfile extends PlatformProfile {
  const IosProfile();

  @override
  AppOS get os => AppOS.ios;
  @override
  String get label => 'iOS';
  @override
  String? get downloadAsset => 'SmartMenuKJ-ios.ipa';
}
