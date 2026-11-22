import 'package:flutter/foundation.dart';

/// Where the map should go next: which room to show, and whether to edit.
typedef MapRequest = ({bool edit, String? roomId});

/// Lets any screen or sheet switch tabs, or open the map at a room.
class AppNav extends ChangeNotifier {
  AppNav({this.tab = 0});

  /// The tabs, in the order of the tab bar. The floor plan is the Rooms tab.
  static const home = 0, rooms = 1, automate = 2, more = 3;
  static const map = rooms;
  static const count = 4;

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
