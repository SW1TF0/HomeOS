import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/home.dart';

/// One home in the list of homes kept on this device.
class HomeEntry {
  HomeEntry({required this.id, required this.name, this.cloudId, this.account, this.stamp, this.synced, this.hub = false});

  final String id;
  String name;

  /// Where the home is kept in the signed-in account, once it is saved there.
  String? cloudId;

  /// The account the home belongs to.
  String? account;

  /// Which saved version of the home this device has, and a fingerprint of
  /// what it last sent or received, to tell whether anything changed since.
  String? stamp;
  String? synced;

  /// Whether this device stays at home and carries out what other devices
  /// ask for, from anywhere.
  bool hub;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'cloudId': ?cloudId,
        'account': ?account,
        'stamp': ?stamp,
        'synced': ?synced,
        if (hub) 'hub': true,
      };

  factory HomeEntry.fromJson(Map<String, dynamic> j) => HomeEntry(
        id: j['id'] as String,
        name: j['name'] as String? ?? defaultHomeName,
        cloudId: j['cloudId'] as String?,
        account: j['account'] as String?,
        stamp: j['stamp'] as String?,
        synced: j['synced'] as String?,
        hub: j['hub'] == true,
      );

  void unlink() {
    cloudId = account = stamp = synced = null;
    hub = false;
  }
}

/// The homes on this device, in the order they are listed, and the one that is open.
class HomeList {
  HomeList({required this.homes, required this.current});

  final List<HomeEntry> homes;
  String current;

  Map<String, dynamic> toJson() => {'current': current, 'homes': homes.map((h) => h.toJson()).toList()};

  factory HomeList.fromJson(Map<String, dynamic> j) => HomeList(
        homes: [for (final h in (j['homes'] as List? ?? const [])) HomeEntry.fromJson(Map<String, dynamic>.from(h as Map))],
        current: j['current'] as String? ?? firstHomeId,
      );

  HomeList copy() => HomeList.fromJson(jsonDecode(jsonEncode(toJson())) as Map<String, dynamic>);
}

/// The id of the home every install starts with. Homes saved before there
/// could be more than one become this home.
const firstHomeId = 'home';
const defaultHomeName = 'My home';

/// Where the homes are saved. Each home is its own JSON document.
abstract class HomeRepository {
  /// The list of homes and which one is open. Never empty.
  Future<HomeList> homes();
  Future<void> saveHomes(HomeList list);

  /// One home's floors, rooms, devices, connections and scenes; null when it has none yet.
  Future<HomeData?> load(String homeId);
  Future<void> save(String homeId, HomeData data);
  Future<void> remove(String homeId);
}

/// Saves on the device itself, in the app's preferences.
class LocalHomeRepository implements HomeRepository {
  static const _listKey = 'smartmenukj.homes.v1';

  /// The first home keeps the key it had when there was only one home.
  static String _key(String homeId) => homeId == firstHomeId ? 'smartmenukj.home.v1' : 'smartmenukj.home.v1.$homeId';

  @override
  Future<HomeList> homes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_listKey);
    try {
      if (raw != null) {
        final list = HomeList.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
        if (list.homes.isNotEmpty) return fixCurrent(list);
      }
    } catch (_) {}
    return HomeList(homes: [HomeEntry(id: firstHomeId, name: defaultHomeName)], current: firstHomeId);
  }

  @override
  Future<void> saveHomes(HomeList list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_listKey, jsonEncode(list.toJson()));
  }

  @override
  Future<HomeData?> load(String homeId) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key(homeId));
    if (raw == null) return null;
    try {
      return HomeData.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String homeId, HomeData data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key(homeId), jsonEncode(data.toJson()));
  }

  @override
  Future<void> remove(String homeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key(homeId));
  }
}

/// Makes sure the open home is one of the listed homes.
HomeList fixCurrent(HomeList list) {
  if (!list.homes.any((h) => h.id == list.current)) list.current = list.homes.first.id;
  return list;
}

/// Keeps everything in memory, for tests and screenshots.
class MemoryHomeRepository implements HomeRepository {
  MemoryHomeRepository([HomeData? data]) {
    if (data != null) _homes[firstHomeId] = _copy(data);
  }

  final Map<String, HomeData> _homes = {};
  HomeList _list = HomeList(homes: [HomeEntry(id: firstHomeId, name: defaultHomeName)], current: firstHomeId);
  int saves = 0;

  /// The saved copy of the open home.
  HomeData? get data => _homes[_list.current];

  static HomeData _copy(HomeData d) => HomeData.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);

  @override
  Future<HomeList> homes() async => _list.copy();

  @override
  Future<void> saveHomes(HomeList list) async => _list = fixCurrent(list.copy());

  @override
  Future<HomeData?> load(String homeId) async => _homes[homeId] == null ? null : _copy(_homes[homeId]!);

  @override
  Future<void> save(String homeId, HomeData d) async {
    saves++;
    _homes[homeId] = _copy(d);
  }

  @override
  Future<void> remove(String homeId) async => _homes.remove(homeId);
}
