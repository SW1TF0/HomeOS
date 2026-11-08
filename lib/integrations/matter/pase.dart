import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'crypto.dart';
import 'message.dart';
import 'session.dart';
import 'spake2p.dart';
import 'tlv.dart';

/// PASE (Core spec 4.13.1): proves the user typed the right setup code and
/// opens the first encrypted session with a device that is in pairing mode.

/// The device answered, but the code did not match.
class WrongCodeException extends MatterException {
  WrongCodeException([super.message = 'The setup code is wrong, or the pairing window has closed.']);
}

/// Runs PASE with the device at [address]:[port] and returns the new session.
Future<SecureSession> establishPase(
  MatterTransport transport,
  InternetAddress address,
  int port,
  int passcode, {
  MrpParams params = const MrpParams(),
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await _pase(transport, address, port, passcode, params);
    } on _Busy catch (b) {
      if (attempt >= 3) throw MatterException('The device is busy. Try again in a moment.');
      await Future<void>.delayed(b.delay);
    }
  }
}

class _Busy implements Exception {
  _Busy(this.delay);
  final Duration delay;
}

Future<SecureSession> _pase(
    MatterTransport transport, InternetAddress address, int port, int passcode, MrpParams params) async {
  final plain = transport.unsecured(address, port, params: params);
  final x = plain.exchange(Protocols.secureChannel);
  var ok = false;
  try {
    final localId = transport.newSessionId();
    final random = randomBytes(32);
    final request = tlvStruct((w) {
      w.bytes(1, random);
      w.uint(2, localId);
      w.uint(3, 0); // default passcode id
      w.boolean(4, false); // we do not know the PBKDF parameters yet
      writeSessionParams(w, 5);
    });
    final response = _expect(await x.request(SecureOp.pbkdfParamRequest, request), SecureOp.pbkdfParamResponse);
    final r = _struct(response.payload);
    final peerId = r.integer(3);
    final pbkdf = r.struct(4);
    final iterations = pbkdf?.integer(1);
    final salt = pbkdf?.bytes(2);
    if (!bytesEqual(r.bytes(1) ?? const [], random) ||
        peerId == null ||
        iterations == null ||
        salt == null ||
        iterations < 1000 ||
        iterations > 100000 ||
        salt.length < 16 ||
        salt.length > 32) {
      throw MatterException('The device sent pairing parameters this app cannot use.');
    }
    final peerParams = MrpParams.fromTlv(r[5], plain.peerParams);
    plain.peerParams = peerParams;

    final w0w1 = await _w0w1(passcode, salt, iterations);
    final prover = Spake2pProver(spakeContext(request, response.payload), w0w1);
    final pake2 = _expect(
        await x.request(SecureOp.pake1, tlvStruct((w) => w.bytes(1, prover.shareX))), SecureOp.pake2);
    final p2 = _struct(pake2.payload);
    final shareY = p2.bytes(1), cB = p2.bytes(2);
    if (shareY == null || cB == null) throw MatterException('The device sent a broken pairing message.');
    final SpakeResult keys;
    try {
      keys = prover.finish(shareY);
    } on CryptoException {
      throw MatterException('The device sent a broken pairing message.');
    }
    if (!bytesEqual(keys.cB, cB)) {
      // Tell the device, so it gives up this attempt now instead of after a minute.
      _sendStatus(x, StatusReport.generalFailure, SecureChannelCode.invalidParameter);
      throw WrongCodeException();
    }
    final done = await x.request(SecureOp.pake3, tlvStruct((w) => w.bytes(1, keys.cA)));
    if (!done.isStatusReport) throw MatterException('The device sent an unexpected pairing message.');
    final status = done.statusReport;
    if (!status.ok) {
      if (status.protocolCode == SecureChannelCode.invalidParameter) throw WrongCodeException();
      throw MatterException('Pairing failed: ${status.reason}.');
    }
    final session = SecureSession.derive(
      plain,
      localId: localId,
      peerId: peerId,
      secret: keys.ke,
      salt: const [],
      peerParams: peerParams,
    );
    ok = true;
    return session;
  } finally {
    x.close();
    if (ok) {
      // Stay around briefly to acknowledge a repeated final status report.
      Timer(const Duration(seconds: 3), plain.close);
    } else {
      plain.close();
    }
  }
}

/// PBKDF2 takes about a second on a phone: run it on another isolate. Kept in
/// its own function so the closure captures only these three values.
Future<Uint8List> _w0w1(int passcode, Uint8List salt, int iterations) =>
    Isolate.run(() => spakeW0W1(passcode, salt, iterations));

MatterMessage _expect(MatterMessage m, int opcode) {
  if (m.isStatusReport) {
    final s = m.statusReport;
    if (s.isBusy) throw _Busy(s.busyDelay);
    if (s.protocolCode == SecureChannelCode.invalidParameter) throw WrongCodeException();
    throw MatterException('Pairing failed: ${s.reason}.');
  }
  if (m.protocolId != Protocols.secureChannel || m.opcode != opcode) {
    throw MatterException('The device sent an unexpected pairing message.');
  }
  return m;
}

TlvStruct _struct(Uint8List payload) {
  try {
    final v = decodeTlv(payload);
    if (v is TlvStruct) return v;
  } on TlvFormatException {
    // fall through
  } on RangeError {
    // fall through
  }
  throw MatterException('The device sent a broken pairing message.');
}

void _sendStatus(Exchange x, int general, int code) {
  try {
    x.send(SecureOp.statusReport, StatusReport(general, Protocols.secureChannel, code).encode());
  } catch (_) {}
}
