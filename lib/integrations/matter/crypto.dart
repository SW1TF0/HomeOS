import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// The cryptography Matter needs (Core spec chapter 3), on top of pointycastle:
/// SHA-256, HMAC, HKDF, PBKDF2, AES-128-CCM and NIST P-256.

final _rng = Random.secure();

Uint8List randomBytes(int n) => Uint8List.fromList(List.generate(n, (_) => _rng.nextInt(256)));

/// A random number in [min, max] (both at most 32 bits apart).
int randomIn(int min, int max) => min + _rng.nextInt(max - min + 1);

Uint8List concatBytes(Iterable<List<int>> parts) {
  final b = BytesBuilder(copy: false);
  for (final p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// Compares in constant time (for MACs and confirmation values).
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

String hexOf(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

Uint8List hexBytes(String hex) {
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  return Uint8List.fromList(
      [for (var i = 0; i + 1 < clean.length; i += 2) int.parse(clean.substring(i, i + 2), radix: 16)]);
}

/// A 64-bit value as 16 upper-case hex digits (node and fabric ids). Values
/// above 2^63 are Dart ints with the same bits, which this handles.
String hex64(int v) =>
    (v >>> 32).toRadixString(16).padLeft(8, '0').toUpperCase() +
    (v & 0xffffffff).toRadixString(16).padLeft(8, '0').toUpperCase();

int parseHex64(String s) {
  final t = s.trim().padLeft(16, '0');
  if (t.length != 16) throw FormatException('Not a 64-bit hex value: $s');
  return (int.parse(t.substring(0, 8), radix: 16) << 32) | int.parse(t.substring(8), radix: 16);
}

Uint8List le64(int v) => Uint8List.fromList([for (var i = 0; i < 8; i++) (v >>> (8 * i)) & 0xff]);
Uint8List be64(int v) => Uint8List.fromList([for (var i = 7; i >= 0; i--) (v >>> (8 * i)) & 0xff]);

int beToInt(List<int> b) {
  var v = 0;
  for (final x in b) {
    v = (v << 8) | x;
  }
  return v;
}

Uint8List sha256(List<int> data) => SHA256Digest().process(Uint8List.fromList(data));
Uint8List sha1(List<int> data) => SHA1Digest().process(Uint8List.fromList(data));

Uint8List hmacSha256(List<int> key, List<int> data) {
  final mac = HMac(SHA256Digest(), 64)..init(KeyParameter(Uint8List.fromList(key)));
  return mac.process(Uint8List.fromList(data));
}

/// HKDF-SHA256 (RFC 5869). An empty [salt] means 32 zero bytes, as the RFC says.
Uint8List hkdf(List<int> ikm, List<int> salt, List<int> info, int length) {
  final prk = hmacSha256(salt.isEmpty ? Uint8List(32) : salt, ikm);
  final out = BytesBuilder();
  var t = Uint8List(0);
  for (var i = 1; out.length < length; i++) {
    t = hmacSha256(prk, [...t, ...info, i]);
    out.add(t);
  }
  return Uint8List.sublistView(out.toBytes(), 0, length);
}

/// PBKDF2-HMAC-SHA256. Slow on purpose; run it off the UI isolate.
Uint8List pbkdf2(List<int> password, List<int> salt, int iterations, int length) {
  final d = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))
    ..init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, length));
  return d.process(Uint8List.fromList(password));
}

