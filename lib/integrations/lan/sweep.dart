import 'dart:async';
import 'dart:io';

/// What knocking on an address found.
class SweepHit {
  const SweepHit(this.host, this.openPorts);
  final String host;

  /// Ports that accepted a connection. Empty when the device only refused,
  /// which still proves it is there.
  final Set<int> openPorts;
}

/// Ports worth knocking on: TVs, speakers, plugs, cameras, printers, PCs, phones, robots, routers.
const sweepPorts = [
  80, 443, 8080, 53, 22, 445, 139, 554, 631, 9100, 1400, 7000, 8008, 8009, 8060, 8001, 8002, 3000, 3001, //
  9999, 55443, 6668, 1883, 8123, 5000, 62078, 49152, 49153, 5555, 8443, 8883, 8291, 8728,
];

// "Connection refused" on Linux / Android, macOS / iOS and Windows.
const _refused = {111, 61, 10061};

/// Finds every address in [hosts] that answers on any of [ports]. A device
/// that refuses a connection counts too: it answered, so it exists.
Future<void> sweepHosts(
  List<String> hosts,
  void Function(SweepHit hit) found, {
  List<int> ports = sweepPorts,
  Map<int, int> portMap = const {},
  Duration timeout = const Duration(milliseconds: 600),
  int parallelHosts = 16,
}) async {
  var next = 0;
  Future<void> probe(String host) async {
    final open = <int>{};
    var alive = false;
    await Future.wait(ports.map((port) async {
      try {
        final s = await Socket.connect(host, portMap[port] ?? port, timeout: timeout);
        s.destroy();
        open.add(port);
        alive = true;
      } on SocketException catch (e) {
        if (_refused.contains(e.osError?.errorCode)) alive = true;
      } catch (_) {}
    }));
    if (alive) found(SweepHit(host, open));
  }

  Future<void> worker() async {
    while (next < hosts.length) {
      await probe(hosts[next++]);
    }
  }

  await Future.wait(List.generate(parallelHosts, (_) => worker()));
}

/// A name for [host] from the router's DNS (many routers know every device's name).
Future<String?> reverseName(String host) async {
  try {
    final r = await InternetAddress(host).reverse().timeout(const Duration(milliseconds: 1500));
    final name = r.host;
    if (name.isEmpty || name == host || RegExp(r'^[\d.]+$').hasMatch(name)) return null;
    return name.replaceFirst(RegExp(r'\.(local|lan|home|localdomain|home\.arpa|fritz\.box|domain)$', caseSensitive: false), '');
  } catch (_) {
    return null;
  }
}

/// Guesses a device from the ports it opened.
String? guessFromPorts(Set<int> open) {
  if (open.contains(8291) || open.contains(8728)) return 'mikrotik';
  if (open.contains(8060)) return 'roku';
  if (open.contains(8001) || open.contains(8002)) return 'samsung';
  if (open.contains(3000) || open.contains(3001)) return 'webos';
  if (open.contains(8008) || open.contains(8009)) return 'cast';
  if (open.contains(9999)) return 'kasa';
  if (open.contains(55443)) return 'yeelight';
  if (open.contains(1400)) return 'upnp';
  if (open.contains(554)) return 'camera';
  return null;
}
