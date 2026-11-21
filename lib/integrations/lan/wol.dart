import 'dart:io';
import 'dart:typed_data';

import 'net.dart';

/// Normalises a MAC address to `aa:bb:cc:dd:ee:ff`, or returns null if it is not one.
String? normalizeMac(String? raw) {
  if (raw == null) return null;
  final hex = raw.replaceAll(RegExp(r'[^0-9a-fA-F]'), '').toLowerCase();
  if (hex.length != 12 || hex == '000000000000') return null;
  return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
}

/// The Wake-on-LAN "magic packet": six 0xFF bytes, then the MAC sixteen times.
Uint8List magicPacket(String mac) {
  final m = normalizeMac(mac);
  if (m == null) throw ArgumentError('Not a MAC address: $mac');
  final bytes = m.split(':').map((h) => int.parse(h, radix: 16)).toList();
  return Uint8List.fromList([for (var i = 0; i < 6; i++) 0xff, for (var i = 0; i < 16; i++) ...bytes]);
}

/// Wakes a device that supports Wake-on-LAN (most TVs, PCs, consoles).
Future<void> wakeOnLan(String mac, {String? host}) async {
  final packet = magicPacket(mac);
  final socket = await lanUdpSocket();
  try {
    final targets = await broadcastTargets();
    // Also the subnet broadcast (x.y.z.255), which some routers need.
    final ip = InternetAddress.tryParse(host ?? '');
    if (ip != null && ip.type == InternetAddressType.IPv4) {
      final parts = ip.address.split('.');
      final b = InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255');
      if (!targets.contains(b)) targets.add(b);
    }
    for (var i = 0; i < 3; i++) {
      for (final t in targets) {
        trySend(socket, packet, t, 9);
        trySend(socket, packet, t, 7);
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  } finally {
    socket.close();
  }
}
