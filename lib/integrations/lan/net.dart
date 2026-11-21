import 'dart:io';
import 'dart:typed_data';

/// The phone's address on the home network and the size of that network.
class LocalNet {
  const LocalNet(this.interface, this.address);
  final String interface;
  final InternetAddress address;

  List<int> get bytes => address.rawAddress;

  /// The /24 this address sits in, e.g. `192.168.1`.
  String get prefix24 => bytes.take(3).join('.');

  /// Broadcast address of the /24 (x.y.z.255), which reaches the local network
  /// even when the phone's default route is mobile data.
  InternetAddress get broadcast => InternetAddress('$prefix24.255');
}

bool isPrivateIPv4(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return b[0] == 10 || (b[0] == 192 && b[1] == 168) || (b[0] == 172 && b[1] >= 16 && b[1] < 32);
}

/// Private IPv4 addresses of this device, Wi-Fi / Ethernet first. Mobile data,
/// VPN and hotspot-only interfaces come last or are skipped.
Future<List<LocalNet>> localNetworks() async {
  List<NetworkInterface> ifaces;
  try {
    ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
  } catch (_) {
    return const [];
  }
  int score(String name) {
    final n = name.toLowerCase();
    if (n.startsWith('wlan') || n.startsWith('wl') || n.startsWith('en') || n.startsWith('eth') || n.contains('wi-fi')) {
      return 0;
    }
    // Mobile data (rmnet, ccmni, pdp, seth, wwan, clat...), VPNs and containers.
    if (n.startsWith('rmnet') || n.startsWith('ccmni') || n.startsWith('tun') || n.startsWith('ppp') ||
        n.startsWith('utun') || n.startsWith('docker') || n.startsWith('veth') || n.startsWith('br-') ||
        n.startsWith('pdp') || n.startsWith('seth') || n.startsWith('wwan') || n.startsWith('v4-') ||
        n.startsWith('clat') || n.startsWith('ccinet') || n.contains('rmnet')) {
      return 9;
    }
    return 5;
  }

  final out = <LocalNet>[
    for (final i in ifaces)
      for (final a in i.addresses)
        if (isPrivateIPv4(a) && score(i.name) < 9) LocalNet(i.name, a),
  ]..sort((a, b) => score(a.interface).compareTo(score(b.interface)));
  return out;
}

/// Whether this device is on a Wi-Fi or wired network. Mobile data and VPNs do not count.
Future<bool> hasHomeNetwork() async => (await localNetworks()).isNotEmpty;

/// A UDP socket whose multicast and broadcast packets leave through the home
/// network. Without this, Android can send them out over mobile data.
Future<RawDatagramSocket> lanUdpSocket({LocalNet? via}) async {
  final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  socket.broadcastEnabled = true;
  final net = via ?? (await localNetworks()).firstOrNull;
  if (net != null) {
    try {
      socket.setRawOption(RawSocketOption(
          RawSocketOption.levelIPv4, RawSocketOption.IPv4MulticastInterface, Uint8List.fromList(net.bytes)));
    } catch (_) {}
  }
  try {
    socket.multicastHops = 4;
  } catch (_) {}
  return socket;
}

/// Broadcast targets: the subnet broadcast of each local network, then the global one.
Future<List<InternetAddress>> broadcastTargets() async {
  final nets = await localNetworks();
  return {for (final n in nets.take(2)) n.broadcast, InternetAddress('255.255.255.255')}.toList();
}

/// Sends [data] and ignores "network unreachable" style errors.
void trySend(RawDatagramSocket s, List<int> data, InternetAddress to, int port) {
  try {
    s.send(data, to, port);
  } catch (_) {}
}
