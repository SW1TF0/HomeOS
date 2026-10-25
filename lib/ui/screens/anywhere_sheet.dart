import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../cloud/cloud_sync.dart';
import '../../integrations/catalog.dart';
import '../../models/device.dart';
import '../../models/home.dart';
import '../../state/home_store.dart';
import '../../theme/app_theme.dart';
import '../widgets/kj_widgets.dart';
import 'account_sheet.dart';
import 'connect_screen.dart';

Future<void> showAnywhereSheet(BuildContext context) => showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: const BoxConstraints(maxWidth: 640),
      builder: (_) => const AnywhereSheet(),
    );

/// Which devices answer away from home, and the two ways to make more of them do: their maker's cloud, or a device
/// left at home (as Apple Home needs an Apple TV or HomePod).
class AnywhereSheet extends StatelessWidget {
  const AnywhereSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<HomeStore>();
    final cloud = context.watch<CloudSync>();
    final p = context.palette;
    final networked = store.devices.where(store.networked).toList();
    final anywhere = networked.where(store.worksAnywhere).toList();
    final atHome = networked.where((d) => !store.worksAnywhere(d)).toList();
    final hubOn = cloud.online || cloud.isHub;

    List<IntegrationConfig> of(String type) => store.integrations.where((i) => i.type == type).toList();
    ({String text, bool ok}) state(String type, {String? key, String? missing}) {
      final list = of(type);
      if (list.isEmpty) return (text: 'Not added', ok: false);
      if (key != null && list.every((c) => c.setting(key).isEmpty)) return (text: missing!, ok: false);
      return (text: 'Works from anywhere', ok: true);
    }

    final clouds = [
      (
        'homeassistant',
        'Home Assistant',
        'Everything in it, with its outside address: Home Assistant Cloud or your own',
        state('homeassistant', key: 'remote_url', missing: 'Add its outside address'),
      ),
      ('shelly', 'Shelly', 'With the Shelly Cloud key from the Shelly app', state('shelly', key: 'cloud_key', missing: 'Add the Shelly Cloud key')),
      ('tuya', 'Tuya & Smart Life', 'Plugs, bulbs, strips, curtains, sensors and robots', state('tuya')),
      ('imou', 'Imou cloud', 'Imou cameras: pictures and live video', state('imou')),
    ];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          const DisplayText('Control from anywhere', size: 28),
          const SizedBox(height: 6),
          Text(
            networked.isEmpty
                ? 'Add your devices first; then this shows which of them answer away from home.'
                : hubOn
                    ? 'Everything answers away from home: ${anywhere.length} through their own cloud, the rest through '
                        '${cloud.isHub ? 'this device' : cloud.hubName ?? 'the device at home'}.'
                    : '${anywhere.length} of ${networked.length} devices answer away from home now.',
            key: const Key('anywhere-summary'),
            style: NType.body(14, color: p.textDim),
          ),
          const SectionLabel('Nothing needed at home'),
          for (final (type, name, what, st) in clouds) ...[
            NCard(
              key: Key('anywhere-$type'),
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
              onTap: () {
                final spec = specFor(type)!;
                final list = of(type);
                openIntegrationSheet(context, spec: spec, config: list.isEmpty ? null : list.first);
              },
              child: Row(children: [
                Icon(specFor(type)!.icon, size: 26),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(name, style: NType.body(15.5, color: p.text, weight: 600)),
                    Text(what, style: NType.body(12.5, color: p.textDim)),
                    const SizedBox(height: 2),
                    Text(st.text, style: NType.body(12.5, color: st.ok ? KJPalette.accent : p.textDim, weight: 600)),
                  ]),
                ),
                Icon(st.ok ? Icons.check_circle : Icons.chevron_right, color: st.ok ? KJPalette.accent : p.textDim),
              ]),
            ),
            const SizedBox(height: 8),
          ],
          const SectionLabel('Through a device left at home'),
          NCard(
            key: const Key('anywhere-hub'),
            onTap: cloud.available ? () => showAccountSheet(context) : null,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'Everything else, like Hue, Matter, TVs, Roomba, MikroTik, WLED, ESPHome, Tasmota and cameras on Wi-Fi, '
                'only listens on your home Wi-Fi. Apple Home works the same way: away from home it needs an Apple TV '
                'or HomePod left at home. Here any old phone, tablet or computer can do it: sign in, then turn on Keep '
                'online from this device on the one that stays at home.',
                style: NType.body(13.5, color: p.text),
              ),
              const SizedBox(height: 8),
              Text(
                !cloud.available
                    ? 'Accounts are not part of this version of the app.'
                    : hubOn
                        ? '${cloud.isHub ? 'This device' : cloud.hubName ?? 'A device at home'} is keeping ${store.homeName} online.'
                        : atHome.isEmpty
                            ? 'None of your devices needs it now.'
                            : 'Not set up yet. ${_names(atHome)} ${atHome.length == 1 ? 'needs' : 'need'} it.',
                key: const Key('anywhere-hub-state'),
                style: NType.body(12.5, color: hubOn ? KJPalette.accent : p.textDim, weight: 600),
              ),
            ]),
          ),
          const SizedBox(height: 14),
          Text(
            'iRobot, Philips Hue, TP-Link Tapo and Kasa, Google and Apple keep their clouds closed to other apps, so '
            'their devices need the device at home, or Home Assistant with its outside address.',
            style: NType.body(12.5, color: p.textDim),
          ),
        ],
      ),
    );
  }

  static String _names(List<Device> devices) {
    final names = [for (final d in devices.take(3)) d.name];
    final more = devices.length - names.length;
    if (more > 0) return '${names.join(', ')} and $more more';
    if (names.length == 1) return names.single;
    return '${names.sublist(0, names.length - 1).join(', ')} and ${names.last}';
  }
}
