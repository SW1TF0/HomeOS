import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app_info.dart';
import '../../cloud/cloud_sync.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import 'account_sheet.dart';
import 'help_sheet.dart';
import 'homes_sheet.dart';
import 'settings_screen.dart';

/// The round button in the top right of each tab: the account's first letter, or a person when signed out.
class ProfileButton extends StatelessWidget {
  const ProfileButton({super.key});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: 'Profile and settings',
        child: InkResponse(
          key: const Key('profile-button'),
          onTap: () => showProfileMenu(context),
          radius: 26,
          child: const Padding(padding: EdgeInsets.all(4), child: ProfileAvatar()),
        ),
      );
}

class ProfileAvatar extends StatelessWidget {
  const ProfileAvatar({super.key, this.size = 38});
  final double size;

  @override
  Widget build(BuildContext context) {
    final cloud = context.watch<CloudSync>();
    final p = context.palette;
    final email = cloud.signedIn ? cloud.account!.email.trim() : '';
    final letter = email.isEmpty ? null : email.characters.first.toUpperCase();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: letter == null ? Colors.transparent : p.text,
            border: Border.all(color: letter == null ? p.border : p.text, width: 1.2),
          ),
          child: letter == null
              ? Icon(Icons.person_outline, size: size * 0.55, color: p.text)
              : Text(letter, style: NType.display(size * 0.56, color: p.background)),
        ),
        // Something to look at: the account could not sync.
        if (cloud.signedIn && cloud.problem != null)
          Positioned(
            right: 0,
            top: 0,
            child: Container(
              width: size * 0.26,
              height: size * 0.26,
              decoration: BoxDecoration(
                  color: KJPalette.danger, shape: BoxShape.circle, border: Border.all(color: p.background, width: 1.5)),
            ),
          ),
      ]),
    );
  }
}

/// Opens the profile menu from the top right corner.
Future<void> showProfileMenu(BuildContext context) => showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close menu',
      barrierColor: Colors.black54,
      transitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (_, _, _) => ProfileMenu(host: context),
      transitionBuilder: (_, animation, _, child) {
        final a = CurvedAnimation(parent: animation, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.9, end: 1.0).animate(a), alignment: Alignment.topRight, child: child),
        );
      },
    );

/// The account, quick switching between homes, settings and help, in one card.
class ProfileMenu extends StatelessWidget {
  const ProfileMenu({super.key, required this.host});

  /// Where the menu was opened from; sheets and pages it leads to open there once it closes.
  final BuildContext host;

  @override
  Widget build(BuildContext context) {
    final cloud = context.watch<CloudSync>();
    final store = context.watch<HomeStore>();
    final p = context.palette;
    final width = math.min(MediaQuery.sizeOf(context).width - 24, 360.0);

    void then(void Function(BuildContext host) action) {
      Navigator.pop(context);
      if (host.mounted) action(host);
    }

    final warn = cloud.signedIn && cloud.problem != null;
    final String title;
    final String subtitle;
    if (cloud.signedIn) {
      title = cloud.account!.email;
      subtitle = cloud.busy
          ? 'Syncing your homes...'
          : cloud.problem ??
              (cloud.isHub
                  ? 'This device keeps ${store.homeName} online'
                  : cloud.online
                      ? 'Control from anywhere is on'
                      : 'Your homes are saved to your account');
    } else {
      title = 'Not signed in';
      subtitle = cloud.available
          ? 'Sign in to keep your homes on every device and control them from anywhere.'
          : 'Everything stays on this device.';
    }

    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Material(
            key: const Key('profile-menu'),
            color: p.surface,
            clipBehavior: Clip.antiAlias,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28), side: BorderSide(color: p.border)),
            child: SizedBox(
              width: width,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 8, 0),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const ProfileAvatar(size: 50),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: NType.body(16, color: p.text, weight: 600)),
                            const SizedBox(height: 2),
                            Text(subtitle, style: NType.body(13, color: warn ? KJPalette.danger : p.textDim)),
                          ]),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Close',
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.close, color: p.textDim),
                      ),
                    ]),
                  ),
                  if (cloud.available)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                      child: cloud.signedIn
                          ? OutlinedButton(
                              key: const Key('profile-account'),
                              onPressed: () => then(showAccountSheet),
                              child: const Text('Manage account'),
                            )
                          : FilledButton(
                              key: const Key('profile-sign-in'),
                              onPressed: () => then(showAccountSheet),
                              child: const Text('Sign in or create account'),
                            ),
                    ),
                  Divider(height: 24, color: p.border),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                    child: Text('Homes', style: NType.label(color: p.textDim)),
                  ),
                  for (final h in store.homes)
                    ListTile(
                      key: ValueKey('profile-home-${h.id}'),
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                      leading: h.id == store.homeId
                          ? const Icon(Icons.radio_button_checked, color: KJPalette.accent)
                          : Icon(Icons.radio_button_unchecked, color: p.textDim),
                      title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      trailing: h.cloudId != null && cloud.signedIn
                          ? Icon(Icons.cloud_done_outlined, size: 18, color: p.textDim)
                          : null,
                      onTap: () async {
                        Navigator.pop(context);
                        if (h.id == store.homeId) return;
                        await store.openHome(h.id);
                        store.toast('${h.name} is open.');
                      },
                    ),
                  ListTile(
                    key: const Key('profile-homes'),
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: const Icon(Icons.add_home_outlined),
                    title: const Text('Add or manage homes'),
                    onTap: () => then(showHomesSheet),
                  ),
                  Divider(height: 24, color: p.border),
                  ListTile(
                    key: const Key('profile-settings'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('Settings'),
                    subtitle: const Text('Theme, clock, devices, backups'),
                    onTap: () => then(openSettings),
                  ),
                  ListTile(
                    key: const Key('profile-help'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                    leading: const Icon(Icons.help_outline),
                    title: const Text('Help'),
                    subtitle: const Text('How to add devices, draw rooms and more'),
                    onTap: () => then(showHelpSheet),
                  ),
                  Divider(height: 16, color: p.border),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 4, 12, 10),
                    child: Row(children: [
                      Expanded(child: Text('SMARTHOMEKJ $appVersion · FREE', style: NType.label(color: p.textDim))),
                      if (cloud.signedIn)
                        TextButton.icon(
                          key: const Key('profile-sign-out'),
                          onPressed: () {
                            Navigator.pop(context);
                            cloud.signOut();
                            store.toast('Signed out. Your homes stay on this device.');
                          },
                          icon: const Icon(Icons.logout, size: 18),
                          label: const Text('Sign out'),
                        ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
