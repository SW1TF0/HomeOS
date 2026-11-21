import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/models/automation.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

void main() {
  group('triggers', () {
    const off = DeviceState(on: false);
    const on = DeviceState(on: true);

    test('fire once, on the change itself', () {
      const turnsOn = AutomationTrigger(deviceId: 'd', kind: TriggerKind.turnsOn);
      expect(turnsOn.fired(off, on), isTrue);
      expect(turnsOn.fired(on, on), isFalse, reason: 'staying on is not turning on');
      expect(turnsOn.fired(on, off), isFalse);
      expect(turnsOn.fired(off.merge(DeviceState.unreachable), on), isFalse,
          reason: 'a device that comes back on the network did not just turn on');

      const motion = AutomationTrigger(deviceId: 'd', kind: TriggerKind.becomes, label: 'Motion', value: 'Detected');
      const clear = DeviceState(readings: {'Motion': 'Clear'});
      const seen = DeviceState(readings: {'Motion': 'detected'});
      expect((motion.fired(clear, seen), motion.fired(seen, seen), motion.fired(seen, clear)), (true, false, false));

      const hot = AutomationTrigger(deviceId: 'd', kind: TriggerKind.above, label: 'Temperature', number: 25);
      DeviceState temp(String t) => DeviceState(readings: {'Temperature': t});
      expect(hot.fired(temp('24.5 °C'), temp('25,5 °C')), isTrue);
      expect(hot.fired(temp('26 °C'), temp('27 °C')), isFalse, reason: 'already above');
      expect(hot.fired(const DeviceState(currentTemp: 25), const DeviceState(currentTemp: 25.2)), isTrue);
      const flat = AutomationTrigger(deviceId: 'd', kind: TriggerKind.below, label: 'Battery', number: 20);
      expect(flat.fired(const DeviceState(battery: 0.21), const DeviceState(battery: 0.19)), isTrue);

      const gone = AutomationTrigger(deviceId: 'd', kind: TriggerKind.offline);
      expect(gone.fired(on, on.merge(DeviceState.unreachable)), isTrue);
      const opens = AutomationTrigger(deviceId: 'd', kind: TriggerKind.opens);
      expect(opens.fired(const DeviceState(position: 0), const DeviceState(position: 0.4)), isTrue);
      const alarm = AutomationTrigger(deviceId: 'd', kind: TriggerKind.activity, value: Activity.triggered);
      expect(alarm.fired(const DeviceState(activity: Activity.armedAway), const DeviceState(activity: Activity.triggered)),
          isTrue);
    });

    test('a device offers what it can do, with both ways of a two-way reading', () {
      final sensor = Device(
        id: 's',
        name: 'Hall sensor',
        kind: DeviceKind.sensor,
        integrationId: 'demo',
        externalId: 's',
        capabilities: {Capability.readings},
        state: const DeviceState(
            readings: {'Motion': 'Clear', 'Temperature': '21.5 °C', 'Address': '10.0.0.4'}, battery: 0.8),
      );
      final events = AutomationTrigger.choicesFor(sensor).map((t) => t.event).toList();
      expect(events, [
        'Motion becomes Clear',
        'Motion becomes Detected',
        'Temperature rises above …',
        'Temperature drops below …',
        'Battery drops below …',
        'stops answering',
        'answers again',
      ]);
      expect(AutomationTrigger.choicesFor(sensor)[2].needsNumber, isTrue);
      expect([for (final t in AutomationTrigger.choicesFor(sensor).take(2)) t.eventFor('Hall sensor')],
          ['stops detecting motion', 'detects motion']);
      const door = AutomationTrigger(deviceId: 'd', kind: TriggerKind.becomes, label: 'Door', value: 'Open');
      expect((door.eventFor('Back door'), door.eventFor('Hall sensor')), ('opens', 'Door opens'));
      expect(AutomationTrigger.choicesFor(sensor)[2].copyWith(number: 25).event, 'Temperature rises above 25°');
    });

    test('only between some hours, also past midnight', () {
      final night = Automation(
          id: 'a',
          trigger: const AutomationTrigger(deviceId: 'd', kind: TriggerKind.turnsOn),
          then: const AutomationStep.scene('s'),
          from: 22 * 60,
          to: 6 * 60);
      expect([for (final h in [21, 22, 23, 0, 5, 6, 12]) night.allowedAt(DateTime(2026, 10, 17, h))],
          [false, true, true, true, true, false, false]);
      night.to = night.from;
      expect(night.allowedAt(DateTime(2026, 10, 17, 12)), isTrue, reason: 'the same time twice means any time');
    });

    test('are saved with the home and read back', () {
      final a = Automation(
        id: 'auto-1',
        trigger: const AutomationTrigger(deviceId: 'd', kind: TriggerKind.above, label: 'Humidity', number: 70),
        then: const AutomationStep.device('fan', on: true, offAfter: 15),
        enabled: false,
        from: 60,
        to: 120,
      );
      final back = HomeData.fromJson(jsonDecode(jsonEncode(HomeData(automations: [a]).toJson())) as Map<String, dynamic>)
          .automations
          .single;
      expect(jsonEncode(back.toJson()), jsonEncode(a.toJson()));
      expect(HomeData().toJson().containsKey('automations'), isFalse, reason: 'old versions keep reading the file');
      expect(HomeData.fromJson({'automations': [{'id': 'x', 'trigger': {'kind': 'nope'}}]}).automations, isEmpty);
    });
  });

  group('in the home', () {
    late HomeStore store;

    Future<void> setUpStore() async {
      store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 500)));
      await store.load();
    }

    Device named(String n) => store.devices.firstWhere((d) => d.name == n);

    /// A reading changes, the way a sensor reports it.
    void report(Device d, DeviceState s) {
      d.state = d.state.merge(s);
      store.notifyListeners();
      store.automationChanged(store.automations.first);
    }

    testWidgets('motion turns a light on, and off again a while later', (tester) async {
      await setUpStore();
      final hall = store.addVirtualDevice('demo', 'Hall motion', DeviceKind.sensor);
      hall.state = const DeviceState(readings: {'Motion': 'Clear'});
      final lamp = named('Bedside lamp');
      expect(lamp.state.on, isFalse);
      store.addAutomation(Automation(
        id: 'auto-1',
        trigger: AutomationTrigger(deviceId: hall.id, kind: TriggerKind.becomes, label: 'Motion', value: 'Detected'),
        then: AutomationStep.device(lamp.id, on: true, offAfter: 5),
      ));
      await tester.pump();
      expect(lamp.state.on, isFalse, reason: 'nothing happened yet');

      report(hall, const DeviceState(readings: {'Motion': 'Detected'}));
      await tester.pump();
      expect(lamp.state.on, isTrue);
      expect(store.automationRuns, contains('auto-1'));

      // Movement again a few minutes later starts the wait over.
      await tester.pump(const Duration(minutes: 3));
      report(hall, const DeviceState(readings: {'Motion': 'Clear'}));
      report(hall, const DeviceState(readings: {'Motion': 'Detected'}));
      await tester.pump(const Duration(minutes: 3));
      expect(lamp.state.on, isTrue);
      await tester.pump(const Duration(minutes: 2, seconds: 1));
      expect(lamp.state.on, isFalse);
      store.dispose();
    });

    testWidgets('a light turning on runs a scene; switched off, or out of hours, nothing runs', (tester) async {
      await setUpStore();
      final tv = named('TV');
      final lamp = named('Floor lamp');
      final kitchen = named('Kitchen lights');
      final dim = store.addScene('Dim', [kitchen], turnOn: true);
      final a = Automation(
          id: 'auto-2',
          trigger: AutomationTrigger(deviceId: tv.id, kind: TriggerKind.turnsOn),
          then: AutomationStep.scene(dim.id));
      store.addAutomation(a);
      await tester.pump();

      a.enabled = false;
      store.automationChanged(a);
      await store.command(tv, const DeviceCommand(on: true));
      await tester.pump();
      expect(kitchen.state.on, isFalse);

      await store.command(tv, const DeviceCommand(on: false));
      a
        ..enabled = true
        ..from = (DateTime.now().hour + 2) % 24 * 60
        ..to = (DateTime.now().hour + 3) % 24 * 60;
      store.automationChanged(a);
      await store.command(tv, const DeviceCommand(on: true));
      await tester.pump();
      expect(kitchen.state.on, isFalse, reason: 'outside its hours');

      await store.command(tv, const DeviceCommand(on: false));
      a.from = a.to = null;
      store.automationChanged(a);
      await store.command(tv, const DeviceCommand(on: true));
      await tester.pump();
      expect(kitchen.state.on, isTrue);
      expect(lamp.state.on, isTrue, reason: 'only the scene changed');

      // Removing the scene removes what runs it.
      store.removeScene(dim);
      expect(store.automations, isEmpty);
      store.dispose();
    });

    testWidgets('an automation that sets itself off does not run in a loop', (tester) async {
      await setUpStore();
      final lamp = named('Desk lamp');
      await store.command(lamp, const DeviceCommand(on: false));
      store.addAutomation(Automation(
          id: 'auto-3',
          trigger: AutomationTrigger(deviceId: lamp.id, kind: TriggerKind.turnsOff),
          then: AutomationStep.device(lamp.id, on: true)));
      final runs = <DateTime>[];
      store.addListener(() {
        final at = store.automationRuns['auto-3'];
        if (at != null && (runs.isEmpty || runs.last != at)) runs.add(at);
      });
      await store.command(lamp, const DeviceCommand(on: true));
      await store.command(lamp, const DeviceCommand(on: false));
      await tester.pump();
      expect(lamp.state.on, isTrue);
      await store.command(lamp, const DeviceCommand(on: false));
      await tester.pump();
      expect(runs.length, 1, reason: 'it waits a moment before running again');

      // Removing the device removes its automations.
      store.removeDevice(lamp);
      expect(store.automations, isEmpty);
      store.dispose();
    });

    testWidgets('a background run for a timed scene runs no automations', (tester) async {
      store = HomeStore(
          repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('', 500)), automate: false);
      await store.load();
      final tv = named('TV');
      final kitchen = named('Kitchen lights');
      store.addAutomation(Automation(
          id: 'auto-4',
          trigger: AutomationTrigger(deviceId: tv.id, kind: TriggerKind.turnsOn),
          then: AutomationStep.device(kitchen.id, on: true)));
      await store.command(tv, const DeviceCommand(on: true));
      await tester.pump();
      expect(kitchen.state.on, isFalse);
      store.dispose();
    });
  });
}
