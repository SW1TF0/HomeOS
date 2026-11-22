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

  /// Windows reports a refused connection as WSAECONNREFUSED (10061) or, through Dart's socket, as
  /// ERROR_CONNECTION_REFUSED (1225, "The remote computer refused the network connection"). Missing 1225 made
  /// every refusing device look absent on Windows.
  @override
  bool connectionRefused(int? code) => code == 10061 || code == 1225;

  /// Windows answers a refused connection with two more tries before it reports it, about two seconds later
  /// (macOS and Linux report it at once). Waiting less made the network scan miss devices and show them offline.
  @override
  Duration connectWait(Duration usual) {
    const refusal = Duration(milliseconds: 2500);
    return usual < refusal ? refusal : usual;
  }
}