class CryptoException implements Exception {
  CryptoException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// AES-128-CCM with a 16-byte tag (RFC 3610). Returns ciphertext followed by the tag.
Uint8List aesCcmEncrypt(List<int> key, List<int> nonce, List<int> plaintext, [List<int> aad = const []]) {
  final aes = AESEngine()..init(true, KeyParameter(Uint8List.fromList(key)));
  final p = Uint8List.fromList(plaintext);
  final tag = _cbcMac(aes, nonce, p, aad);
  final out = Uint8List(p.length + 16);
  _ctr(aes, nonce, p, out);
  final s0 = _counterBlock(aes, nonce, 0);
  for (var i = 0; i < 16; i++) {
    out[p.length + i] = tag[i] ^ s0[i];
  }
  return out;
}

/// Opens AES-128-CCM data made by [aesCcmEncrypt]. Throws when the tag does not match.
Uint8List aesCcmDecrypt(List<int> key, List<int> nonce, List<int> sealed, [List<int> aad = const []]) {
  if (sealed.length < 16) throw CryptoException('Message too short.');
  final aes = AESEngine()..init(true, KeyParameter(Uint8List.fromList(key)));
  final c = Uint8List.fromList(sealed.sublist(0, sealed.length - 16));
  final p = Uint8List(c.length);
  _ctr(aes, nonce, c, p);
  final s0 = _counterBlock(aes, nonce, 0);
  final expected = _cbcMac(aes, nonce, p, aad);
  var diff = 0;
  for (var i = 0; i < 16; i++) {
    diff |= expected[i] ^ s0[i] ^ sealed[c.length + i];
  }
  if (diff != 0) throw CryptoException('Message failed its integrity check.');
  return p;
}

Uint8List _cbcMac(AESEngine aes, List<int> nonce, Uint8List p, List<int> aad) {
  final l = 15 - nonce.length;
  final b0 = Uint8List(16);
  b0[0] = (aad.isNotEmpty ? 0x40 : 0) | (((16 - 2) ~/ 2) << 3) | (l - 1);
  b0.setRange(1, 1 + nonce.length, nonce);
  for (var i = 0; i < l; i++) {
    b0[15 - i] = (p.length >> (8 * i)) & 0xff;
  }
  final x = Uint8List(16);
  aes.processBlock(b0, 0, x, 0);
  final block = Uint8List(16);
  void absorb(List<int> data) {
    for (var off = 0; off < data.length; off += 16) {
      for (var i = 0; i < 16; i++) {
        block[i] = (off + i < data.length ? data[off + i] : 0) ^ x[i];
      }
      aes.processBlock(block, 0, x, 0);
    }
  }

  if (aad.isNotEmpty) absorb([(aad.length >> 8) & 0xff, aad.length & 0xff, ...aad]);
  absorb(p);
  return x;
}

Uint8List _counterBlock(AESEngine aes, List<int> nonce, int i) {
  final l = 15 - nonce.length;
  final a = Uint8List(16);
  a[0] = l - 1;
  a.setRange(1, 1 + nonce.length, nonce);
  for (var k = 0; k < l; k++) {
    a[15 - k] = (i >> (8 * k)) & 0xff;
  }
  final s = Uint8List(16);
  aes.processBlock(a, 0, s, 0);
  return s;
}

void _ctr(AESEngine aes, List<int> nonce, Uint8List input, Uint8List output) {
  for (var off = 0, i = 1; off < input.length; off += 16, i++) {
    final s = _counterBlock(aes, nonce, i);
    for (var k = 0; k < 16 && off + k < input.length; k++) {
      output[off + k] = input[off + k] ^ s[k];
    }
  }
}

// ---- P-256 --------------------------------------------------------------------

final ECDomainParameters p256 = ECCurve_secp256r1();

final _p = BigInt.parse('ffffffff00000001000000000000000000000000ffffffffffffffffffffffff', radix: 16);
final _b = BigInt.parse('5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b', radix: 16);

BigInt bigFromBytes(List<int> bytes) {
  var v = BigInt.zero;
  for (final b in bytes) {
    v = (v << 8) | BigInt.from(b);
  }
  return v;
}

Uint8List bigToBytes(BigInt v, int length) {
  final out = Uint8List(length);
  var x = v;
  for (var i = length - 1; i >= 0; i--) {
    out[i] = (x & BigInt.from(0xff)).toInt();
    x = x >> 8;
  }
  return out;
}

/// Decodes a compressed or uncompressed point and checks it is on the curve.
ECPoint decodePoint(List<int> bytes) {
  final ECPoint? p;
  try {
    p = p256.curve.decodePoint(Uint8List.fromList(bytes));
  } on ArgumentError {
    throw CryptoException('Not a valid P-256 point.');
  }
  if (p == null || p.isInfinity) throw CryptoException('Not a valid P-256 point.');
  final x = p.x!.toBigInteger()!, y = p.y!.toBigInteger()!;
  if (x >= _p || y >= _p || (y * y - (x * x * x - BigInt.from(3) * x + _b)) % _p != BigInt.zero) {
    throw CryptoException('Not a valid P-256 point.');
  }
  return p;
}

Uint8List encodePoint(ECPoint p) => p.getEncoded(false);

/// A random scalar in [1, n).
BigInt randomScalar() {
  while (true) {
    final k = bigFromBytes(randomBytes(32));
    if (k > BigInt.zero && k < p256.n) return k;
  }
}

/// A P-256 key pair. [publicKey] is the 65-byte uncompressed point.
class EcKeyPair {
  EcKeyPair(this.d) : publicKey = encodePoint((p256.G * d)!);

