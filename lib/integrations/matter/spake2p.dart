import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/ecc/api.dart';

import 'crypto.dart';

/// SPAKE2+ over P-256 as Matter uses it for PASE (Core spec 3.10). The app is
/// the prover (it knows the passcode); [Spake2pVerifier] plays the device in tests.

final _m = decodePoint(hexBytes('02886e2f97ace46e55ba9dd7242579f2993b64e16ef3dcab95afd497333d8fa12f'));
final _n = decodePoint(hexBytes('03d8bbd6c639c62937b04d997f38c3770719c629d7014d49a24b4f98baa1292b49'));

/// w0 and w1 from the passcode: PBKDF2 of its 4 little-endian bytes, 80 bytes,
/// each half reduced mod n. Returned as 64 bytes (w0 || w1) so it can cross isolates.
Uint8List spakeW0W1(int passcode, List<int> salt, int iterations) {
  final pin = Uint8List(4)..buffer.asByteData().setUint32(0, passcode, Endian.little);
  final ws = pbkdf2(pin, salt, iterations, 80);
  final w0 = bigFromBytes(ws.sublist(0, 40)) % p256.n;
  final w1 = bigFromBytes(ws.sublist(40, 80)) % p256.n;
  return concatBytes([bigToBytes(w0, 32), bigToBytes(w1, 32)]);
}

/// The keys both sides agree on.
class SpakeResult {
  SpakeResult(this.ke, this.cA, this.cB);

  /// Shared secret the session keys come from.
  final Uint8List ke;

  /// The prover's confirmation, sent in Pake3 (HMAC(KcA, Y)).
  final Uint8List cA;

  /// The verifier's confirmation, sent in Pake2 (HMAC(KcB, X)).
  final Uint8List cB;
}

SpakeResult _keys(List<int> context, ECPoint x, ECPoint y, ECPoint z, ECPoint v, BigInt w0) {
  final tt = BytesBuilder();
  void add(List<int> data) {
    tt.add(le64(data.length));
    tt.add(data);
  }

  final xBytes = encodePoint(x), yBytes = encodePoint(y);
  add(context);
  add(const []);
  add(const []);
  add(encodePoint(_m));
  add(encodePoint(_n));
  add(xBytes);
  add(yBytes);
  add(encodePoint(z));
  add(encodePoint(v));
  add(bigToBytes(w0, 32));
  final hash = sha256(tt.toBytes());
  final kc = hkdf(hash.sublist(0, 16), const [], utf8.encode('ConfirmationKeys'), 32);
  return SpakeResult(
    Uint8List.fromList(hash.sublist(16, 32)),
    hmacSha256(kc.sublist(0, 16), yBytes),
    hmacSha256(kc.sublist(16, 32), xBytes),
  );
}

class Spake2pProver {
  /// [w0w1] is what [spakeW0W1] returns. [x] is only fixed by tests.
  Spake2pProver(this.context, Uint8List w0w1, [BigInt? x])
      : w0 = bigFromBytes(w0w1.sublist(0, 32)),
        w1 = bigFromBytes(w0w1.sublist(32, 64)),
        x = x ?? randomScalar() {
    _share = ((p256.G * this.x)! + (_m * w0)!)!;
  }

  /// SHA-256 of "CHIP PAKE V1 Commissioning" and the two PBKDF messages.
  final Uint8List context;
  final BigInt w0;
  final BigInt w1;
  final BigInt x;
  late final ECPoint _share;

  /// pA, sent in Pake1.
  Uint8List get shareX => encodePoint(_share);

  /// Works out the shared keys from the device's share pB (Y).
  SpakeResult finish(List<int> shareY) {
    final y = decodePoint(shareY);
    final yMinusN = (y - (_n * w0)!)!;
    return _keys(context, _share, y, (yMinusN * x)!, (yMinusN * w1)!, w0);
  }
}

/// The device's side, from w0 and L = w1*G.
class Spake2pVerifier {
  Spake2pVerifier(this.context, Uint8List w0w1, [BigInt? y])
      : w0 = bigFromBytes(w0w1.sublist(0, 32)),
        l = (p256.G * bigFromBytes(w0w1.sublist(32, 64)))!,
        y = y ?? randomScalar() {
    _share = ((p256.G * this.y)! + (_n * w0)!)!;
  }

  final Uint8List context;
  final BigInt w0;
  final ECPoint l;
  final BigInt y;
  late final ECPoint _share;

  /// pB, sent in Pake2.
  Uint8List get shareY => encodePoint(_share);

  SpakeResult finish(List<int> shareX) {
    final x = decodePoint(shareX);
    final xMinusM = (x - (_m * w0)!)!;
    return _keys(context, x, _share, (xMinusM * y)!, (l * y)!, w0);
  }
}

/// The context hash that binds SPAKE2+ to this PASE exchange.
Uint8List spakeContext(List<int> pbkdfRequest, List<int> pbkdfResponse) =>
    sha256([...utf8.encode('CHIP PAKE V1 Commissioning'), ...pbkdfRequest, ...pbkdfResponse]);
