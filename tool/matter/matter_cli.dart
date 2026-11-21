// A small command-line Matter controller for trying the library against real
// devices or the matter.js simulator, without the app.
//
//   dart run tool/matter/matter_cli.dart <state.json> add <code> [address[:port]]
//   dart run tool/matter/matter_cli.dart <state.json> list
//   dart run tool/matter/matter_cli.dart <state.json> on|off <nodeHex> [endpoint]
//   dart run tool/matter/matter_cli.dart <state.json> level <nodeHex> <endpoint> <1..254>
//   dart run tool/matter/matter_cli.dart <state.json> ct <nodeHex> <endpoint> <mireds>
//   dart run tool/matter/matter_cli.dart <state.json> read <nodeHex> <endpoint>
//   dart run tool/matter/matter_cli.dart <state.json> remove <nodeHex>
//
// The state file holds the fabric keys and the added devices (created on first use).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:smartmenukj/integrations/matter/controller.dart';
import 'package:smartmenukj/integrations/matter/crypto.dart';
import 'package:smartmenukj/integrations/matter/discovery.dart';
import 'package:smartmenukj/integrations/matter/fabric.dart';
import 'package:smartmenukj/integrations/matter/session.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: matter_cli.dart <state.json> add|list|on|off|level|ct|read|remove ...');
    exit(2);
  }
  final file = File(args[0]);
  if (Platform.environment['MATTER_DEBUG'] != null) {
    final start = DateTime.now();
    matterLog = (l) => stdout.writeln('${DateTime.now().difference(start).inMilliseconds.toString().padLeft(6)} $l');
  }
  final iface = Platform.environment['MATTER_IFACE'];
  NetworkInterface? pinned;
  if (iface != null) {
    pinned = (await NetworkInterface.list(includeLoopback: true)).where((i) => i.name == iface).firstOrNull;
  }
  final discovery = MatterDiscovery(interface: pinned);
  final c = file.existsSync()
      ? MatterController.fromJson(jsonDecode(file.readAsStringSync()) as Map<String, dynamic>, discovery: discovery)
      : MatterController(MatterFabric.create(), discovery: discovery);
  void save() => file.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(c.toJson()));
  c.onChanged = save;
  save();
  int node(String s) => parseHex64(s);
  int ep(int i, [int fallback = 1]) => args.length > i ? int.parse(args[i]) : fallback;
  final watchdog = Timer(const Duration(seconds: 45), () {
    stderr.writeln('Gave up after 45 s.');
    exit(1);
  });
  try {
    switch (args[1]) {
      case 'add':
        final n = await c.commission(args[2], address: args.length > 3 ? args[3] : null, onProgress: (s) => stdout.writeln('... $s'));
        stdout.writeln('added $n');
        final d = await c.describe(n.nodeId);
        for (final e in d.endpoints) {
          stdout.writeln('  $e${e.label == null ? '' : ' "${e.label}"'}');
        }
      case 'list':
        for (final n in c.nodes.values) {
          stdout.writeln(n);
        }
      case 'on' || 'off':
        await c.setOnOff(node(args[2]), ep(3), args[1] == 'on');
      case 'level':
        await c.setLevel(node(args[2]), ep(3), int.parse(args[4]));
      case 'ct':
        await c.setColorTemperature(node(args[2]), ep(3), int.parse(args[4]));
      case 'read':
        stdout.writeln(await c.readLight(node(args[2]), ep(3)));
      case 'remove':
        await c.removeNode(node(args[2]));
      default:
        stderr.writeln('unknown command ${args[1]}');
    }
  } finally {
    watchdog.cancel();
    save();
    await c.close();
  }
}
