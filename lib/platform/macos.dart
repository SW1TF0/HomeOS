import 'dart:io';

import 'platform.dart';

/// Macs. Only macOS fixes go here: they cannot change Windows or Linux.
class MacosProfile extends PlatformProfile {
  const MacosProfile();

  @override
  AppOS get os => AppOS.macos;
  @override
  String get label => 'macOS';
  @override
  bool get isDesktop => true;
  @override
  bool get clickOnTap => true;
  @override
  String? get downloadAsset => 'SmartMenuKJ-macos.zip';

  @override
  Future<String?> readArpTable() async {
    final r = await Process.run('arp', ['-an']).timeout(const Duration(seconds: 3));
    return '${r.stdout}';
  }

  @override
  Future<String> deviceName() async => Platform.localHostname;
}
