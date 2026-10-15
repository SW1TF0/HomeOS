import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/home.dart';

/// Where the home is saved. Local only: SmartMenuKJ has no cloud or account.
abstract class HomeRepository {
  Future<HomeData?> load();
  Future<void> save(HomeData data);
}

class LocalHomeRepository implements HomeRepository {
  static const _key = 'smartmenukj.home.v1';

  @override
  Future<HomeData?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      return HomeData.fromJson(Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(HomeData data) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(data.toJson()));
  }
}

class MemoryHomeRepository implements HomeRepository {
  MemoryHomeRepository([this.data]);
  HomeData? data;
  int saves = 0;

  @override
  Future<HomeData?> load() async =>
      data == null ? null : HomeData.fromJson(jsonDecode(jsonEncode(data!.toJson())) as Map<String, dynamic>);

  @override
  Future<void> save(HomeData d) async {
    saves++;
    data = HomeData.fromJson(jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>);
  }
}
