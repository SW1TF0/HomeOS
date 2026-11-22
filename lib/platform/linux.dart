import 'dart:io';

import 'platform.dart';

/// Linux PCs. Only Linux fixes go here.
class LinuxProfile extends PlatformProfile {
  const LinuxProfile();

  @override
  AppOS get os => AppOS.linux;
  @override
  String get label => 'Linux';
  @override
  bool get isDesktop => true;
  @override
  String? get downloadAsset => 'SmartMenuKJ-linux.tar.gz';

  @override
  Future<String?> readArpTable() async {
    try {
      return await File('/proc/net/arp').readAsString();
    } on FileSystemException {
      final r = await Process.run('ip', ['neigh', 'show']).timeout(const Duration(seconds: 2));
      return '${r.stdout}';
    }
  }

  @override
  Future<String> deviceName() async => Platform.localHostname;
}
