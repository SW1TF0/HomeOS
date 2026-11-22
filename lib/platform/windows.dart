import 'dart:io';

import 'platform.dart';

/// Windows PCs. Only Windows fixes go here: they cannot change macOS or Linux.
class WindowsProfile extends PlatformProfile {
  const WindowsProfile();

  @override
  AppOS get os => AppOS.windows;
  @override
  String get label => 'Windows';
  @override
  bool get isDesktop => true;
  @override
  bool get clickOnTap => true;
  @override
  String? get downloadAsset => 'SmartMenuKJ-windows.zip';

  @override
  Future<String?> readArpTable() async {
    final r = await Process.run('arp', ['-a']).timeout(const Duration(seconds: 3));
    return '${r.stdout}';
  }

  @override
  Future<String> deviceName() async => Platform.localHostname;

  /// Windows answers a refused connection with two more tries before it reports it, about two seconds later
  /// (macOS and Linux report it at once). Waiting less made the network scan miss devices and show them offline.
  @override
  Duration connectWait(Duration usual) {
    const refusal = Duration(milliseconds: 2500);
    return usual < refusal ? refusal : usual;
  }
}
