import 'package:flutter/material.dart';

import '../../theme/nothing_theme.dart';
import '../widgets/nothing_widgets.dart';

Future<void> showHelpSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const HelpSheet(),
    );

const _topics = [
  (
    Icons.wifi_tethering,
    'Add your devices',
    'Open Connect and tap Scan network. Everything on your Wi-Fi that answers shows up: tap Add, or Add all. '
        'This phone has to be on the same Wi-Fi as the devices. If one is missing, tap Add by IP address and type the '
        'address your router lists for it. Hubs such as Home Assistant, Hue or an MQTT broker are added under Connect '
        'with their address.',
  ),
  (
    Icons.hub_outlined,
    'Matter devices',
    'In Google Home, Apple Home, SmartThings or Alexa, open the device and choose Linked Matter apps (or Turn on '
        'pairing mode) to get a pairing code. Type it under Connect, Matter. The device keeps working in the other app too.',
  ),
  (
    Icons.grid_view_outlined,
    'Draw your home',
    'Open Map and tap Edit. Add a ready-made room, or drag on the dotted grid to draw one, and drag a corner to resize '
        'it. Devices that wait in the tray at the bottom join a room when you drag them onto it. Undo puts back your '
        'last change.',
  ),
  (
    Icons.touch_app_outlined,
    'Switch and adjust',
    'Tap a device to switch it, hold it for all its controls. Drag sideways across a light to dim it. Locks open only '
        'while you hold the button. All off on the home screen switches everything off at once.',
  ),
  (
    Icons.auto_awesome_outlined,
    'Scenes',
    'Set your devices the way you like, then tap New scene on the home screen to save it. Tap a scene to bring it '
        'back. Hold it to rename it, change its devices or give it a time and days to run by itself.',
  ),
  (
    Icons.home_work_outlined,
    'More than one home',
    "Tap the home's name at the top of the home screen, or your profile button, to switch homes or add one. Each home "
        'has its own map, devices, connections and scenes.',
  ),
  (
    Icons.public,
    'Control from anywhere',
    'Sign in from the profile button. On a phone, tablet or computer that stays at home and plugged in, open your '
        'account and turn on Keep online from this device. Your other devices signed in to the same account can then '
        'switch things from anywhere.',
  ),
  (
    Icons.wifi_off,
    'A device does not answer',
    'Check that it has power and is on the same Wi-Fi as this phone, then tap Refresh all devices in Settings. If its '
        'address changed, remove it and scan again, or give it a fixed address in your router.',
  ),
];

/// Short answers to the first questions people have.
class HelpSheet extends StatelessWidget {
  const HelpSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          const DotText('HELP', size: 30),
          const SizedBox(height: 6),
          Text('Tap a question to open it.', style: NType.body(14, color: p.textDim)),
          const SizedBox(height: 16),
          for (final (icon, title, body) in _topics) ...[
            NCard(
              padding: EdgeInsets.zero,
              child: ExpansionTile(
                key: Key('help-$title'),
                shape: const Border(),
                collapsedShape: const Border(),
                leading: Icon(icon),
                title: Text(title),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                expandedAlignment: Alignment.centerLeft,
                children: [Text(body, style: NType.body(14, color: p.textDim, height: 1.45))],
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}