  factory EcKeyPair.generate() => EcKeyPair(randomScalar());

  factory EcKeyPair.fromPrivate(List<int> privateKey) => EcKeyPair(bigFromBytes(privateKey));

  final BigInt d;
  final Uint8List publicKey;

  Uint8List get privateKey => bigToBytes(d, 32);

  /// ECDSA with SHA-256 (deterministic, RFC 6979); the signature is r and s, 32 bytes each.
  Uint8List sign(List<int> message) {
    final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64))
      ..init(true, PrivateKeyParameter<ECPrivateKey>(ECPrivateKey(d, p256)));
    final sig = signer.generateSignature(Uint8List.fromList(message)) as ECSignature;
    return concatBytes([bigToBytes(sig.r, 32), bigToBytes(sig.s, 32)]);
  }

  /// The ECDH shared secret with [peerPublicKey]: the x coordinate, 32 bytes.
  Uint8List sharedSecret(List<int> peerPublicKey) {
    final s = (decodePoint(peerPublicKey) * d)!;
    if (s.isInfinity) throw CryptoException('Bad key agreement.');
    return bigToBytes(s.x!.toBigInteger()!, 32);
  }
}

/// Checks a raw r||s ECDSA-SHA256 [signature] of [message].
bool ecdsaVerify(List<int> publicKey, List<int> message, List<int> signature) {
  if (signature.length != 64) return false;
  try {
    final signer = ECDSASigner(SHA256Digest())
      ..init(false, PublicKeyParameter<ECPublicKey>(ECPublicKey(decodePoint(publicKey), p256)));
    return signer.verifySignature(Uint8List.fromList(message),
        ECSignature(bigFromBytes(signature.sublist(0, 32)), bigFromBytes(signature.sublist(32))));
  } catch (_) {
    return false;
  }
}

/// Turns a DER `SEQUENCE { INTEGER r, INTEGER s }` signature into raw r||s.
Uint8List derSignatureToRaw(List<int> der) {
  var i = 0;
  int length() {
    final first = der[i++];
    if (first < 0x80) return first;
    var n = 0;
    for (var k = 0; k < (first & 0x7f); k++) {
      n = (n << 8) | der[i++];
    }
    return n;
  }

  Uint8List integer() {
    if (der[i++] != 0x02) throw CryptoException('Bad signature.');
    final len = length();
    var v = der.sublist(i, i + len);
    i += len;
    while (v.length > 32 && v.first == 0) {
      v = v.sublist(1);
    }
    if (v.length > 32) throw CryptoException('Bad signature.');
    return Uint8List(32)..setRange(32 - v.length, 32, v);
  }

  try {
    if (der[i++] != 0x30) throw CryptoException('Bad signature.');
    length();
    return concatBytes([integer(), integer()]);
  } on RangeError {
    throw CryptoException('Bad signature.');
  }
}
