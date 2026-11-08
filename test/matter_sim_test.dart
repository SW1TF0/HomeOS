// End-to-end tests against the matter.js device simulator: commissioning,
// control, state read-back and reconnecting from saved settings.
//
// They run when Node and matter.js are installed (`cd tool/matter && npm
// install`, or point MATTER_SIM_DIR elsewhere) and skip otherwise. The
// simulator is started as `node device.mjs <port> <light|bridge|robot> <storage>`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smartmenukj/integrations/integration.dart';
import 'package:smartmenukj/integrations/matter/commissioner.dart';
import 'package:smartmenukj/integrations/matter/controller.dart';
import 'package:smartmenukj/integrations/matter/discovery.dart';
import 'package:smartmenukj/integrations/matter/fabric.dart';
import 'package:smartmenukj/integrations/matter/matter_driver.dart';
import 'package:smartmenukj/integrations/matter/onboarding.dart';
import 'package:smartmenukj/integrations/matter/session.dart';
import 'package:smartmenukj/models/device.dart';
import 'package:smartmenukj/models/home.dart';
import 'package:smartmenukj/state/home_store.dart';
import 'package:smartmenukj/state/repository.dart';

final _simDir = Platform.environment['MATTER_SIM_DIR'] ?? 'tool/matter';
const _code = '34970112332';

String? _skipReason() {
  if (!File('$_simDir/device.mjs').existsSync()) return 'matter.js simulator not found in $_simDir';
  if (!Directory('$_simDir/node_modules/@matter/main').existsSync()) return 'matter.js is not installed in $_simDir';
  try {
    final r = Process.runSync('node', ['--version']);
    if (r.exitCode != 0) return 'node does not run';
  } on ProcessException {
    return 'node is not installed';
  }
  return null;
}

/// One running simulator.
class _Sim {
  _Sim._(this.kind, this.port, this._process, this._storage);

  final String kind;
  final int port;
  final Process _process;
  final Directory _storage;
  final lines = <String>[];
  final _waiters = <(bool Function(String), Completer<String>)>[];

  static Future<_Sim> start(String kind) async {
    final probe = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = probe.port;
    probe.close();
    final storage = await Directory.systemTemp.createTemp('matter_sim_');
    final p = await Process.start('node', ['device.mjs', '$port', kind, storage.path], workingDirectory: _simDir);
    final sim = _Sim._(kind, port, p, storage);
    for (final stream in [p.stdout, p.stderr]) {
      stream.transform(utf8.decoder).transform(const LineSplitter()).listen(sim._line);
    }
    await sim.waitFor('READY', timeout: const Duration(seconds: 60));
    return sim;
  }

  void _line(String l) {
    lines.add(l);
    if (Platform.environment['MATTER_DEBUG'] != null) stdout.writeln('[sim $kind] $l');
    for (final w in List.of(_waiters)) {
      if (w.$1(l)) {
        _waiters.remove(w);
        w.$2.complete(l);
      }
    }
  }

  /// Waits for an output line equal to [line] (or matching [test]) that was
  /// printed after [after] lines.
  Future<String> waitFor(String line, {int after = 0, Duration timeout = const Duration(seconds: 15)}) {
    for (var i = after; i < lines.length; i++) {
      if (lines[i].trim() == line) return Future.value(lines[i]);
    }
    final c = Completer<String>();
    _waiters.add(((l) => l.trim() == line, c));
    return c.future.timeout(timeout, onTimeout: () => throw TimeoutException('simulator never printed "$line"'));
  }

  Future<String> waitForPrefix(String prefix, {int after = 0, Duration timeout = const Duration(seconds: 15)}) {
    for (var i = after; i < lines.length; i++) {
      if (lines[i].trim().startsWith(prefix)) return Future.value(lines[i]);
    }
    final c = Completer<String>();
    _waiters.add(((l) => l.trim().startsWith(prefix), c));
    return c.future.timeout(timeout, onTimeout: () => throw TimeoutException('simulator never printed "$prefix..."'));
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode.timeout(const Duration(seconds: 10), onTimeout: () {
      _process.kill(ProcessSignal.sigkill);
      return -1;
    });
    try {
      await _storage.delete(recursive: true);
    } catch (_) {}
  }
}

Future<NetworkInterface?> _loopback() async =>
    (await NetworkInterface.list(includeLoopback: true, type: InternetAddressType.IPv4))
        .where((i) => i.addresses.any((a) => a.isLoopback))
        .firstOrNull;

MatterDriver _driver(IntegrationConfig cfg, NetworkInterface? lo) =>
    MatterDriver(cfg, http.Client(), discovery: MatterDiscovery(interface: lo));

