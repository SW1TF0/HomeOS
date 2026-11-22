// Everything that is different on Android, iOS, macOS, Windows, Linux and the web lives in this folder, one file per
// system. The rest of the app asks AppPlatform.current and never checks Platform.isWindows / isMacOS itself.
//
// So a fix for one system goes in that system's file (macos.dart, windows.dart...) and cannot change how the others
// behave. A rule in test/architecture_test.dart keeps Platform.is... checks out of the rest of lib/.
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'android.dart';
import 'ios.dart';
import 'linux.dart';
import 'macos.dart';
import 'web.dart';
import 'windows.dart';

enum AppOS { android, ios, macos, windows, linux, web }

/// How the app behaves on one system. Each system's file overrides only what is different there; everything else
/// is this class's default.
abstract class PlatformProfile {
  const PlatformProfile();

  AppOS get os;

  /// "Windows", "macOS"... for Diagnostics.
  String get label;

  /// A computer with a mouse and a window, not a phone or tablet.
  bool get isDesktop => false;

  // ---- What the system can do ---------------------------------------------------------------------------------

  /// Keeps running with the screen off, with a notification, while it keeps a home online (Android's foreground
  /// service, see HubService.kt).
  bool get keepsRunningInBackground => false;

  /// The home-screen widget and the All off Quick Settings tile.
  bool get homeScreenWidget => false;

  /// Scenes on a schedule run by the system with the app closed.
  bool get timedSceneAlarms => false;

  /// Backups to a folder the user picks, kept up to date.
  bool get backupFolder => false;

  /// RTSP camera video plays inside the app. Elsewhere cameras show pictures or MJPEG.
  bool get playsRtsp => false;

  /// The app's own sounds (UiSounds.kt) for taps, switching and scenes.
  bool get appSounds => false;

  /// The system's click on a tap, where the system has one.
  bool get clickOnTap => false;

  /// The file in the GitHub release that installs on this system, or null when there is none.
  String? get downloadAsset => null;

  // ---- Reading the network ----------------------------------------------------------------------------------

  /// The ARP table as text (IP and MAC address pairs), for naming devices on the Wi-Fi. Null when it cannot be read.
  Future<String?> readArpTable() async => null;

  // ---- How it looks -----------------------------------------------------------------------------------------

  /// A last change to the theme for this system only. A look fix for one system goes here.
  ThemeData adjustTheme(ThemeData theme) => theme;

  /// Wraps the whole app, for changes that need to sit above every screen (text scaling, mouse cursors...).
  Widget wrapApp(Widget app) => app;

  /// The system's version, for Diagnostics.
  String get osVersion => kIsWeb ? '-' : Platform.operatingSystemVersion;

  /// The Dart version the app was built with, for Diagnostics.
  String get dartVersion => kIsWeb ? '-' : Platform.version.split(' ').first;

  /// This system's name for the device, shown when it keeps a home online.
  Future<String> deviceName() async => 'Home device';

  /// Starts or stops running in the background while this device keeps a home online.
  Future<void> keepRunning(bool on) async {}

  /// Whether a failed connection's error code means the device turned it down (so it is there) rather than not
  /// answering. Each system has its own codes: Linux and Android 111, macOS and iOS 61, Windows 10061 or 1225.
  bool connectionRefused(int? code) => const {111, 61, 10061, 1225}.contains(code);

  /// How long to wait on a connection to tell a device that turns it down from one that is not there. Windows
  /// tries again for about two seconds before it reports "refused"; the others say so at once.
  Duration connectWait(Duration usual) => usual;
}

/// The system the app runs on, and the one it looks like.
class AppPlatform {
  AppPlatform._();

  /// The profile of the system the app really runs on: what it can do.
  static PlatformProfile get current => _override ?? _real;

  static final PlatformProfile _real = _detect();
  static PlatformProfile? _override;

  static PlatformProfile _detect() {
    if (kIsWeb) return const WebProfile();
    if (Platform.isAndroid) return const AndroidProfile();
    if (Platform.isIOS) return const IosProfile();
    if (Platform.isMacOS) return const MacosProfile();
    if (Platform.isWindows) return const WindowsProfile();
    return const LinuxProfile();
  }

  static PlatformProfile of(AppOS os) => switch (os) {
        AppOS.android => const AndroidProfile(),
        AppOS.ios => const IosProfile(),
        AppOS.macos => const MacosProfile(),
        AppOS.windows => const WindowsProfile(),
        AppOS.linux => const LinuxProfile(),
        AppOS.web => const WebProfile(),
      };

  /// The system the app is pretending to be, to see on a Mac how Windows (or any other) looks and behaves:
  /// `./run.sh --as windows`, or Diagnostics > Pretend to be. Null when it is itself.
  static AppOS? get pretending => _pretend.value;
  static final ValueNotifier<AppOS?> _pretend = ValueNotifier(_fromDefine());

  /// Changes when the app starts or stops pretending, so the app can draw itself again.
  static ValueListenable<AppOS?> get pretendChanges => _pretend;

  static AppOS? _fromDefine() {
    const name = String.fromEnvironment('PRETEND_PLATFORM');
    return AppOS.values.where((o) => o.name == name).firstOrNull;
  }

  /// Pretends to be [os] (null to stop). Only the look and the profile change: the real system's own abilities
  /// (Android's background service, the RTSP player...) cannot be borrowed.
  static void pretend(AppOS? os) {
    _override = os == null ? null : of(os);
    debugDefaultTargetPlatformOverride = os == null ? null : targetFor(os);
    _pretend.value = os;
  }

  /// The profile used for how the app looks: the pretended system's, or the real one.
  static PlatformProfile get looks => _pretend.value == null ? _real : of(_pretend.value!);

  static TargetPlatform? targetFor(AppOS os) => switch (os) {
        AppOS.android => TargetPlatform.android,
        AppOS.ios => TargetPlatform.iOS,
        AppOS.macos => TargetPlatform.macOS,
        AppOS.windows => TargetPlatform.windows,
        AppOS.linux => TargetPlatform.linux,
        AppOS.web => null,
      };

  /// Tests set a profile directly; null goes back to the real one.
  @visibleForTesting
  static set debugProfile(PlatformProfile? p) => _override = p;

  /// Applies a pretend platform given at start (`--dart-define=PRETEND_PLATFORM=windows`).
  static void applyStartupPretend() {
    final os = _pretend.value;
    if (os != null) pretend(os);
  }
}
