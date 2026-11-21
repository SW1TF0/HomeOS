import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'tlv.dart';

/// Matter operational certificates (Core spec 6.5).
///
/// Devices store and exchange certificates in a compact TLV form, but the
/// signature covers the X.509 DER form of the same fields, so signing and
/// checking means converting TLV to DER exactly the way every other Matter
/// stack does (Core spec 6.5.x, "canonical" conversion).

class CertificateException implements Exception {
  CertificateException(this.message);
  final String message;
  @override
  String toString() => 'Bad certificate: $message';
}

/// Distinguished name attribute tags (Core spec 6.5.6.1).
class DnTag {
  static const commonName = 1;
  static const nodeId = 17;
  static const firmwareSigningId = 18;
  static const icacId = 19;
  static const rcacId = 20;
  static const fabricId = 21;
  static const caseAuthenticatedTag = 22;
}

/// Key usage bits as Matter stores them.
class KeyUsage {
  static const digitalSignature = 0x01;
  static const keyCertSign = 0x20;
  static const cRLSign = 0x40;
}

/// Extended key usage values: 1 serverAuth, 2 clientAuth.
class KeyPurpose {
  static const serverAuth = 1;
  static const clientAuth = 2;
}

/// Seconds between 1970-01-01 and the Matter epoch, 2000-01-01.
const matterEpochOffset = 946684800;

int matterTime(DateTime t) => t.toUtc().millisecondsSinceEpoch ~/ 1000 - matterEpochOffset;

/// One attribute of a subject or issuer: its tag and value (an int for the
/// Matter ids, a String for the others).
typedef DnAttribute = (int, Object);

class MatterCertificate {
  MatterCertificate({
    required this.serialNumber,
    required this.issuer,
    required this.notBefore,
    required this.notAfter,
    required this.subject,
    required this.publicKey,
    required this.isCa,
    this.pathLength,
    required this.keyUsage,
    this.extendedKeyUsage,
    required this.subjectKeyId,
    required this.authorityKeyId,
    this.futureExtensions = const [],
    List<int>? extensionOrder,
    this.signature,
  }) : extensionOrder = extensionOrder ??
            [1, 2, if (extendedKeyUsage != null) 3, 4, 5, for (var i = 0; i < futureExtensions.length; i++) 6];

  final Uint8List serialNumber;
  final List<DnAttribute> issuer;

  /// Seconds since 2000-01-01 UTC. A [notAfter] of 0 means "never expires".
  final int notBefore;
  final int notAfter;
  final List<DnAttribute> subject;

  /// Uncompressed P-256 point, 65 bytes.
  final Uint8List publicKey;
  final bool isCa;
  final int? pathLength;
  final int keyUsage;
  final List<int>? extendedKeyUsage;
  final Uint8List subjectKeyId;
  final Uint8List authorityKeyId;

  /// Extensions Matter has no TLV field for, kept as their DER encoding.
  final List<Uint8List> futureExtensions;

  /// Extension tags in the order they appear, which the DER form must keep.
  final List<int> extensionOrder;

  /// Raw r || s ECDSA signature over [tbsDer].
  Uint8List? signature;

  static int? _find(List<DnAttribute> dn, int tag) {
    for (final a in dn) {
      if (a.$1 == tag && a.$2 is int) return a.$2 as int;
    }
    return null;
  }

  int? get nodeId => _find(subject, DnTag.nodeId);
  int? get fabricId => _find(subject, DnTag.fabricId);
  int? get rcacId => _find(subject, DnTag.rcacId);
  int? get icacId => _find(subject, DnTag.icacId);

  /// Signs with [issuerKey] (the root's key, or this certificate's own for a root).
  void sign(EcKeyPair issuerKey) => signature = issuerKey.sign(tbsDer());

  bool verifySignature(List<int> issuerPublicKey) {
    final s = signature;
    return s != null && ecdsaVerify(issuerPublicKey, tbsDer(), s);
  }

  // ---- TLV ----------------------------------------------------------------------

