import 'dart:typed_data';

/// Matter message framing (Core spec 4.4): the packet header that is sent in the
/// clear, and the protocol header that sits inside the encrypted payload.

class Protocols {
  static const secureChannel = 0x0000;
  static const interactionModel = 0x0001;
}

/// Secure channel opcodes.
class SecureOp {
  static const standaloneAck = 0x10;
  static const pbkdfParamRequest = 0x20;
  static const pbkdfParamResponse = 0x21;
  static const pake1 = 0x22;
  static const pake2 = 0x23;
  static const pake3 = 0x24;
  static const sigma1 = 0x30;
  static const sigma2 = 0x31;
  static const sigma3 = 0x32;
  static const sigma2Resume = 0x33;
  static const statusReport = 0x40;
}

/// Protocol codes of a secure channel StatusReport.
class SecureChannelCode {
  static const success = 0;
  static const noSharedTrustRoots = 1;
  static const invalidParameter = 2;
  static const closeSession = 3;
  static const busy = 4;
}

/// Interaction model opcodes.
class ImOp {
  static const statusResponse = 0x01;
  static const readRequest = 0x02;
  static const subscribeRequest = 0x03;
  static const subscribeResponse = 0x04;
  static const reportData = 0x05;
  static const writeRequest = 0x06;
  static const writeResponse = 0x07;
  static const invokeRequest = 0x08;
  static const invokeResponse = 0x09;
  static const timedRequest = 0x0a;
}

class MessageFormatException implements Exception {
  MessageFormatException(this.message);
  final String message;
  @override
  String toString() => 'Bad Matter message: $message';
}

int _le(Uint8List d, int at, int n) {
  if (at + n > d.length) throw MessageFormatException('too short');
  var v = 0;
  for (var i = 0; i < n; i++) {
    v |= d[at + i] << (8 * i);
  }
  return v;
}

void _put(BytesBuilder b, int v, int n) {
  for (var i = 0; i < n; i++) {
    b.addByte((v >>> (8 * i)) & 0xff);
  }
}

/// The unencrypted message header.
class PacketHeader {
  PacketHeader({
    required this.sessionId,
    required this.counter,
    this.securityFlags = 0,
    this.sourceNodeId,
    this.destNodeId,
    this.destGroupId,
  });

  final int sessionId;
  final int counter;
  final int securityFlags;
  final int? sourceNodeId;
  final int? destNodeId;
  final int? destGroupId;

  /// Length of the encoded header; the rest of a datagram is the payload.
  int length = 0;

  bool get isGroup => securityFlags & 0x03 == 1;
  bool get hasPrivacy => securityFlags & 0x80 != 0;
  bool get hasExtensions => securityFlags & 0x20 != 0;

  Uint8List encode() {
    final b = BytesBuilder();
    var flags = 0;
    if (sourceNodeId != null) flags |= 0x04;
    if (destNodeId != null) {
      flags |= 0x01;
    } else if (destGroupId != null) {
      flags |= 0x02;
    }
    b.addByte(flags);
    _put(b, sessionId, 2);
    b.addByte(securityFlags);
    _put(b, counter, 4);
    if (sourceNodeId != null) _put(b, sourceNodeId!, 8);
    if (destNodeId != null) _put(b, destNodeId!, 8);
    if (destNodeId == null && destGroupId != null) _put(b, destGroupId!, 2);
    final out = b.toBytes();
    length = out.length;
    return out;
  }

  static PacketHeader decode(Uint8List d) {
    if (d.length < 8) throw MessageFormatException('too short');
    final flags = d[0];
    if (flags >> 4 != 0) throw MessageFormatException('unknown version ${flags >> 4}');
    var at = 1;
    final sessionId = _le(d, at, 2);
    at += 2;
    final security = d[at++];
    if (security & 0x80 != 0) throw MessageFormatException('privacy headers are not supported');
    final counter = _le(d, at, 4);
    at += 4;
    int? source, dest, group;
    if (flags & 0x04 != 0) {
      source = _le(d, at, 8);
      at += 8;
    }
    if (flags & 0x03 == 1) {
      dest = _le(d, at, 8);
      at += 8;
    } else if (flags & 0x03 == 2) {
      group = _le(d, at, 2);
      at += 2;
    }
    if (security & 0x20 != 0) {
      final len = _le(d, at, 2);
      at += 2 + len;
    }
    return PacketHeader(
      sessionId: sessionId,
      counter: counter,
      securityFlags: security,
      sourceNodeId: source,
      destNodeId: dest,
      destGroupId: group,
    )..length = at;
  }
}

