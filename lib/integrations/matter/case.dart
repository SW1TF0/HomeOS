import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'certs.dart';
import 'crypto.dart';
import 'fabric.dart';
import 'message.dart';
import 'session.dart';
import 'tlv.dart';

/// CASE (Core spec 4.14.2): the certificate-based handshake that opens an
/// encrypted session with a device already on our fabric. This app always
/// starts it (it is the initiator). Session resumption is not used: every
/// connection runs the full Sigma1/2/3 exchange, which costs only a few
/// milliseconds more.

/// The device does not have our fabric (it was reset or removed from the app).
class NotOnFabricException extends MatterException {
  NotOnFabricException(
      [super.message = 'The device no longer knows SmartMenuKJ. It may have been reset; add it again.']);
}

final _sigma2Nonce = Uint8List.fromList('NCASE_Sigma2N'.codeUnits);
final _sigma3Nonce = Uint8List.fromList('NCASE_Sigma3N'.codeUnits);

/// Runs CASE with node [peerNodeId] of [fabric] at [address]:[port].
Future<SecureSession> establishCase(
  MatterTransport transport,
  MatterFabric fabric,
  int peerNodeId,
  InternetAddress address,
  int port, {
  MrpParams params = const MrpParams(),
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await _case(transport, fabric, peerNodeId, address, port, params);
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

Future<SecureSession> _case(MatterTransport transport, MatterFabric fabric, int peerNodeId,
    InternetAddress address, int port, MrpParams params) async {
  final plain = transport.unsecured(address, port, params: params);
  final x = plain.exchange(Protocols.secureChannel);
  var ok = false;
  try {
    final localId = transport.newSessionId();
    final random = randomBytes(32);
    final eph = EcKeyPair.generate();
    final sigma1 = tlvStruct((w) {
      w.bytes(1, random);
      w.uint(2, localId);
      w.bytes(3, fabric.destinationId(random, peerNodeId));
      w.bytes(4, eph.publicKey);
      writeSessionParams(w, 5);
    });
    final reply = await x.request(SecureOp.sigma1, sigma1);
    if (reply.isStatusReport) {
      final s = reply.statusReport;
      if (s.isBusy) throw _Busy(s.busyDelay);
      if (s.protocolCode == SecureChannelCode.noSharedTrustRoots) throw NotOnFabricException();
      throw MatterException('The device refused the secure connection: ${s.reason}.');
    }
    if (reply.protocolId != Protocols.secureChannel || reply.opcode != SecureOp.sigma2) {
      throw MatterException('The device sent an unexpected message while connecting.');
    }
    final sigma2 = reply.payload;
    final s2 = _struct(sigma2);
    final responderRandom = s2.bytes(1), peerId = s2.integer(2), peerEph = s2.bytes(3), encrypted2 = s2.bytes(4);
    if (responderRandom == null || peerId == null || peerEph == null || encrypted2 == null) {
      throw MatterException('The device sent a broken handshake message.');
    }
    final peerParams = MrpParams.fromTlv(s2[5], plain.peerParams);
    plain.peerParams = peerParams;

    final Uint8List shared, tbe2;
    final ipk = fabric.operationalIpk;
    try {
      shared = eph.sharedSecret(peerEph);
      final s2k = hkdf(shared, [...ipk, ...responderRandom, ...peerEph, ...sha256(sigma1)], 'Sigma2'.codeUnits, 16);
      tbe2 = aesCcmDecrypt(s2k, _sigma2Nonce, encrypted2);
    } on CryptoException {
      _sendStatus(x, SecureChannelCode.invalidParameter);
      throw MatterException('The device failed the security check.');
    }
    final t2 = _struct(tbe2);
    final nocBytes = t2.bytes(1), icacBytes = t2.bytes(2), signature = t2.bytes(3);
    if (nocBytes == null || signature == null) throw MatterException('The device sent a broken handshake message.');
    _checkPeer(fabric, peerNodeId, nocBytes, icacBytes);
    final noc = MatterCertificate.decode(nocBytes);
    final tbs2 = tlvStruct((w) {
      w.bytes(1, nocBytes);
      if (icacBytes != null) w.bytes(2, icacBytes);
      w.bytes(3, peerEph);
      w.bytes(4, eph.publicKey);
    });
    if (!ecdsaVerify(noc.publicKey, tbs2, signature)) {
      _sendStatus(x, SecureChannelCode.invalidParameter);
      throw MatterException('The device failed the security check.');
    }

    final s3k = hkdf(shared, [...ipk, ...sha256([...sigma1, ...sigma2])], 'Sigma3'.codeUnits, 16);
    final ourNoc = fabric.controllerNoc.encode();
    final tbs3 = tlvStruct((w) {
      w.bytes(1, ourNoc);
      w.bytes(3, eph.publicKey);
      w.bytes(4, peerEph);
    });
    final tbe3 = tlvStruct((w) {
      w.bytes(1, ourNoc);
      w.bytes(3, fabric.controllerKey.sign(tbs3));
    });
    final sigma3 = tlvStruct((w) => w.bytes(1, aesCcmEncrypt(s3k, _sigma3Nonce, tbe3)));
    final done = await x.request(SecureOp.sigma3, sigma3);
    if (!done.isStatusReport) throw MatterException('The device sent an unexpected message while connecting.');
    final status = done.statusReport;
    if (!status.ok) {
      if (status.isBusy) throw _Busy(status.busyDelay);
      if (status.protocolCode == SecureChannelCode.noSharedTrustRoots) throw NotOnFabricException();
      throw MatterException('The device refused the secure connection: ${status.reason}.');
    }
    final session = SecureSession.derive(
      plain,
      localId: localId,
      peerId: peerId,
      secret: shared,
      salt: [...ipk, ...sha256([...sigma1, ...sigma2, ...sigma3])],
      peerParams: peerParams,
      localNodeId: fabric.controllerNodeId,
      peerNodeId: peerNodeId,
    );
    ok = true;
    return session;
  } finally {
    x.close();
    if (ok) {
      Timer(const Duration(seconds: 3), plain.close);
    } else {
      plain.close();
    }
  }
}

/// The device must prove it is the node we asked for, on our fabric.
void _checkPeer(MatterFabric fabric, int nodeId, Uint8List nocBytes, Uint8List? icacBytes) {
  try {
    final noc = MatterCertificate.decode(nocBytes);
    var issuerKey = fabric.rootPublicKey;
    if (icacBytes != null) {
      final icac = MatterCertificate.decode(icacBytes);
      if (!icac.isCa || !icac.verifySignature(fabric.rootPublicKey)) throw CertificateException('bad ICAC');
      final f = icac.fabricId;
      if (f != null && f != fabric.fabricId) throw CertificateException('ICAC of another fabric');
      issuerKey = icac.publicKey;
    }
    if (noc.isCa || noc.nodeId != nodeId || noc.fabricId != fabric.fabricId || !noc.verifySignature(issuerKey)) {
      throw CertificateException('NOC does not match');
    }
  } on CertificateException {
    throw MatterException('The device at this address is not the one SmartMenuKJ added.');
  }
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
  throw MatterException('The device sent a broken handshake message.');
}

void _sendStatus(Exchange x, int code) {
  try {
    x.send(SecureOp.statusReport, StatusReport(StatusReport.generalFailure, Protocols.secureChannel, code).encode());
  } catch (_) {}
}