  Uint8List encode() {
    final sig = signature;
    if (sig == null) throw CertificateException('not signed');
    return tlvStruct((w) {
      w.bytes(1, serialNumber);
      w.uint(2, 1); // ECDSA with SHA-256
      w.list(3, (w) => _writeDn(w, issuer));
      w.uint(4, notBefore);
      w.uint(5, notAfter);
      w.list(6, (w) => _writeDn(w, subject));
      w.uint(7, 1); // EC public key
      w.uint(8, 1); // prime256v1
      w.bytes(9, publicKey);
      w.list(10, (w) {
        var future = 0;
        for (final tag in extensionOrder) {
          switch (tag) {
            case 1:
              w.struct(1, (w) {
                w.boolean(1, isCa);
                if (pathLength != null) w.uint(2, pathLength!);
              });
            case 2:
              w.uint(2, keyUsage);
            case 3:
              w.array(3, (w) {
                for (final p in extendedKeyUsage ?? const <int>[]) {
                  w.uint(null, p);
                }
              });
            case 4:
              w.bytes(4, subjectKeyId);
            case 5:
              w.bytes(5, authorityKeyId);
            case 6:
              w.bytes(6, futureExtensions[future++]);
          }
        }
      });
      w.bytes(11, sig);
    });
  }

  static void _writeDn(TlvWriter w, List<DnAttribute> dn) {
    for (final (tag, value) in dn) {
      if (value is int) {
        w.uint(tag, value);
      } else {
        w.string(tag, value as String);
      }
    }
  }

  static MatterCertificate decode(List<int> tlv) {
    final Object? v;
    try {
      v = decodeTlv(Uint8List.fromList(tlv));
    } on TlvFormatException catch (e) {
      throw CertificateException(e.message);
    }
    if (v is! TlvStruct) throw CertificateException('not a TLV structure');
    try {
      if (v.integer(2) != 1 || v.integer(7) != 1 || v.integer(8) != 1) {
        throw CertificateException('unsupported algorithm');
      }
      final ext = v[10];
      if (ext is! TlvStruct) throw CertificateException('missing extensions');
      bool? isCa;
      int? pathLength, keyUsage;
      List<int>? eku;
      Uint8List? skid, akid;
      final future = <Uint8List>[];
      final order = <int>[];
      for (final (tag, value) in ext.fields) {
        if (tag == null) continue;
        order.add(tag);
        switch (tag) {
          case 1:
            final bc = value as TlvStruct;
            isCa = bc.boolean(1) ?? false;
            pathLength = bc.integer(2);
          case 2:
            keyUsage = value as int;
          case 3:
            eku = [for (final p in value as List<Object?>) p as int];
          case 4:
            skid = value as Uint8List;
          case 5:
            akid = value as Uint8List;
          case 6:
            future.add(value as Uint8List);
          default:
            throw CertificateException('unknown extension $tag');
        }
      }
      if (isCa == null || keyUsage == null || skid == null || akid == null) {
        throw CertificateException('missing extensions');
      }
      final serial = v.bytes(1), pub = v.bytes(9), sig = v.bytes(11);
      if (serial == null || pub == null || sig == null) throw CertificateException('missing fields');
      return MatterCertificate(
        serialNumber: serial,
        issuer: _readDn(v[3]),
        notBefore: v.integer(4) ?? 0,
        notAfter: v.integer(5) ?? 0,
        subject: _readDn(v[6]),
        publicKey: pub,
        isCa: isCa,
        pathLength: pathLength,
        keyUsage: keyUsage,
        extendedKeyUsage: eku,
        subjectKeyId: skid,
        authorityKeyId: akid,
        futureExtensions: future,
        extensionOrder: order,
        signature: sig,
      );
    } on TypeError {
      throw CertificateException('a field has the wrong type');
    }
  }

  static List<DnAttribute> _readDn(Object? v) {
    if (v is! TlvStruct) throw CertificateException('bad distinguished name');
    final out = <DnAttribute>[];
    for (final (tag, value) in v.fields) {
      if (tag == null || value == null) throw CertificateException('bad distinguished name');
      if (_isMatterId(tag) != (value is int)) throw CertificateException('bad attribute $tag');
      out.add((tag, value));
    }
    return out;
  }

  static bool _isMatterId(int tag) => tag >= 17 && tag <= 22;

  // ---- DER ----------------------------------------------------------------------

