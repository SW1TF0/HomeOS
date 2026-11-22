import 'platform.dart';

/// The app in a browser. Only web fixes go here.
class WebProfile extends PlatformProfile {
  const WebProfile();

  @override
  AppOS get os => AppOS.web;
  @override
  String get label => 'Web';
}
