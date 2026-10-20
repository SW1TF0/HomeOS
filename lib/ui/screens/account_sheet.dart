import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../cloud/cloud_sync.dart';
import '../../cloud/firebase.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../widgets/dialogs.dart';
import '../widgets/kj_widgets.dart';

Future<void> showAccountSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const AccountSheet(),
    );

/// The account in Settings: sign in, or what it is doing.
class AccountCard extends StatelessWidget {
  const AccountCard({super.key});

  @override
  Widget build(BuildContext context) {
    final cloud = context.watch<CloudSync>();
    final store = context.watch<HomeStore>();
    final p = context.palette;
    if (!cloud.available) return const SizedBox.shrink();
    final (icon, title, subtitle) = !cloud.signedIn
        ? (Icons.person_outline, 'Sign in', 'Your homes on every phone and computer, and control from anywhere. Free.')
        : (
            cloud.problem == null ? Icons.cloud_done_outlined : Icons.cloud_off_outlined,
            cloud.account!.email,
            cloud.problem ?? remoteSummary(cloud, store.homeName),
          );
    return NCard(
      key: const Key('account-card'),
      onTap: () => showAccountSheet(context),
      child: Row(children: [
        Icon(icon, size: 28),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: NType.body(17, color: p.text, weight: 600)),
            Text(subtitle, style: NType.body(13, color: p.textDim)),
          ]),
        ),
        Icon(Icons.arrow_forward, color: p.textDim),
      ]),
    );
  }
}

/// One line on how the open home is reached from anywhere.
String remoteSummary(CloudSync cloud, String home) {
  if (cloud.isHub && cloud.store.offHomeNetwork) {
    return 'This device is off the home Wi-Fi, so $home cannot be reached through it until it is back.';
  }
  if (cloud.isHub) return 'This device keeps $home online, so you can control it from anywhere.';
  if (cloud.online) return '${cloud.hubName ?? 'A device at home'} keeps $home online. Control it from anywhere.';
  if (cloud.hubSeen != null) return '${cloud.hubName ?? 'The device at home'} is offline, so $home works only on its Wi-Fi.';
  return 'Your homes are saved to your account.';
}

class AccountSheet extends StatefulWidget {
  const AccountSheet({super.key});