  /// The X.509 TBSCertificate that the signature covers.
  Uint8List tbsDer() {
    var future = 0;
    final extensions = <Uint8List>[];
    for (final tag in extensionOrder) {
      switch (tag) {
        case 1:
          extensions.add(_ext(_oidBasicConstraints, true,
              _seq([if (isCa) _bool(true), if (pathLength != null) _integer(pathLength!)])));
        case 2:
          extensions.add(_ext(_oidKeyUsage, true, _bitString(keyUsage)));
        case 3:
          extensions.add(_ext(_oidExtKeyUsage, true, _seq([for (final p in extendedKeyUsage ?? const <int>[]) _oid(_purposeOid(p))])));
        case 4:
          extensions.add(_ext(_oidSubjectKeyId, false, _der(0x04, subjectKeyId)));
        case 5:
          extensions.add(_ext(_oidAuthorityKeyId, false, _seq([_der(0x80, authorityKeyId)])));
        case 6:
          extensions.add(futureExtensions[future++]);
      }
    }
    return _seq([
      _der(0xa0, _integer(2)), // version 3
      // The serial is copied as is, like the reference implementation does.
      _der(0x02, serialNumber),
      _seq([_oid(_oidEcdsaSha256)]),
      _name(issuer),
      _seq([_time(notBefore, false), _time(notAfter, true)]),
      _name(subject),
      spkiDer(publicKey),
      _der(0xa3, _seq(extensions)),
    ]);
  }

  /// The whole certificate as X.509 DER (for tools and tests).
  Uint8List toDer() {
    final sig = signature;
    if (sig == null) throw CertificateException('not signed');
    return _seq([tbsDer(), _seq([_oid(_oidEcdsaSha256)]), _der(0x03, [0, ...rawSignatureToDer(sig)])]);
  }

  static Uint8List _ext(List<int> oid, bool critical, Uint8List value) =>
      _seq([_oid(oid), if (critical) _bool(true), _der(0x04, value)]);

  static Uint8List _name(List<DnAttribute> dn) => _seq([
        for (final (tag, value) in dn) _der(0x31, _seq([_oid(_dnOid(tag)), _dnValue(tag, value)])),
      ]);

  static Uint8List _dnValue(int tag, Object value) {
    if (tag == DnTag.caseAuthenticatedTag) {
      return _der(0x0c, ascii.encode((value as int).toRadixString(16).toUpperCase().padLeft(8, '0')));
    }
    if (_isMatterId(tag)) return _der(0x0c, ascii.encode(hex64(value as int)));
    final s = utf8.encode(value as String);
    if (tag == 16) return _der(0x16, s); // domainComponent is an IA5String
    return _der(tag > 128 ? 0x13 : 0x0c, s); // 129..143: the PrintableString variants
  }

  static List<int> _dnOid(int tag) {
    final t = tag > 128 ? tag - 128 : tag;
    const x520 = {1: 3, 2: 4, 3: 5, 4: 6, 5: 7, 6: 8, 7: 10, 8: 11, 9: 12, 10: 41, 11: 42, 12: 43, 13: 44, 14: 46, 15: 65};
    final id = x520[t];
    if (id != null) return [0x55, 0x04, id];
    if (t == 16) return hexBytes('0992268993f22c640119');
    if (_isMatterId(t)) return [...hexBytes('2b0601040182a27c01'), t - 16];
    throw CertificateException('unknown attribute $tag');
  }

  static Uint8List _time(int t, bool isNotAfter) {
    if (t == 0 && isNotAfter) return _der(0x18, ascii.encode('99991231235959Z'));
    final d = DateTime.fromMillisecondsSinceEpoch((t + matterEpochOffset) * 1000, isUtc: true);
    String two(int v) => v.toString().padLeft(2, '0');
    final rest = '${two(d.month)}${two(d.day)}${two(d.hour)}${two(d.minute)}${two(d.second)}Z';
    if (d.year >= 1950 && d.year <= 2049) return _der(0x17, ascii.encode('${two(d.year % 100)}$rest'));
    return _der(0x18, ascii.encode('${d.year.toString().padLeft(4, '0')}$rest'));
  }

  static List<int> _purposeOid(int p) {
    const last = {1: 1, 2: 2, 3: 3, 4: 4, 5: 8, 6: 9};
    final l = last[p];
    if (l == null) throw CertificateException('unknown key purpose $p');
    return [0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, l];
  }