/// The protocol header: exchange, protocol, opcode and acknowledgement.
class PayloadHeader {
  PayloadHeader({
    required this.exchangeId,
    required this.protocolId,
    required this.opcode,
    this.initiator = false,
    this.reliable = false,
    this.ackCounter,
    this.vendorId,
  });

  final int exchangeId;
  final int protocolId;
  final int opcode;
  final bool initiator;
  final bool reliable;
  final int? ackCounter;
  final int? vendorId;

  Uint8List encode(List<int> payload) {
    final b = BytesBuilder();
    var flags = 0;
    if (initiator) flags |= 0x01;
    if (ackCounter != null) flags |= 0x02;
    if (reliable) flags |= 0x04;
    if (vendorId != null) flags |= 0x10;
    b.addByte(flags);
    b.addByte(opcode);
    _put(b, exchangeId, 2);
    if (vendorId != null) _put(b, vendorId!, 2);
    _put(b, protocolId, 2);
    if (ackCounter != null) _put(b, ackCounter!, 4);
    b.add(payload);
    return b.toBytes();
  }

  /// Splits a decrypted payload into its header and the application data.
  static (PayloadHeader, Uint8List) decode(Uint8List d) {
    if (d.length < 6) throw MessageFormatException('payload too short');
    final flags = d[0];
    final opcode = d[1];
    var at = 2;
    final exchange = _le(d, at, 2);
    at += 2;
    int? vendor;
    if (flags & 0x10 != 0) {
      vendor = _le(d, at, 2);
      at += 2;
    }
    final protocol = _le(d, at, 2);
    at += 2;
    int? ack;
    if (flags & 0x02 != 0) {
      ack = _le(d, at, 4);
      at += 4;
    }
    if (flags & 0x08 != 0) {
      final len = _le(d, at, 2);
      at += 2 + len;
    }
    return (
      PayloadHeader(
        exchangeId: exchange,
        protocolId: protocol,
        opcode: opcode,
        initiator: flags & 0x01 != 0,
        reliable: flags & 0x04 != 0,
        ackCounter: ack,
        vendorId: vendor,
      ),
      Uint8List.sublistView(d, at),
    );
  }
}

/// A secure channel StatusReport: general code, protocol and protocol code.
class StatusReport {
  StatusReport(this.generalCode, this.protocolId, this.protocolCode, [this.data]);

  final int generalCode;
  final int protocolId;
  final int protocolCode;

  /// Protocol specific data after the codes (a Busy report carries the wait in ms).
  final Uint8List? data;

  static const generalSuccess = 0;
  static const generalFailure = 1;
  static const generalBusy = 8;

  bool get ok => generalCode == generalSuccess;

  bool get isBusy => protocolId == Protocols.secureChannel && protocolCode == SecureChannelCode.busy;

  /// How long a busy device asks us to wait before trying again.
  Duration get busyDelay {
    final d = data;
    final ms = d != null && d.length >= 2 ? d[0] | (d[1] << 8) : 0;
    return Duration(milliseconds: ms <= 0 ? 1000 : ms);
  }

  Uint8List encode() {
    final b = BytesBuilder();
    _put(b, generalCode, 2);
    _put(b, protocolId, 4);
    _put(b, protocolCode, 2);
    if (data != null) b.add(data!);
    return b.toBytes();
  }

  static StatusReport decode(Uint8List d) => StatusReport(
      _le(d, 0, 2), _le(d, 2, 4), _le(d, 6, 2), d.length > 8 ? Uint8List.fromList(d.sublist(8)) : null);

  /// A readable reason for a failed handshake.
  String get reason {
    if (protocolId == Protocols.secureChannel) {
      switch (protocolCode) {
        case SecureChannelCode.noSharedTrustRoots:
          return 'the device does not know this app (it is not on its fabric)';
        case SecureChannelCode.invalidParameter:
          return 'the device rejected the request (wrong code or parameters)';
        case SecureChannelCode.closeSession:
          return 'the device closed the session';
        case SecureChannelCode.busy:
          return 'the device is busy, try again in a moment';
      }
    }
    return 'status $generalCode/$protocolCode';
  }

  @override
  String toString() => 'StatusReport($generalCode, protocol $protocolId, code $protocolCode)';
}
