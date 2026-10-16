import 'package:flutter/foundation.dart';

/// Where the map should go next: which room to show, and whether to edit.
typedef MapRequest = ({bool edit, String? roomId});

/// Lets any screen or sheet switch tabs, or open the map at a room.
class AppNav extends ChangeNotifier {
  AppNav({this.tab = 0});

  static const home = 0, map = 1, devices = 2, connect = 3;

  int tab;
  MapRequest? _mapRequest;

  void go(int i) {
    if (tab == i) return;
    tab = i;
    notifyListeners();
  }

  /// Shows the map, optionally zoomed to [roomId] and in edit mode.
  void openMap({bool edit = false, String? roomId}) {
    _mapRequest = (edit: edit, roomId: roomId);
    tab = map;
    notifyListeners();
  }

  /// Hands the waiting map request to the map, once.
  MapRequest? takeMapRequest() {
    final r = _mapRequest;
    _mapRequest = null;
    return r;
  }

  bool get hasMapRequest => _mapRequest != null;
}