  /// A BIT STRING the way X.509 writes key usage: bit 0 is the top bit of the first byte.
  static Uint8List _bitString(int v) {
    if (v == 0) return _der(0x03, [0]);
    final bytes = <int>[];
    for (var x = v; x != 0; x >>= 8) {
      var b = x & 0xff, r = 0;
      for (var i = 0; i < 8; i++) {
        r = (r << 1) | ((b >> i) & 1);
      }
      bytes.add(r);
    }
    var unused = 0;
    while ((bytes.last >> unused) & 1 == 0) {
      unused++;
    }
    return _der(0x03, [unused, ...bytes]);
  }
}

// ---- issuing --------------------------------------------------------------------

const _year = 365 * 24 * 3600;

Uint8List _serial() {
  // A positive DER integer with no leading zero, so every stack reads it the same way.
  final s = randomBytes(8);
  s[0] = 1 + s[0] % 0x7f;
  return s;
}

/// A self-signed root certificate for a new fabric.
MatterCertificate issueRootCertificate(EcKeyPair rootKey, {required int rcacId, DateTime? now}) {
  final t = matterTime(now ?? DateTime.now());
  final skid = sha1(rootKey.publicKey);
  final dn = <DnAttribute>[(DnTag.rcacId, rcacId)];
  return MatterCertificate(
    serialNumber: _serial(),
    issuer: dn,
    notBefore: t - _year,
    notAfter: t + 10 * _year,
    subject: dn,
    publicKey: rootKey.publicKey,
    isCa: true,
    keyUsage: KeyUsage.keyCertSign | KeyUsage.cRLSign,
    subjectKeyId: skid,
    authorityKeyId: skid,
  )..sign(rootKey);
}

/// A node operational certificate for [publicKey], signed by the root.
MatterCertificate issueNodeCertificate({
  required EcKeyPair rootKey,
  required MatterCertificate root,
  required List<int> publicKey,
  required int nodeId,
  required int fabricId,
  DateTime? now,
}) {
  final t = matterTime(now ?? DateTime.now());
  return MatterCertificate(
    serialNumber: _serial(),
    issuer: root.subject,
    notBefore: t - _year,
    notAfter: t + 10 * _year,
    subject: [(DnTag.nodeId, nodeId), (DnTag.fabricId, fabricId)],
    publicKey: Uint8List.fromList(publicKey),
    isCa: false,
    keyUsage: KeyUsage.digitalSignature,
    extendedKeyUsage: const [KeyPurpose.clientAuth, KeyPurpose.serverAuth],
    subjectKeyId: sha1(publicKey),
    authorityKeyId: root.subjectKeyId,
  )..sign(rootKey);
}

// ---- CSR ----------------------------------------------------------------------

/// The public key from a device's PKCS#10 certificate signing request, after
/// checking the request is signed by the matching private key.
Uint8List publicKeyFromCsr(List<int> csr) {
  try {
    final root = _DerNode.parse(Uint8List.fromList(csr));
    final parts = root.children;
    if (root.tag != 0x30 || parts.length != 3) throw CertificateException('CSR is not a sequence of 3');
    final info = parts[0];
    final fields = info.children;
    if (info.tag != 0x30 || fields.length < 3) throw CertificateException('bad CSR info');
    if (fields[0].tag != 0x02 || fields[0].content.length != 1 || fields[0].content[0] != 0) {
      throw CertificateException('unsupported CSR version');
    }
    final spki = fields[2].children;
    final algorithm = spki[0].children;
    if (!bytesEqual(algorithm[0].content, _oidEcPublicKey) || !bytesEqual(algorithm[1].content, _oidPrime256v1)) {
      throw CertificateException('CSR key is not P-256');
    }
    final bits = spki[1];
    if (bits.tag != 0x03 || bits.content.isEmpty || bits.content[0] != 0) throw CertificateException('bad CSR key');
    final publicKey = Uint8List.fromList(bits.content.sublist(1));
    final alg = parts[1].children;
    if (alg.isEmpty || !bytesEqual(alg[0].content, _oidEcdsaSha256)) throw CertificateException('CSR not signed with ECDSA-SHA256');
    final sig = parts[2];
    if (sig.tag != 0x03 || sig.content.isEmpty || sig.content[0] != 0) throw CertificateException('bad CSR signature');
    final raw = derSignatureToRaw(sig.content.sublist(1));
    if (!ecdsaVerify(publicKey, info.raw, raw)) throw CertificateException('CSR signature does not match');
    return publicKey;
  } on RangeError {
    throw CertificateException('CSR is truncated');
  } on CryptoException catch (e) {
    throw CertificateException(e.message);
  }
}

