/// Shown in Settings and the profile menu. Keep in step with the version in pubspec.yaml.
const appVersion = '1.22.0';

/// Where the app's releases are published (GitHub Releases); the update check and download links use it.
const appReleasesUrl = 'https://github.com/SW1TF0/HomeOS';

/// Where this build is installed from: 'github' (the default), or 'play', 'appstore', 'msstore' for store builds:
///   flutter build appbundle --dart-define=STORE=play
/// A store keeps its apps up to date itself and does not allow them to update another way, so store builds
/// never check GitHub for updates or link to downloads.
const appStore = String.fromEnvironment('STORE', defaultValue: 'github');

/// The privacy policy, linked from Settings and from each store listing.
const appPrivacyUrl = 'https://github.com/SW1TF0/HomeOS/blob/main/docs/privacy.md';

/// Installed from an app store, which handles updates.
const fromAppStore = appStore != 'github';