IntegrationConfig _reloaded(IntegrationConfig cfg) => IntegrationConfig.fromJson(
    Map<String, dynamic>.from(jsonDecode(jsonEncode(cfg.toJson())) as Map));

void main() {
  final skip = _skipReason();
  if (Platform.environment['MATTER_DEBUG'] != null) matterLog = (l) => stdout.writeln('[matter] $l');

  group('matter.js colour light', () {
    late _Sim sim;
    NetworkInterface? lo;

    setUpAll(() async {
      sim = await _Sim.start('light');
      lo = await _loopback();
    });
    tearDownAll(() => sim.stop());

    test('commission, control, read back, reconnect from saved settings', () async {
      final cfg = IntegrationConfig(id: 'matter1', type: matterType, name: 'Matter');
      final driver = _driver(cfg, lo);
      final steps = <String>[];
      final devices = await driver.commission(_code, address: '127.0.0.1:${sim.port}', onProgress: steps.add);
      await sim.waitFor('EVENT commissioned');
      expect(steps, matterCommissioningSteps);

      expect(devices, hasLength(1));
      final light = devices.single;
      expect(light.kind, DeviceKind.light);
      expect(light.name, 'Sim light');
      expect(light.capabilities,
          containsAll([Capability.onOff, Capability.brightness, Capability.colorTemp, Capability.color]));
      expect(light.state.reachable, isTrue);
      expect(light.state.colorTempK, (1000000 / 250).round()); // the simulator starts at 250 mireds

      // What the app must save to reach the device again.
      final nodes = cfg.settings['nodes'] as List;
      expect(nodes, hasLength(1));
      expect((nodes.single as Map)['port'], sim.port);
      expect((nodes.single as Map)['address'], '127.0.0.1');
      expect(cfg.settings['fabric'], isA<Map>());

      // The device now advertises itself on our fabric.
      final fabric = MatterFabric.fromJson(Map<String, dynamic>.from(cfg.settings['fabric'] as Map));
      final nodeId = matterNodeIdOf(light)!;
      final found = await MatterDiscovery(interface: lo).resolveOperational(fabric.instanceName(nodeId));
      expect(found?.port, sim.port, reason: 'operational mDNS record');

      expect((await driver.discover()).map((d) => d.id), [light.id]);

      var mark = sim.lines.length;
      var state = await driver.send(light, const DeviceCommand(on: true));
      await sim.waitFor('STATE onOff=true', after: mark);
      expect(state?.on, isTrue);

      mark = sim.lines.length;
      state = await driver.send(light, const DeviceCommand(brightness: 0.5));
      await sim.waitFor('STATE level=127', after: mark);
      expect(state?.brightness, closeTo(0.5, 0.01));

      mark = sim.lines.length;
      state = await driver.send(light, const DeviceCommand(color: 0xff0000));
      await sim.waitForPrefix('STATE x=', after: mark);
      expect(state?.color, isNotNull);

      mark = sim.lines.length;
      state = await driver.send(light, const DeviceCommand(colorTempK: 2700));
      await sim.waitFor('STATE mireds=370', after: mark);
      expect(state?.colorTempK, (1000000 / 370).round());

      mark = sim.lines.length;
      await driver.send(light, const DeviceCommand(on: false));
      await sim.waitFor('STATE onOff=false', after: mark);

      final read = await driver.refreshAll([light]);
      expect(read[light.id]?.on, isFalse);
      expect(read[light.id]?.brightness, closeTo(127 / 254, 0.001));
      expect(read[light.id]?.colorTempK, (1000000 / 370).round());
      expect(read[light.id]?.reachable, isTrue);
      await driver.stop();

      // A new driver from the saved settings (as after an app restart) reconnects with CASE.
      final again = _driver(_reloaded(cfg), lo);
      mark = sim.lines.length;
      final back = await again.send(light, const DeviceCommand(on: true));
      await sim.waitFor('STATE onOff=true', after: mark);
      expect(back?.on, isTrue);
      final read2 = await again.refreshAll([light]);
      expect(read2[light.id]?.on, isTrue);
      await again.stop();
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: skip);

  group('matter.js bridge', () {
    late _Sim sim;
    NetworkInterface? lo;

    setUpAll(() async {
      sim = await _Sim.start('bridge');
      lo = await _loopback();
    });
    tearDownAll(() => sim.stop());

    test('a wrong code is reported and the device can still be added', () async {
      final c = MatterController(MatterFabric.create(), discovery: MatterDiscovery(interface: lo));
      final wrong = SetupCode(passcode: 20202022, discriminator: 15, isShort: true).manualCode;
      await expectLater(
        c.commission(wrong, address: '127.0.0.1:${sim.port}'),
        throwsA(isA<CommissioningException>().having((e) => e.failure, 'failure', CommissioningFailure.wrongCode)),
      );
      await c.close();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('finds the device in pairing mode with mDNS', () async {
      final found = await MatterDiscovery(interface: lo).commissionable(code: parseSetupCode(_code));
      expect(found.map((d) => d.port), contains(sim.port));
      final d = found.firstWhere((d) => d.port == sim.port);
      expect(d.discriminator, 3840);
      expect(d.vendorId, 0xfff1);
      expect(d.productId, 0x8000);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('commission found with mDNS: two plugs and a temperature sensor', () async {
      final cfg = IntegrationConfig(id: 'matter2', type: matterType, name: 'Matter');
      final driver = _driver(cfg, lo);
      final devices = await driver.commission(_code);
      await sim.waitFor('EVENT commissioned');

      final plugs = devices.where((d) => d.kind == DeviceKind.outlet).toList();
      final sensors = devices.where((d) => d.kind == DeviceKind.sensor).toList();
      expect(devices, hasLength(3));
      expect(plugs.map((d) => d.name), unorderedEquals(['Kettle plug', 'Fan plug']));
      expect(sensors.single.name, 'Hall sensor');
      expect(sensors.single.state.currentTemp, 21.5);
      expect(sensors.single.state.readings['Temperature'], '21.5 °C');

      final kettle = plugs.firstWhere((d) => d.name == 'Kettle plug');
      final on = await driver.send(kettle, const DeviceCommand(on: true));
      expect(on?.on, isTrue);
      final fan = plugs.firstWhere((d) => d.name == 'Fan plug');
      final states = await driver.refreshAll(devices);
      expect(states[kettle.id]?.on, isTrue);
      expect(states[fan.id]?.on, isFalse);
      await driver.stop();

      final again = _driver(_reloaded(cfg), lo);
      final read = await again.refreshAll(devices);
      expect(read[sensors.single.id]?.currentTemp, 21.5);
      expect(read[kettle.id]?.on, isTrue);
      final off = await again.send(kettle, const DeviceCommand(on: false));
      expect(off?.on, isFalse);

      // Removing the device takes SmartHomeKJ off it.
      await again.removeNode(matterNodeIdOf(kettle)!);
      expect(again.controller.nodes, isEmpty);
      await expectLater(again.refreshAll([kettle]).then((m) => m[kettle.id]?.reachable), completion(isFalse));
      await again.stop();
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: skip);

  group('matter.js robot vacuum and appliances', () {
    late _Sim sim;
    NetworkInterface? lo;

    setUpAll(() async {
      sim = await _Sim.start('robot');
      lo = await _loopback();
    });
    tearDownAll(() => sim.stop());

    test('a robot vacuum, an air purifier, a water valve, a washing machine and a smoke alarm', () async {
      final cfg = IntegrationConfig(id: 'matter3', type: matterType, name: 'Matter');
      final driver = _driver(cfg, lo);
      final devices = await driver.commission(_code, address: '127.0.0.1:${sim.port}');
      await sim.waitFor('EVENT commissioned');
      expect(devices.map((d) => d.kind), [
        DeviceKind.vacuum, DeviceKind.purifier, DeviceKind.valve, DeviceKind.appliance, DeviceKind.sensor, //
      ]);
      Device of(DeviceKind kind) => devices.singleWhere((d) => d.kind == kind);

      // Sends [c], waits for the simulator to print [line], then reads the device back as the app would.
      Future<DeviceState> send(Device d, DeviceCommand c, String line) async {
        final mark = sim.lines.length;
        final confirmed = await driver.send(d, c);
        d.state = d.state.merge(confirmed!);
        await sim.waitFor(line, after: mark);
        return d.state = (await driver.refreshAll([d]))[d.id]!;
      }

      final robot = of(DeviceKind.vacuum);
      expect(robot.capabilities, {Capability.run, Capability.dock, Capability.locate, Capability.mode});
      expect(robot.props['noStop'], isFalse, reason: 'it has "go home", so stop is a button of its own');
      expect(robot.state.activity, Activity.docked);
      expect(robot.state.battery, 0.8);
      expect(robot.modes, ['Vacuum', 'Mop', 'Deep clean']);
      expect(robot.state.mode, 'Vacuum');
      expect((await send(robot, const DeviceCommand(action: DeviceAction.start), 'COMMAND run 1')).activity,
          Activity.running);
      expect((await send(robot, const DeviceCommand(action: DeviceAction.pause), 'COMMAND pause')).activity,
          Activity.paused);
      expect((await send(robot, const DeviceCommand(action: DeviceAction.start), 'COMMAND resume')).activity,
          Activity.running);
      expect((await send(robot, const DeviceCommand(mode: 'Mop'), 'STATE clean=1')).mode, 'Mop');
      await send(robot, const DeviceCommand(action: DeviceAction.locate), 'STATE identify=10');
      expect((await send(robot, const DeviceCommand(action: DeviceAction.dock), 'COMMAND goHome')).activity,
          Activity.returning);
      await expectLater(driver.send(robot, const DeviceCommand(mode: 'Turbo')),
          throwsA(isA<IntegrationException>().having((e) => e.message, 'message', contains('no mode called Turbo'))));

      final purifier = of(DeviceKind.purifier);
      expect(purifier.capabilities, {Capability.onOff, Capability.speed, Capability.mode});
      expect(purifier.modes, ['Auto']);
      expect(purifier.state.on, isFalse);
      expect(purifier.state.readings['PM2.5'], '12 µg/m³');
      var s = await send(purifier, const DeviceCommand(speed: 0.5), 'STATE fanMode=2');
      expect((s.on, s.speed, s.mode), (true, 0.5, null));
      s = await send(purifier, const DeviceCommand(mode: 'Auto'), 'STATE fanMode=5');
      expect(s.mode, 'Auto');
      s = await send(purifier, const DeviceCommand(speed: 1), 'STATE fanMode=3');
      expect((s.speed, s.mode), (1.0, null), reason: 'a speed of its own takes it out of Auto');
      expect((await send(purifier, const DeviceCommand(on: false), 'STATE fanMode=0')).on, isFalse);

      final valve = of(DeviceKind.valve);
      expect(valve.capabilities, {Capability.onOff});
      expect(valve.state.on, isFalse);
      expect((await send(valve, const DeviceCommand(on: true), 'STATE valve=1')).on, isTrue);
      expect((await send(valve, const DeviceCommand(on: false), 'STATE valve=0')).on, isFalse);

      final washer = of(DeviceKind.appliance);
      expect(washer.capabilities, {Capability.run, Capability.mode});
      expect(washer.props['noStop'], isFalse);
      expect(washer.modes, ['Normal', 'Delicate', 'Heavy']);
      expect(washer.state.activity, Activity.idle);
      expect((await send(washer, const DeviceCommand(mode: 'Delicate'), 'STATE program=1')).mode, 'Delicate');
      s = await send(washer, const DeviceCommand(action: DeviceAction.start), 'COMMAND start');
      expect((s.activity, s.readings['Left']), (Activity.running, '45 min'));
      expect((await send(washer, const DeviceCommand(action: DeviceAction.pause), 'COMMAND pause')).activity,
          Activity.paused);
      await send(washer, const DeviceCommand(action: DeviceAction.start), 'COMMAND resume');
      s = await send(washer, const DeviceCommand(action: DeviceAction.stop), 'COMMAND stop');
      expect((s.activity, s.readings['Left']), (Activity.idle, null), reason: 'no time left once it stops');

      expect(of(DeviceKind.sensor).state.readings, {'Smoke': 'Clear', 'Carbon monoxide': 'Warning'});
      await driver.stop();
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: skip);

  group('the app', () {
    late _Sim sim;

    setUpAll(() async => sim = await _Sim.start('light'));
    tearDownAll(() => sim.stop());

    test('pairs a device, reaches it again after a restart and frees it when removed', () async {
      final repo = MemoryHomeRepository();
      final store = HomeStore(repository: repo, client: http.Client());
      await store.load();
      final added = await store.pairMatter(_code, address: '127.0.0.1:${sim.port}');
      await sim.waitFor('EVENT commissioned');
      expect(added.map((d) => d.name), ['Sim light']);
      final light = store.device(added.single.id)!;

      var mark = sim.lines.length;
      expect(await store.command(light, const DeviceCommand(on: true)), isTrue);
      await sim.waitFor('STATE onOff=true', after: mark);
      await store.saveNow();
      store.dispose();

      // A restart: the saved keys and address still reach the device.
      final again = HomeStore(repository: repo, client: http.Client());
      await again.load();
      final back = again.device(light.id)!;
      mark = sim.lines.length;
      expect(await again.command(back, const DeviceCommand(on: false)), isTrue);
      await sim.waitFor('STATE onOff=false', after: mark);

      // Removing its last part takes SmartHomeKJ off the device.
      again.removeDevice(back);
      final cfg = again.integrations.firstWhere((i) => i.type == matterType);
      for (var i = 0; i < 100 && (cfg.settings['nodes'] as List).isNotEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(cfg.settings['nodes'], isEmpty);
      await again.saveNow();
      expect(repo.data!.integrations.firstWhere((i) => i.type == matterType).settings['nodes'], isEmpty);
      again.dispose();
    }, timeout: const Timeout(Duration(minutes: 3)));
  }, skip: skip);
}
