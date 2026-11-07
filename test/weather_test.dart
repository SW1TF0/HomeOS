import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smartmenukj/integrations/weather.dart';
import 'package:smartmenukj/models/automation.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/models/scene.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/state/scene_alarms.dart';
import 'package:smartmenukj/state/weather.dart';
import 'package:smartmenukj/util/sun.dart';

import 'weather_fixture.dart';

const sofia = HomePlace(name: 'Sofia', region: 'Sofia-Capital, Bulgaria', lat: 42.6975, lon: 23.3242);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the sun', () {
    void near(DateTime? t, DateTime want) {
      expect(t, isNotNull);
      expect(t!.isUtc, isTrue);
      expect(t.difference(want).inMinutes.abs(), lessThanOrEqualTo(2), reason: '$t, not $want');
    }

    test('rises and sets at the right minute, in summer and winter, east and west', () {
      final london = SunTimes.on(DateTime(2026, 6, 21), 51.5074, -0.1278);
      near(london.rise, DateTime.utc(2026, 6, 21, 3, 43));
      near(london.set, DateTime.utc(2026, 6, 21, 20, 21));
      final ny = SunTimes.on(DateTime(2026, 12, 21), 40.7128, -74.006);
      near(ny.rise, DateTime.utc(2026, 12, 21, 12, 16));
      near(ny.set, DateTime.utc(2026, 12, 21, 21, 31));
      final home = SunTimes.on(DateTime(2026, 11, 7), sofia.lat, sofia.lon);
      expect(home.rise!.isBefore(home.set!), isTrue);
      expect(home.set!.difference(home.rise!).inHours, inInclusiveRange(9, 10), reason: 'a November day');
    });

    test('in the polar summer or night it neither rises nor sets', () {
      final summer = SunTimes.on(DateTime(2026, 6, 21), 78.22, 15.65);
      expect((summer.rise, summer.set), (null, null));
      final winter = SunTimes.on(DateTime(2026, 12, 21), 78.22, 15.65);
      expect((winter.rise, winter.set), (null, null));
    });
  });

  group('scenes at sunrise and sunset', () {
    final sunset = SceneSchedule.sun('sunset', lat: sofia.lat, lon: sofia.lon, offset: -30, days: {6});
    final day = DateTime(2026, 11, 7); // a Saturday
    DateTime minute(DateTime t) => DateTime(t.year, t.month, t.day, t.hour, t.minute);
    final due = minute(SunTimes.on(day, sofia.lat, sofia.lon).set!.toLocal().subtract(const Duration(minutes: 30)));

    test('run at the minute of the sun, on the days picked', () {
      expect(sunset.timeOn(day), due);
      expect(sunset.matches(due), isTrue);
      expect(sunset.matches(due.add(const Duration(minutes: 1))), isFalse);
      expect(sunset.nextAfter(day), due);
      final next = sunset.nextAfter(due)!;
      expect(next.weekday, DateTime.saturday);
      expect(next.difference(due).inDays, 6, reason: 'next Saturday, a little earlier');
      expect(sunset.runNear(due.add(const Duration(minutes: 5))), due);
      expect(sunset.label, '30 min before sunset');
      expect(SceneSchedule.sun('sunrise', lat: 1, lon: 1).label, 'Sunrise');
      expect(SceneSchedule.sun('sunrise', lat: 1, lon: 1, offset: 60).label, '1 h after sunrise');
      expect(SceneSchedule.sun('sunset', lat: 1, lon: 1, offset: 90).label, '90 min after sunset');
    });

    test('keep their place in a backup, and follow the home when it moves', () {
      final back = SceneSchedule.fromJson(jsonDecode(jsonEncode(sunset.toJson())) as Map<String, dynamic>);
      expect((back.sun, back.offset, back.lat, back.lon), ('sunset', -30, sofia.lat, sofia.lon));
      expect(back.days, {6});
      expect(back.timeOn(day), due);
      final moved = back.at(51.5, -0.13);
      expect((moved.sun, moved.offset, moved.lat), ('sunset', -30, 51.5));
      final plain = SceneSchedule(hour: 7, minute: 30);
      expect(identical(plain.at(1, 2), plain), isTrue);
      expect(plain.toJson().containsKey('sun'), isFalse, reason: 'older versions read it as before');
    });

    test('get an Android alarm at their next run', () {
      final s = Scene(id: 'dusk', name: 'Dusk', schedule: sunset);
      expect(SceneAlarms.plan([s], day), {'${SceneAlarms.idOf('dusk')}': due.millisecondsSinceEpoch});
    });
  });

  group('the forecast', () {
    test('is read from what Open-Meteo sends', () {
      final now = DateTime(2026, 11, 7, 19, 40);
      final w = Weather.parse(sampleForecast(now, temp: 8.4, code: 61, isDay: false))!;
      expect((w.temp, w.feelsLike, w.code, w.day, w.humidity, w.wind), (8.4, 6.0, 61, false, 71.0, 9.7));
      expect((w.text, w.raining), ('Rain', true));
      expect(w.hours.length, 7 * 24);
      expect(w.days.length, 7);
      expect(w.days.first.date, DateTime(2026, 11, 7));
      expect(w.days.first.sunset, DateTime(2026, 11, 7, 17, 8));
      final next = w.next(now, count: 5);
      expect(next.first.at, DateTime(2026, 11, 7, 19));
      expect(next.length, 5);
      expect(Weather.parse({'current': {}}), isNull);
      expect(Weather.parse('nope'), isNull);
      final bare = Weather.parse({'current': {'temperature_2m': 3}})!;
      expect((bare.temp, bare.feelsLike, bare.code, bare.hours.length, bare.days.length), (3.0, 3.0, 3, 0, 0));
    });

    test('has words and an icon for every kind of weather', () {
      expect(Weather.describe(0), 'Clear sky');
      expect(Weather.describe(95), 'Thunderstorm');
      expect(Weather.describe(1234), 'Cloudy');
      for (final c in [51, 63, 81, 95, 99]) {
        expect(Weather.isWet(c), isTrue, reason: '$c');
      }
      for (final c in [0, 3, 45, 71, 85]) {
        expect(Weather.isWet(c), isFalse, reason: '$c');
      }
      expect(Weather.iconOf(0, day: true), isNot(Weather.iconOf(0, day: false)));
    });

    test('is asked for at the home, and towns are found by name', () async {
      final asked = <Uri>[];
      final api = OpenMeteo(weatherClient(asked: asked));
      expect(await api.forecast(sofia), isNotNull);
      expect(asked.single.queryParameters['latitude'], '42.6975');
      expect(asked.single.queryParameters['timezone'], 'auto');
      final towns = await api.search(' Sofia ', language: 'bg');
      expect(asked.last.queryParameters, containsPair('name', 'Sofia'));
      expect(asked.last.queryParameters, containsPair('language', 'bg'));
      expect(towns.map((t) => (t.name, t.region)), [('Sofia', 'Sofia-Capital, Bulgaria'), ('Sofia', 'Portugal')]);
      expect(await api.search('S'), isEmpty, reason: 'one letter is too little');
      expect(await OpenMeteo(weatherClient(towns: {'generationtime_ms': 0.2})).search('Zzz'), isEmpty);
      final down = OpenMeteo(MockClient((_) async => http.Response('', 503)));
      expect(() => down.forecast(sofia), throwsA(isA<WeatherException>()));
      expect(() => down.search('Sofia'), throwsA(isA<WeatherException>()));
    });

    test('is asked again only when it is old, the town changed or someone asks', () async {
      final asked = <Uri>[];
      final weather = HomeWeather(weatherClient(asked: asked));
      var now = DateTime(2026, 11, 7, 12);
      await withClock(Clock(() => now), () async {
        await weather.refresh(null);
        expect(asked, isEmpty);
        await weather.refresh(sofia);
        expect(weather.now?.temp, 12);
        await weather.refresh(sofia);
        expect(asked.length, 1, reason: 'still fresh');
        await weather.refresh(sofia, force: true);
        expect(asked.length, 2);
        now = now.add(const Duration(minutes: 31));
        await weather.refresh(sofia);
        expect(asked.length, 3);
        await weather.refresh(const HomePlace(name: 'London', lat: 51.5, lon: -0.13));
        expect(asked.length, 4);
        expect(weather.place?.name, 'London');
        await weather.refresh(null);
        expect((weather.now, weather.place), (null, null));
      });
      weather.dispose();
    });

    test('says why there is none', () async {
      final weather = HomeWeather(MockClient((_) async => http.Response('', 500)));
      await weather.refresh(sofia);
      expect((weather.now, weather.problem), (null, 'The weather service answered 500.'));
      final offline = HomeWeather(MockClient((_) async => throw http.ClientException('no route')));
      await offline.refresh(sofia);
      expect(offline.problem, 'No weather: no internet connection?');
      weather.dispose();
      offline.dispose();
    });
  });

  group('the home', () {
    late HomeStore store;
    late Map<String, Object?> Function() forecast;
    late Map<String, String> claimed;

    setUp(() async {
      forecast = () => sampleForecast(DateTime.now());
      claimed = {};
      store = HomeStore(
        repository: MemoryHomeRepository(),
        client: weatherClient(forecast: () => forecast(), other: (_) => http.Response('', 500)),
        claimRun: (id, slot) async {
          if (claimed[id] == slot) return false;
          claimed[id] = slot;
          return true;
        },
      );
      await store.load();
    });

    tearDown(() => store.dispose());

    Device named(String n) => store.devices.firstWhere((d) => d.name == n);

    /// [n], switched off first.
    Future<Device> off(String n) async {
      final d = named(n);
      await store.command(d, const DeviceCommand(on: false));
      return d;
    }

    test('keeps its town and its timers in the backup', () async {
      final lamp = named('Desk lamp');
      store.setPlace(sofia);
      withClock(Clock.fixed(DateTime(2026, 11, 7, 20, 0, 12, 345)), () => store.setTimer(lamp, const Duration(minutes: 30)));
      final timer = store.timerFor(lamp.id)!;
      expect(timer.at, DateTime(2026, 11, 7, 20, 30, 12), reason: 'to the second');
      expect(timer.on, lamp.state.on != true);
      final back = HomeData.fromJson(jsonDecode(store.exportJson()) as Map<String, dynamic>);
      expect((back.place?.name, back.place?.region, back.place?.lat), ('Sofia', 'Sofia-Capital, Bulgaria', sofia.lat));
      expect(back.timers.single.slot, timer.slot);
      expect(HomeData().toJson().keys, isNot(contains('timers')));
      expect(HomeData().toJson().keys, isNot(contains('place')));
      expect(HomeData.fromJson({'place': {'name': 'x'}, 'timers': [{'deviceId': 3}]}).place, isNull);
      expect(HomeData.fromJson({'timers': [{'deviceId': 3}]}).timers, isEmpty);
    });

    test('a timer turns its device off once, on time, and goes away', () async {
      final lamp = named('Desk lamp');
      await store.command(lamp, const DeviceCommand(on: true));
      final start = DateTime(2026, 11, 7, 20);
      withClock(Clock.fixed(start), () => store.setTimer(lamp, const Duration(minutes: 15)));
      expect(store.timerFor(lamp.id)?.on, isFalse);
      expect(SceneAlarms.plan(const [], start, store.timers),
          {'${SceneAlarms.timerAlarm(lamp.id)}': start.add(const Duration(minutes: 15)).millisecondsSinceEpoch});

      await store.runDueTimers(start.add(const Duration(minutes: 14)));
      expect(lamp.state.on, isTrue);
      await store.runDueTimers(start.add(const Duration(minutes: 15, seconds: 10)));
      expect(lamp.state.on, isFalse);
      expect(store.timers, isEmpty);

      // Set again and cancelled, nothing happens.
      withClock(Clock.fixed(start), () => store.setTimer(lamp, const Duration(minutes: 5), on: true));
      store.cancelTimer(lamp.id);
      await store.runDueTimers(start.add(const Duration(minutes: 6)));
      expect(lamp.state.on, isFalse);
    });

    test('a timer missed by long, or already done by the alarm, is dropped', () async {
      final lamp = await off('Desk lamp');
      final fan = await off('Bath fan');
      final start = DateTime(2026, 11, 7, 20);
      withClock(Clock.fixed(start), () {
        store.setTimer(lamp, const Duration(minutes: 10), on: true);
        store.setTimer(fan, const Duration(minutes: 30), on: true);
      });
      final done = store.timerFor(fan.id)!;
      claimed['timer-${fan.id}'] = done.slot;
      await store.runDueTimers(start.add(const Duration(minutes: 31)));
      expect((lamp.state.on, fan.state.on), (false, false));
      expect(store.timers, isEmpty);

      // A device that goes takes its timer with it.
      withClock(Clock.fixed(start), () => store.setTimer(lamp, const Duration(minutes: 10)));
      store.removeDevice(lamp);
      expect(store.timers, isEmpty);
    });

    test('an alarm runs a device timer even with the app closed', () async {
      final lamp = await off('Desk lamp');
      final start = DateTime(2026, 11, 7, 20);
      withClock(Clock.fixed(start), () => store.setTimer(lamp, const Duration(minutes: 20), on: true));
      final alarm = SceneAlarms.timerAlarm(lamp.id);
      expect(await runDueAlarm(store, alarm, start.add(const Duration(minutes: 5))), isFalse, reason: 'too early');
      expect(await runDueAlarm(store, alarm, start.add(const Duration(minutes: 20, seconds: 3))), isTrue);
      expect(lamp.state.on, isTrue);
      expect(await runDueAlarm(store, alarm, start.add(const Duration(minutes: 20, seconds: 30))), isFalse);
    });

    test('an automation runs at sunset, but only once a town is set', () async {
      final lamp = await off('Floor lamp');
      store.addAutomation(Automation(
        id: 'dusk',
        trigger: const AutomationTrigger(deviceId: AutomationTrigger.home, kind: TriggerKind.sunset, number: 15),
        then: AutomationStep.device(lamp.id, on: true),
      ));
      final day = DateTime(2026, 11, 7);
      final set = SunTimes.on(day, sofia.lat, sofia.lon).set!.toLocal().add(const Duration(minutes: 15));
      final at = DateTime(set.year, set.month, set.day, set.hour, set.minute);
      store.runDueScenes(at);
      await Future<void>.delayed(Duration.zero);
      expect(lamp.state.on, isFalse, reason: 'no town yet');

      store.setPlace(sofia);
      store.runDueScenes(at.subtract(const Duration(minutes: 1)));
      await Future<void>.delayed(Duration.zero);
      expect(lamp.state.on, isFalse);
      store.runDueScenes(at);
      await Future<void>.delayed(Duration.zero);
      expect(lamp.state.on, isTrue);
      expect(store.automationRuns, contains('dusk'));
      expect(store.automations.single.trigger.event, '15 min after sunset');
    });

    test('setting the town moves the scenes timed by the sun', () {
      final s = store.addScene('Dusk', [named('Floor lamp')])
        ..schedule = SceneSchedule.sun('sunset', lat: 51.5, lon: -0.13, offset: 10);
      store.setPlace(sofia);
      expect((s.schedule!.lat, s.schedule!.lon, s.schedule!.offset), (sofia.lat, sofia.lon, 10));
    });

    testWidgets('automations run when it starts to rain or gets cold outside, once', (tester) async {
      final lamp = await off('Floor lamp');
      final fan = await off('Bath fan');
      store.addAutomation(Automation(
        id: 'rain',
        trigger: const AutomationTrigger(deviceId: AutomationTrigger.home, kind: TriggerKind.rain),
        then: AutomationStep.device(lamp.id, on: true),
      ));
      store.addAutomation(Automation(
        id: 'cold',
        trigger: const AutomationTrigger(deviceId: AutomationTrigger.home, kind: TriggerKind.colderOutside, number: 5),
        then: AutomationStep.device(fan.id, on: true),
      ));
      expect(store.automations.last.trigger.event, 'it gets colder than 5° outside');
      forecast = () => sampleForecast(DateTime.now(), temp: 8, code: 3);
      store.setPlace(sofia);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(store.weather.now?.temp, 8);
      expect((lamp.state.on, fan.state.on), (false, false), reason: 'the first forecast is no change');

      forecast = () => sampleForecast(DateTime.now(), temp: 4, code: 61);
      await tester.runAsync(() => store.weather.refresh(sofia, force: true));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect((lamp.state.on, fan.state.on), (true, true));

      await store.command(lamp, const DeviceCommand(on: false));
      await tester.runAsync(() => store.weather.refresh(sofia, force: true));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      expect(lamp.state.on, isFalse, reason: 'still raining is not starting to rain');
      await tester.pump(const Duration(minutes: 1));
    });
  });
}
