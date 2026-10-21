import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../widgets/kj_widgets.dart';

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
    'Open Connect and tap Scan network. Everything on your Wi-Fi that answers shows up and can be added: tap Add, or '
        'Add all. Devices the app has no controls for still show whether they are online, and open their own web page '
        'when they have one. This phone has to be on the same Wi-Fi as the devices. If one is missing, tap Add by IP '
        'address and type the '
        'address your router lists for it. Hubs such as Home Assistant, Hue or an MQTT broker are added under Connect '
        'with their address.',
  ),
  (
    Icons.cleaning_services_outlined,
    'iRobot Roomba',
    'Scan the network and add the Roomba. Then put it on its dock, hold its HOME button for about 2 seconds until it '
        'plays a tone (on j and s series robots, until the light ring turns blue), open it in the app and tap Get '
        'password within a minute. After that it cleans, pauses, goes home and beeps from the app, on your Wi-Fi.',
  ),
  (
    Icons.router_outlined,
    'MikroTik router',
    'Scan the network and add the router, or add it by its address (often 192.168.88.1). Open it, tap Router settings '
        'and log in with the user and password you use in WinBox. You see who is connected and can switch Wi-Fi and '
        'ports, change the Wi-Fi name and password, keep a device on the same address, rename and restart the router. '
        'Every other setting opens the router\'s own settings page.',
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
    'Open Map and tap Edit. Add a ready-made room, or drag on the dotted grid to draw one. To change a room\'s size, '
        'tap it, then drag a blue dot on a corner or a bar on a wall, pinch it with two fingers, or tap + and - next to '
        'Width and Height. Devices that wait in the tray at the bottom join a room when you drag them onto it. Undo puts '
        'back your last change.',
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
    'Tap New scene on the home screen, pick a name, then choose what it does: turn devices off, turn them on, or keep '
        'them how they are now. Tap a scene to run it. Hold it to change it: flip a device\'s switch to have it off or '
        'on, or tap the device to set its brightness, colour or temperature. Give it a time and days to run by itself.',
  ),
  (
    Icons.bolt_outlined,
    'Automations',
    'Tap Automations next to Scenes on the home screen, then New automation. Pick what sets it off, like a sensor '
        'detecting motion, a door opening or a room getting warm, and what it does: run a scene, or switch a device, '
        'maybe off again a few minutes later. It can be kept to some hours, like the night. Automations run while the '
        'app is open, and all the time on a device that keeps the home online.',
  ),
  (
    Icons.widgets_outlined,
    'Widget and All off tile',
    'On Android, open Settings, Shortcuts. The widget puts your first four scenes and All off on the home screen. The '
        'tile puts All off in Quick Settings, the menu you pull down from the top.',
  ),
  (
    Icons.settings_backup_restore,
    'Keep your home when you reinstall',
    'On Android the app keeps a backup file of every home in Downloads/SmartHomeKJ, and the file stays when the app '
        'is uninstalled. After installing again, tap Restore on the home screen, or Settings, Restore from a file, and '
        'pick it.',
  ),
  (
    Icons.videocam_outlined,
    'Watch a camera',
    'Open Connect and tap Add a camera. Pick the camera it finds, or type its address, choose its brand and type the '
        'camera\'s own user and password (on Tapo, make a Camera account in the Tapo app under the camera\'s Advanced '
        'settings). The video plays live in the Android app while you are on your home Wi-Fi. On Dahua, Imou, '
        'Amcrest, Hikvision and Ezviz cameras, Recordings under the video plays what the camera saved on its memory '
        'card: tap a clip or a time on the line.',
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
          const DisplayText('Help', size: 30),
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
