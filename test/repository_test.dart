import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/repository.dart';

void main() {
  test('a home saved before there were several homes becomes the first home', () async {
    final old = HomeData(floors: [Floor(id: 'f', name: 'Upstairs')]);
    SharedPreferences.setMockInitialValues({'smartmenukj.home.v1': jsonEncode(old.toJson())});
    final repo = LocalHomeRepository();
    final list = await repo.homes();
    expect(list.homes.map((h) => h.id), [firstHomeId]);
    expect(list.current, firstHomeId);
    expect((await repo.load(list.current))!.floors.single.name, 'Upstairs');
  });

  test('each home is saved on its own and can be removed', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = LocalHomeRepository();
    await repo.save(firstHomeId, HomeData(floors: [Floor(id: 'a', name: 'A')]));
    await repo.save('home-2', HomeData(floors: [Floor(id: 'b', name: 'B')]));
    await repo.saveHomes(HomeList(
        homes: [HomeEntry(id: firstHomeId, name: 'Flat'), HomeEntry(id: 'home-2', name: 'Cabin')], current: 'home-2'));
    final list = await repo.homes();
    expect(list.homes.map((h) => h.name), ['Flat', 'Cabin']);
    expect(list.current, 'home-2');
    expect((await repo.load('home-2'))!.floors.single.name, 'B');
    expect((await repo.load(firstHomeId))!.floors.single.name, 'A');
    await repo.remove('home-2');
    expect(await repo.load('home-2'), isNull);
  });

  test('a list pointing at a missing home opens the first one', () async {
    SharedPreferences.setMockInitialValues({
      'smartmenukj.homes.v1': jsonEncode({
        'current': 'gone',
        'homes': [
          {'id': 'home', 'name': 'Flat'},
        ],
      }),
    });
    expect((await LocalHomeRepository().homes()).current, 'home');
  });
}
