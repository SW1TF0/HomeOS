import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/seed.dart';
import 'package:smartmenukj/util/color_math.dart';

void main() {
  test('home survives a JSON round trip', () {
    final home = seedHome();
    final back = HomeData.fromJson(jsonDecode(jsonEncode(home.toJson())) as Map<String, dynamic>);
    expect(back.floors.length, home.floors.length);
    expect(back.rooms.map((r) => r.name), home.rooms.map((r) => r.name));
    expect(back.devices.length, home.devices.length);
    final lamp = back.devices.firstWhere((d) => d.name == 'Floor lamp');
    expect(lamp.state.color, 0xFF5A36);
    expect(lamp.mapPos, const Offset(3, 9));
    expect(lamp.capabilities, contains(Capability.color));
  });

  test('commands change only what they name', () {
    const s = DeviceState(on: false, brightness: 0.4, colorTempK: 2700);
    final bright = s.applyCommand(const DeviceCommand(brightness: 0.9));
    expect(bright.on, isTrue, reason: 'raising brightness turns a light on');
    expect(bright.colorTempK, 2700);
    final colored = s.applyCommand(const DeviceCommand(color: 0xff0000));
    expect(colored.color, 0xff0000);
    expect(colored.colorTempK, isNull, reason: 'colour replaces white mode');
    expect(s.applyCommand(const DeviceCommand(on: true)).brightness, 0.4);
  });

  test('merge keeps known fields and readings', () {
    const a = DeviceState(on: true, readings: {'Temperature': '20 °C'});
    final b = a.merge(const DeviceState(readings: {'Humidity': '40 %'}));
    expect(b.on, isTrue);
    expect(b.readings, {'Temperature': '20 °C', 'Humidity': '40 %'});
    expect(a.merge(DeviceState.unreachable).reachable, isFalse);
  });

  test('colour conversions are close to inverse', () {
    for (final c in [0xff0000, 0x00ff00, 0x0000ff, 0xffffff]) {
      final xy = rgbToXy(c);
      final back = intToRgb(xyToRgb(xy[0], xy[1]));
      final orig = intToRgb(c);
      for (var i = 0; i < 3; i++) {
        expect((back[i] - orig[i]).abs(), lessThan(40), reason: 'channel $i of ${intToHex(c)}');
      }
    }
    expect(miredToKelvin(370), 2703);
    expect(kelvinToMired(4000), 250);
    expect(hexToInt('#ff8800'), 0xff8800);
  });

  test('room contains points inside its rectangle', () {
    final r = Room(id: 'r', floorId: 'f', name: 'R', x: 2, y: 2, width: 4, height: 3);
    expect(r.contains(const Offset(3, 3)), isTrue);
    expect(r.contains(const Offset(7, 3)), isFalse);
  });
}