  @override
  State<AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<AccountSheet> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _hide = true;
  bool _working = false;
  String? _error;
  String? _note;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _go(Future<void> Function() action) async {
    setState(() {
      _working = true;
      _error = null;
      _note = null;
    });
    try {
      await action();
    } on CloudException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _working = false);
  }

  @override
  Widget build(BuildContext context) {
    final cloud = context.watch<CloudSync>();
    final store = context.watch<HomeStore>();
    final p = context.palette;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: EdgeInsets.fromLTRB(20, 0, 20, 32 + MediaQuery.viewInsetsOf(context).bottom),
        children: cloud.signedIn ? _account(context, cloud, store, p) : _signIn(context, cloud, p),
      ),
    );
  }

  List<Widget> _signIn(BuildContext context, CloudSync cloud, KJPalette p) => [
        const DisplayText('Account', size: 30),
        const SizedBox(height: 6),
        Text(
            'Sign in to keep your homes on every phone and computer, and to switch things on and off from anywhere. '
            'Without an account everything still works on your Wi-Fi.',
            style: NType.body(14, color: p.textDim)),
        const SizedBox(height: 18),
        TextField(
          key: const Key('account-email'),
          controller: _email,
          keyboardType: TextInputType.emailAddress,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.email],
          decoration: const InputDecoration(labelText: 'Email'),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('account-password'),
          controller: _password,
          obscureText: _hide,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.password],
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: 'At least 6 characters',
            suffixIcon: IconButton(
              tooltip: _hide ? 'Show password' : 'Hide password',
              onPressed: () => setState(() => _hide = !_hide),
              icon: Icon(_hide ? Icons.visibility_outlined : Icons.visibility_off_outlined),
            ),
          ),
          onSubmitted: (_) => _go(() => cloud.signIn(_email.text, _password.text)),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, key: const Key('account-error'), style: NType.body(14, color: KJPalette.danger)),
        ],
        if (_note != null) ...[
          const SizedBox(height: 12),
          Text(_note!, style: NType.body(14, color: p.text)),
        ],
        const SizedBox(height: 18),
        Row(children: [
          Expanded(
            child: FilledButton(
              key: const Key('account-sign-in'),
              onPressed: _working ? null : () => _go(() => cloud.signIn(_email.text, _password.text)),
              child: const Text('Sign in'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              key: const Key('account-create'),
              onPressed: _working ? null : () => _go(() => cloud.signIn(_email.text, _password.text, create: true)),
              child: const Text('Create account'),
            ),
          ),
        ]),
        const SizedBox(height: 6),
        Align(
          child: TextButton(
            onPressed: _working
                ? null
                : () => _go(() async {
                      if (!_email.text.contains('@')) throw const CloudException('Type your email first.');
                      await cloud.resetPassword(_email.text);
                      _note = 'Check your email for a link to set a new password.';
                    }),
            child: const Text('Forgot password?'),
          ),
        ),
        if (_working) const LinearProgressIndicator(),
      ];

  List<Widget> _account(BuildContext context, CloudSync cloud, HomeStore store, KJPalette p) {
    final home = store.homeName;
    final linked = store.openHomeEntry.cloudId != null;
    return [
      const DisplayText('Account', size: 30),
      const SizedBox(height: 6),
      Text(cloud.account!.email, style: NType.body(16, color: p.text, weight: 500)),
      const SizedBox(height: 4),
      Text(
        cloud.busy
            ? 'Syncing your homes...'
            : cloud.problem ?? 'Your homes are saved to your account and stay in step on every device you sign in on.',
        key: const Key('account-status'),
        style: NType.body(14, color: cloud.problem == null ? p.textDim : KJPalette.danger),
      ),
      if (cloud.needsRules) ...[
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            key: const Key('account-copy-rules'),
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: CloudSync.databaseRules));
              store.toast('Rules copied. Paste them in Firebase, Realtime Database, Rules, then tap Publish.');
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy database rules'),
          ),
        ),
      ],
      const SectionLabel('Control from anywhere', accent: true),
      Text(
          'Your devices only answer on your home Wi-Fi, so on mobile data your phone cannot reach them by itself. '
          'A second phone, tablet or computer that stays at home passes your commands on: install SmartMenuKJ on it, '
          'sign in with this account, keep it plugged in, and turn this on there. Not on the phone you carry: it '
          'leaves home with you.',
          style: NType.body(14, color: p.textDim)),
      const SizedBox(height: 12),
      NCard(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: [
          SwitchListTile(
            key: const Key('account-hub'),
            value: cloud.isHub,
            onChanged: linked && !cloud.busy
                ? (on) async {
                    if (on &&
                        !await confirm(context,
                            title: 'Does this device stay at home?',
                            body: 'It passes on commands for $home while it is at home, on the Wi-Fi, with the app '
                                'running. If you carry it with you, control from anywhere stops when you leave.',
                            action: 'It stays at home')) {
                      return;
                    }
                    await cloud.setHub(on);
                  }
                : null,
            title: Text('Keep $home online from this device'),
            subtitle: Text(linked ? remoteSummary(cloud, home) : 'Saving $home to your account first...'),
          ),
        ]),
      ),
      if (!cloud.isHub && linked) ...[
        const SizedBox(height: 10),
        Text(
          cloud.online
              ? 'Right now ${cloud.hubName ?? 'a device at home'} passes commands on for $home.'
              : cloud.hubSeen != null
                  ? '${cloud.hubName ?? 'The device at home'} has not checked in for a while. Check that it is on, '
                      'plugged in and on the Wi-Fi, with SmartMenuKJ open.'
                  : 'No device at home is doing this yet, so away from home nothing can be switched.',
          key: const Key('account-hub-status'),
          style: NType.body(13, color: cloud.online ? p.textDim : KJPalette.danger),
        ),
      ],
      const SizedBox(height: 24),
      Row(children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: cloud.busy ? null : cloud.syncAll,
            icon: const Icon(Icons.sync, size: 18),
            label: const Text('Sync now'),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: OutlinedButton.icon(
            key: const Key('account-sign-out'),
            onPressed: cloud.signOut,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      Text('Signing out keeps your homes on this device.', style: NType.body(12.5, color: p.textDim)),
    ];
  }
}
