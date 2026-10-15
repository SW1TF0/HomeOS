import 'dart:ui' show Offset;

import '../models/device.dart';
import '../models/home.dart';

const demoIntegrationId = 'demo';

/// The sample home shown on first launch, so the app is alive before any
/// hardware is connected. Everything here can be moved, renamed or deleted.
HomeData seedHome() {
  const floor = 'floor-ground';
  Room room(String id, String name, double x, double y, double w, double h) =>
      Room(id: id, floorId: floor, name: name, x: x, y: y, width: w, height: h);
  Device dev(String id, String name, DeviceKind kind, String roomId, double x, double y, DeviceState state,
          {bool favorite = false, Set<Capability>? caps}) =>
      Device(
        id: Device.idFor(demoIntegrationId, 'manual:$id'),
        name: name,
        kind: kind,
        integrationId: demoIntegrationId,
        externalId: 'manual:$id',
        capabilities: caps,
        roomId: roomId,
        floorId: floor,
        mapPos: Offset(x, y),
        favorite: favorite,
        state: state,
      );

  return HomeData(
    floors: [Floor(id: floor, name: 'Ground floor')],
    rooms: [
      room('room-living', 'Living', 1, 1, 15, 11),
      room('room-kitchen', 'Kitchen', 16, 1, 10, 7),
      room('room-hall', 'Hall', 16, 8, 10, 4),
      room('room-bedroom', 'Bedroom', 1, 12, 12, 9),
      room('room-bath', 'Bath', 13, 12, 6, 9),
      room('room-office', 'Office', 19, 12, 7, 9),
    ],
    integrations: [IntegrationConfig(id: demoIntegrationId, type: 'demo', name: 'Virtual devices')],
    devices: [
      dev('ceiling', 'Ceiling light', DeviceKind.light, 'room-living', 8, 5,
          const DeviceState(on: true, brightness: 0.72, colorTempK: 2700),
          favorite: true),
      dev('lamp', 'Floor lamp', DeviceKind.light, 'room-living', 3, 9,
          const DeviceState(on: true, brightness: 0.45, color: 0xFF5A36)),
      dev('tv', 'TV', DeviceKind.media, 'room-living', 13, 9, const DeviceState(on: false), favorite: true),
      dev('blinds', 'Blinds', DeviceKind.cover, 'room-living', 8, 2, const DeviceState(position: 0.6)),
      dev('thermostat', 'Thermostat', DeviceKind.climate, 'room-hall', 21, 10,
          const DeviceState(on: true, targetTemp: 21.5, currentTemp: 20.8),
          favorite: true),
      dev('door', 'Front door', DeviceKind.lock, 'room-hall', 25, 10, const DeviceState(locked: true), favorite: true),
      dev('kitchen', 'Kitchen lights', DeviceKind.light, 'room-kitchen', 21, 4,
          const DeviceState(on: false, brightness: 1, colorTempK: 4000),
          caps: {Capability.onOff, Capability.brightness, Capability.colorTemp}),
      dev('coffee', 'Coffee machine', DeviceKind.outlet, 'room-kitchen', 24, 2, const DeviceState(on: false),
          favorite: true),
      dev('bedside', 'Bedside lamp', DeviceKind.light, 'room-bedroom', 3, 14,
          const DeviceState(on: false, brightness: 0.3, colorTempK: 2200)),
      dev('climate-bed', 'Bedroom sensor', DeviceKind.sensor, 'room-bedroom', 11, 19,
          const DeviceState(readings: {'Temperature': '19.6 °C', 'Humidity': '48 %'})),
      dev('fan', 'Bath fan', DeviceKind.fan, 'room-bath', 16, 15, const DeviceState(on: false)),
      dev('desk', 'Desk lamp', DeviceKind.light, 'room-office', 22, 16,
          const DeviceState(on: true, brightness: 0.9, colorTempK: 5000),
          favorite: true),
    ],
  );
}