/// A CSR for [key], the way devices make them (subject O=CSR). Used by tests.
Uint8List makeCsr(EcKeyPair key) {
  final info = _seq([
    _integer(0),
    _seq([
      _der(0x31, _seq([_oid([0x55, 0x04, 0x0a]), _der(0x0c, ascii.encode('CSR'))]))
    ]),
    spkiDer(key.publicKey),
    _der(0xa0, const []),
  ]);
  return _seq([info, _seq([_oid(_oidEcdsaSha256)]), _der(0x03, [0, ...rawSignatureToDer(key.sign(info))])]);
}

/// SubjectPublicKeyInfo for a P-256 key.
Uint8List spkiDer(List<int> publicKey) =>
    _seq([_seq([_oid(_oidEcPublicKey), _oid(_oidPrime256v1)]), _der(0x03, [0, ...publicKey])]);

/// Raw r || s as DER `SEQUENCE { INTEGER r, INTEGER s }`.
Uint8List rawSignatureToDer(List<int> raw) {
  Uint8List integer(List<int> v) {
    var i = 0;
    while (i < v.length - 1 && v[i] == 0) {
      i++;
    }
    final t = v.sublist(i);
    return _der(0x02, t[0] & 0x80 != 0 ? [0, ...t] : t);
  }

  return _seq([integer(raw.sublist(0, 32)), integer(raw.sublist(32, 64))]);
}

const _oidEcdsaSha256 = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02];
const _oidEcPublicKey = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01];
const _oidPrime256v1 = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07];
const _oidBasicConstraints = [0x55, 0x1d, 0x13];
const _oidKeyUsage = [0x55, 0x1d, 0x0f];
const _oidExtKeyUsage = [0x55, 0x1d, 0x25];
const _oidSubjectKeyId = [0x55, 0x1d, 0x0e];
const _oidAuthorityKeyId = [0x55, 0x1d, 0x23];

Uint8List _der(int tag, List<int> content) {
  final n = content.length;
  final List<int> len;
  if (n < 0x80) {
    len = [n];
  } else if (n < 0x100) {
    len = [0x81, n];
  } else if (n < 0x10000) {
    len = [0x82, n >> 8, n & 0xff];
  } else {
    len = [0x83, n >> 16, (n >> 8) & 0xff, n & 0xff];
  }
  return Uint8List.fromList([tag, ...len, ...content]);
}

Uint8List _seq(Iterable<List<int>> items) => _der(0x30, concatBytes(items));
Uint8List _oid(List<int> oid) => _der(0x06, oid);
Uint8List _bool(bool v) => _der(0x01, [v ? 0xff : 0]);

Uint8List _integer(int v) {
  final bytes = <int>[];
  var x = v;
  do {
    bytes.insert(0, x & 0xff);
    x >>= 8;
  } while (x != 0);
  if (bytes[0] & 0x80 != 0) bytes.insert(0, 0);
  return _der(0x02, bytes);
}

/// A minimal DER reader, enough for a CSR.
class _DerNode {
  _DerNode(this.tag, this.raw, this.content);

  final int tag;
  final Uint8List raw;
  final Uint8List content;

  static _DerNode parse(Uint8List d, [int at = 0]) {
    final tag = d[at];
    var i = at + 1;
    var len = d[i++];
    if (len & 0x80 != 0) {
      final n = len & 0x7f;
      if (n == 0 || n > 3) throw CertificateException('bad DER length');
      len = 0;
      for (var k = 0; k < n; k++) {
        len = (len << 8) | d[i++];
      }
    }
    if (i + len > d.length) throw RangeError('DER element runs past the end');
    return _DerNode(tag, Uint8List.sublistView(d, at, i + len), Uint8List.sublistView(d, i, i + len));
  }

  List<_DerNode> get children {
    final out = <_DerNode>[];
    var at = 0;
    while (at < content.length) {
      final n = parse(content, at);
      out.add(n);
      at += n.raw.length;
    }
    return out;
  }
}
