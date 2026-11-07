import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/app.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';
import 'package:smartmenukj/state/updates.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  var asked = 0;
  http.Client github(String tag, {int status = 200}) => MockClient((req) async {
        asked++;
        expect(req.url.toString(), UpdateCheck.releasesApi);
        return http.Response(jsonEncode({'tag_name': tag}), status);
      });

  test('versions are compared as numbers, and only version tags count', () {
    expect(UpdateCheck.isNewer('1.18.0', '1.17.0'), isTrue);
    expect(UpdateCheck.isNewer('1.18.0', '1.9.2'), isTrue);
    expect(UpdateCheck.isNewer('1.18', '1.18.0'), isFalse);
    expect(UpdateCheck.isNewer('1.17.0', '1.17.0'), isFalse);
    expect(UpdateCheck.isNewer('2.0.0', '1.99.9'), isTrue);
    expect(UpdateCheck.versionOf('v1.18.0'), '1.18.0');
    expect(UpdateCheck.versionOf('native-latest'), isNull);
  });

  test('a newer release is offered until Later, then only a newer one; GitHub is asked twice a day at most', () async {
    asked = 0;
    var now = DateTime(2026, 11, 7, 9);
    await withClock(Clock(() => now), () async {
      final u = UpdateCheck(client: github('v1.19.0'), current: '1.18.0', platform: UpdatePlatform.android);
      expect(await u.check(), isTrue);
      expect(u.offer, isTrue);
      expect(u.downloadUrl, endsWith('/releases/latest/download/SmartMenuKJ-android.apk'));
      u.later();
      expect(u.offer, isFalse);

      now = now.add(const Duration(hours: 2));
      await u.check();
      expect(asked, 1, reason: 'asked a moment ago');

      // Kept for the next start.
      final again = UpdateCheck(client: github('v1.20.0'), current: '1.18.0');
      await again.load();
      expect(again.latest, '1.19.0');
      expect(again.offer, isFalse);
      now = now.add(const Duration(hours: 11));
      await again.check();
      expect(again.latest, '1.20.0');
      expect(again.offer, isTrue, reason: 'a newer one than the one put off');
    });
  });

  test('the same version, an error or no internet offers nothing', () async {
    final same = UpdateCheck(client: github('v1.18.0'), current: '1.18.0');
    expect(await same.check(), isTrue);
    expect(same.offer, isFalse);
    expect(same.upToDate, isTrue);

    final down = UpdateCheck(client: github('v1.19.0', status: 503), current: '1.18.0');
    expect(await down.check(), isFalse);
    expect(down.offer, isFalse);

    final offline = UpdateCheck(client: MockClient((_) async => throw Exception('no internet')), current: '1.18.0');
    expect(await offline.check(), isFalse);

    expect(await UpdateCheck.off().check(now: true), isFalse);
    expect(UpdateCheck.off(platform: UpdatePlatform.other).downloadUrl, UpdateCheck.allDownloads);
  });

  testWidgets('the home screen offers a new version, and Later puts it away', (tester) async {
    tester.view.physicalSize = const Size(840, 1800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    final store = HomeStore(repository: MemoryHomeRepository(), client: MockClient((_) async => http.Response('[]', 200)));
    await store.load();
    final updates = UpdateCheck(client: github('v99.0.0'), platform: UpdatePlatform.android);
    await tester.pumpWidget(SmartMenuApp(store: store, updates: updates, poll: false));
    await tester.pump();
    expect(find.byKey(const Key('update-card')), findsNothing);

    await tester.runAsync(updates.check);
    await tester.pump();
    expect(find.text('SmartHomeKJ 99.0.0 is out'), findsOneWidget);
    expect(find.textContaining('uninstall SmartHomeKJ first'), findsOneWidget);
    await tester.tap(find.byKey(const Key('update-later')));
    await tester.pump();
    expect(find.byKey(const Key('update-card')), findsNothing);
  });
}
