// The Matter cryptography against outside references: RFC test vectors, the
// Matter specification's own vectors, and values made by Node's crypto and by
// matter.js (tool/matter/vectors.mjs prints them). A few extra checks hand our
// certificates to Node and matter.js; they skip themselves when those are not
// installed.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartmenukj/integrations/matter/certs.dart';
import 'package:smartmenukj/integrations/matter/crypto.dart';
import 'package:smartmenukj/integrations/matter/fabric.dart';
import 'package:smartmenukj/integrations/matter/session.dart';
import 'package:smartmenukj/integrations/matter/spake2p.dart';

Uint8List _h(String hex) => hexBytes(hex);

// ---- vectors made by matter.js (CertificateAuthority, Certificate) ----------------

const _matterJsRcac =
    '15300101002402013703241400182604844584302605047c31453706241400182407012408013009410481777df2453e716e7811a5bd'
    '2106ea7e25ce62da769e64957e034c069fd4a3cc10f172627cdfa9c4c2d62e498da4de916c42bcfbce54ca7d5a8f2843fe9bfcd137'
    '0a35012901182402603004147c28740486c8c3cf1c2832b6dff7cad56fae8de93005147c28740486c8c3cf1c2832b6dff7cad56fae'
    '8de918300b40946ec5d4e66ecfbacd8f7cbc2f106ce841eee8eb5351da143d2295aba3fafae05f51d9137dcfd95a87e1d66dcfb5989d'
    '6e4ce8ef94ead5a407e14870f9b9797918';
const _matterJsRcacTbs =
    '3082013ca003020102020100300a06082a8648ce3d04030230223120301e060a2b0601040182a27c01040c10303030303030303030303030'
    '30303030301e170d3235313031373030303833365a170d3336313031343030303833365a30223120301e060a2b0601040182a27c01040c10'
    '303030303030303030303030303030303059301306072a8648ce3d020106082a8648ce3d0301070342000481777df2453e716e7811a5bd21'
    '06ea7e25ce62da769e64957e034c069fd4a3cc10f172627cdfa9c4c2d62e498da4de916c42bcfbce54ca7d5a8f2843fe9bfcd1a363306130'
    '0f0603551d130101ff040530030101ff300e0603551d0f0101ff040403020106301d0603551d0e041604147c28740486c8c3cf1c2832b6df'
    'f7cad56fae8de9301f0603551d230418301680147c28740486c8c3cf1c2832b6dff7cad56fae8de9';
const _matterJsRcacSignatureDer =
    '300a06082a8648ce3d0403020348003045022100946ec5d4e66ecfbacd8f7cbc2f106ce841eee8eb5351da143d2295aba3fafae00220'
    '5f51d9137dcfd95a87e1d66dcfb5989d6e4ce8ef94ead5a407e14870f9b97979';
const _matterJsNoc =
    '15300101012402013703241400182604844584302605047c3145370627158877665544332211241142182407012408013009410411'
    '82f63c4dc6db0317af13fdd8dc6e2edf66d408b32584a9f9132ab96110c2e4ee34c15c329ca65ae08d77ba9c244f450c7d538a28145c'
    '49e14640df24ec6cac370a3501280118240201360304020401183004147183964044f9ef04b3f2186e92eb875a1e5e1d5a3005147c287404'
    '86c8c3cf1c2832b6dff7cad56fae8de918300b40b488e4e272825a5ab604987247d966c591f1808bf5ae4916b1649db2c4cff2f266b312'
    '3ec404af9ea0db7fc40c7d43c6b76cf34d9be96df9d2893fc86f88dd3a18';
const _matterJsNocTbs =
    '3082017fa003020102020101300a06082a8648ce3d04030230223120301e060a2b0601040182a27c01040c10303030303030303030303030'
    '30303030301e170d3235313031373030303833365a170d3336313031343030303833365a30443120301e060a2b0601040182a27c01050c10'
    '313132323333343435353636373738383120301e060a2b0601040182a27c01010c1030303030303030303030303030303432305930130607'
    '2a8648ce3d020106082a8648ce3d030107034200041182f63c4dc6db0317af13fdd8dc6e2edf66d408b32584a9f9132ab96110c2e4ee34c1'
    '5c329ca65ae08d77ba9c244f450c7d538a28145c49e14640df24ec6caca38183308180300c0603551d130101ff04023000300e0603551d0f'
    '0101ff04040302078030200603551d250101ff0416301406082b0601050507030206082b06010505070301301d0603551d0e041604147183'
    '964044f9ef04b3f2186e92eb875a1e5e1d5a301f0603551d230418301680147c28740486c8c3cf1c2832b6dff7cad56fae8de9';
const _matterJsNocPublicKey =
    '041182f63c4dc6db0317af13fdd8dc6e2edf66d408b32584a9f9132ab96110c2e4ee34c15c329ca65ae08d77ba9c244f450c7d538a2814'
    '5c49e14640df24ec6cac';
const _matterJsCsr =
    '3081c73070020100300e310c300a060355040a0c034353523059301306072a8648ce3d020106082a8648ce3d030107034200049db4f2b3'
    '0dcbab66a55baf8b2a4fa5683356451add14d203d70194e05707242947bde591d8fe44fb9a744c9ef2e2231361de185cc698bfe9dba4e4'
    '41dfd65561a000300a06082a8648ce3d040302034700304402205f9000f9ccc0b66ee76fea2535d85b2c3462260a656317acfab319b839'
    '6ac59202207dd34c8339564ff444ba6aecebd704af502c89fcc73755c51932403f83c47128';
const _matterJsCsrPublicKey =
    '049db4f2b30dcbab66a55baf8b2a4fa5683356451add14d203d70194e05707242947bde591d8fe44fb9a744c9ef2e2231361de185cc698'
    'bfe9dba4e441dfd65561';

// ---- running Node for the extra checks ------------------------------------------

final _simDir = Platform.environment['MATTER_SIM_DIR'] ?? 'tool/matter';

String? _noNode() {
  try {
    return Process.runSync('node', ['--version']).exitCode == 0 ? null : 'node does not run';
  } on ProcessException {
    return 'node is not installed';
  }
}

String? _noMatterJs() =>
    _noNode() ?? (Directory('$_simDir/node_modules/@matter/main').existsSync() ? null : 'matter.js is not in $_simDir');

/// Runs [script] with Node and returns what it printed last, as JSON.
Future<Map<String, dynamic>> _node(String script, Map<String, String> env, {bool module = false}) async {
  final r = await Process.run('node', [if (module) '--input-type=module', '-e', script],
      environment: env, workingDirectory: module ? _simDir : null);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  final lines = (r.stdout as String).trim().split('\n');
  return jsonDecode(lines.last) as Map<String, dynamic>;
}

MatterCertificate _unsignedRootWithKey(List<int> publicKey) => MatterCertificate(
      serialNumber: Uint8List.fromList([1]),
      issuer: const [(DnTag.rcacId, 1)],
      notBefore: 0,
      notAfter: 0,
      subject: const [(DnTag.rcacId, 1)],
      publicKey: Uint8List.fromList(publicKey),
      isCa: true,
      keyUsage: KeyUsage.keyCertSign | KeyUsage.cRLSign,
      subjectKeyId: Uint8List(20),
      authorityKeyId: Uint8List(20),
    );

void main() {
  group('AES-128-CCM (vectors from Node)', () {
    const vectors = [
      (
        key: '000102030405060708090a0b0c0d0e0f',
        nonce: '101112131415161718191a1b1c',
        pt: '',
        aad: '',
        ct: 'd5e7b9742adec972909274ecbe50c0c9',
      ),
      (
        key: '5eded244e2a6ad4ad3d1f6b49f28fa0a',
        nonce: '00010203040506070809101112',
        pt: '48656c6c6f204d6174746572',
        aad: '0011223344',
        ct: '1db70ba237740cc148a5ffebc49ef70ded24b909fc9c474bb47f0957',
      ),
      (
        key: 'c0c1c2c3c4c5c6c7c8c9cacbcccdcecf',
        nonce: '4e434153455f5369676d61324e',
        pt: '1530014c0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f'
            '3031323334353637',
        aad: '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d',
        ct: '96d56719371b7f779a413dcdf01555866943cecd4d4038c415690c09d1e014da1a51ea8a51aaa4190c5ef3e59e0789af97837c95'
            '84cb95c38fe710dc75afe1343a7805a431cc6cb7e366a3',
      ),
    ];
    for (final v in vectors) {
      test('${v.pt.length ~/ 2} bytes with ${v.aad.length ~/ 2} bytes of header', () {
        final sealed = aesCcmEncrypt(_h(v.key), _h(v.nonce), _h(v.pt), _h(v.aad));
        expect(hexOf(sealed), v.ct);
        expect(hexOf(aesCcmDecrypt(_h(v.key), _h(v.nonce), sealed, _h(v.aad))), v.pt);
      });
    }

    test('refuses changed data, a changed header and a short message', () {
      final v = vectors[1];
      final flipped = _h(v.ct)..[3] ^= 0x01;
      expect(() => aesCcmDecrypt(_h(v.key), _h(v.nonce), flipped, _h(v.aad)), throwsA(isA<CryptoException>()));
      expect(() => aesCcmDecrypt(_h(v.key), _h(v.nonce), _h(v.ct), _h('0011223345')), throwsA(isA<CryptoException>()));
      expect(() => aesCcmDecrypt(_h(v.key), _h(v.nonce), Uint8List(15)), throwsA(isA<CryptoException>()));
    });
  });

  group('key derivation', () {
    test('HKDF-SHA256: RFC 5869 test case 1', () {
      final okm = hkdf(List.filled(22, 0x0b), _h('000102030405060708090a0b0c'), _h('f0f1f2f3f4f5f6f7f8f9'), 42);
      expect(hexOf(okm), '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865');
    });

    test('HKDF-SHA256 as Matter uses it (vectors from Node)', () {
      expect(hexOf(hkdf(List.filled(22, 0x0b), const [], utf8.encode('SessionKeys'), 48)),
          '402edeeff8a1d1e85d8ae4ef0fafb88b748ad9ee3d34d46178294480f5787377b1b0ba16d874902e40fbc743abeda5d7');
      expect(hexOf(hkdf(_h('000102030405060708090a0b0c0d0e0f'), _h('a0a1a2a3a4a5a6a7'), utf8.encode('CompressedFabric'), 8)),
          '68cbb0cf3dcb9207');
      expect(hexOf(hkdf(_h('deadbeef'), _h('0102'), utf8.encode('Sigma2'), 16)), '247ef27bd6d0b35d9ce712da0f4352a4');
    });

    test('PBKDF2-HMAC-SHA256 (vectors from Node)', () {
      expect(hexOf(pbkdf2(_h('15cd0c00'), _h('5350414b453250204b65792053616c74'), 1000, 80)),
          'af09892bb5865c0c42b7a5c700e6180adc19d09da85d1e4d5c0365a19f249c581f606cf3689e32c39048049a6190a7243a3153ea2f35'
          '5ff0c170a52f091cd482572c056cdb7bcb6c803ba09a2ecb95ee');
      expect(hexOf(pbkdf2(_h('15cd0c00'), _h('0102030405060708090a0b0c0d0e0f10'), 2000, 80)),
          '8f83df76ef350d5a2d355a9d73d6005cc5b50b431fb938c475a50a40bca2fb0b16b2db29028a9ff153a7ba6108cc3330318463f62774'
          'd7b9b01e4aac9c920277691da494ace370424b9118dedd2e2d5d');
    });

    test('SHA-256 and HMAC-SHA256 (RFC 4231 test case 2)', () {
      expect(hexOf(sha256(utf8.encode('abc'))), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
      expect(hexOf(hmacSha256(utf8.encode('Jefe'), utf8.encode('what do ya want for nothing?'))),
          '5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843');
    });
  });

  group('P-256', () {
    test('signatures verify, and fail for other data or keys', () {
      final key = EcKeyPair.generate();
      final sig = key.sign(utf8.encode('hello'));
      expect(sig, hasLength(64));
      expect(ecdsaVerify(key.publicKey, utf8.encode('hello'), sig), isTrue);
      expect(ecdsaVerify(key.publicKey, utf8.encode('hellp'), sig), isFalse);
      expect(ecdsaVerify(EcKeyPair.generate().publicKey, utf8.encode('hello'), sig), isFalse);
      expect(derSignatureToRaw(rawSignatureToDer(sig)), sig);
    });

    test('both sides of a key agreement get the same secret', () {
      final a = EcKeyPair.generate(), b = EcKeyPair.generate();
      expect(a.sharedSecret(b.publicKey), b.sharedSecret(a.publicKey));
      expect(EcKeyPair.fromPrivate(a.privateKey).publicKey, a.publicKey);
    });

    test('points that are not on the curve are refused', () {
      final bad = Uint8List.fromList(EcKeyPair.generate().publicKey)..[64] ^= 0x01;
      expect(() => decodePoint(bad), throwsA(isA<CryptoException>()));
      expect(() => EcKeyPair.generate().sharedSecret(bad), throwsA(isA<CryptoException>()));
      expect(() => decodePoint(Uint8List(65)..[0] = 4), throwsA(isA<CryptoException>()));
    });
  });

  group('SPAKE2+ (vectors from matter.js)', () {
    final salt = _h('5350414b453250204b65792053616c74');
    final context = _h('3775fe550d79178ee81412478643b3cbcfe15bfb63c4f9106d8ac930da5ae235');
    final x = BigInt.parse('1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef', radix: 16);
    final y = BigInt.parse('fedcba0987654321fedcba0987654321fedcba0987654321fedcba098765432', radix: 16);

    test('w0, w1, both shares, the shared key and both confirmations match', () {
      final w0w1 = spakeW0W1(20202021, salt, 1000);
      expect(hexOf(w0w1.sublist(0, 32)), 'b96170aae803346884724fe9a3b287c30330c2a660375d17bb205a8cf1aecb35');
      expect(hexOf(w0w1.sublist(32)), '823d264225e36f4923b43ad64f8c862a30f4a129bbf9ee8074a32d6d67586a90');
      final prover = Spake2pProver(context, w0w1, x);
      final verifier = Spake2pVerifier(context, w0w1, y);
      expect(hexOf(prover.shareX),
          '04db709504559895f709290e9c32b2e0a81dc34fccc9cdf3b410a3e6872bc7e17629dd510bb78c13a78932d792a247bb2bac93522'
          '63d685ffdecfb619de936963e');
      expect(hexOf(verifier.shareY),
          '04e8986cc4e6a45e7c803523824463d2dda612bb30e139c21bd67719c7c3a4c4ee1fa94ae0b7590376f4450e008a8d955e9ea15d7'
          '30cb75a2b1f72d00917e76736');
      for (final r in [prover.finish(verifier.shareY), verifier.finish(prover.shareX)]) {
        expect(hexOf(r.ke), '7dfb15dc61b110ef225784355a94d72f');
        expect(hexOf(r.cA), '08444ddd97d9d48d0d7fdc11d582329763c5bbcd4c4976ef4e1bc3b6744da541');
        expect(hexOf(r.cB), '38a250e877e634e1e61a4fa1b0c209ef93e9fd658edd2149e265a3a3cc97d996');
      }
    });

    test('a wrong passcode shows up as a confirmation that does not match', () {
      final prover = Spake2pProver(context, spakeW0W1(20202022, salt, 1000));
      final verifier = Spake2pVerifier(context, spakeW0W1(20202021, salt, 1000));
      final p = prover.finish(verifier.shareY);
      final v = verifier.finish(prover.shareX);
      expect(bytesEqual(p.cB, v.cB), isFalse);
      expect(bytesEqual(p.ke, v.ke), isFalse);
    });

    test('a share that is not a curve point is refused', () {
      final prover = Spake2pProver(context, spakeW0W1(20202021, salt, 1000));
      expect(() => prover.finish(Uint8List(65)..[0] = 4), throwsA(isA<CryptoException>()));
    });
  });

  group('operational certificates', () {
    test('a matter.js root and node certificate decode, verify and give the same DER', () {
      final rcac = MatterCertificate.decode(_h(_matterJsRcac));
      expect(rcac.isCa, isTrue);
      expect(rcac.rcacId, 0);
      expect(rcac.keyUsage, KeyUsage.keyCertSign | KeyUsage.cRLSign);
      expect(hexOf(rcac.tbsDer()), _matterJsRcacTbs);
      expect(hexOf(rcac.toDer()), hexOf(_h('30820196$_matterJsRcacTbs$_matterJsRcacSignatureDer')));
      expect(rcac.verifySignature(rcac.publicKey), isTrue);
      expect(hexOf(rcac.encode()), _matterJsRcac);

      final noc = MatterCertificate.decode(_h(_matterJsNoc));
      expect(noc.isCa, isFalse);
      expect(noc.fabricId, 0x1122334455667788);
      expect(noc.nodeId, 0x42);
      expect(noc.extendedKeyUsage, [KeyPurpose.clientAuth, KeyPurpose.serverAuth]);
      expect(hexOf(noc.publicKey), _matterJsNocPublicKey);
      expect(hexOf(noc.tbsDer()), _matterJsNocTbs);
      expect(noc.verifySignature(rcac.publicKey), isTrue);
      expect(noc.verifySignature(noc.publicKey), isFalse);
      expect(hexOf(noc.encode()), _matterJsNoc);
    });

    test('a changed field breaks the signature', () {
      final tlv = _h(_matterJsNoc);
      // The node id in the subject: context tag 17, one byte, 0x42.
      var at = -1;
      for (var i = 0; i + 2 < tlv.length && at < 0; i++) {
        if (tlv[i] == 0x24 && tlv[i + 1] == 0x11 && tlv[i + 2] == 0x42) at = i + 2;
      }
      expect(at, greaterThan(0));
      tlv[at] = 0x43;
      final noc = MatterCertificate.decode(tlv);
      expect(noc.nodeId, 0x43);
      expect(noc.verifySignature(MatterCertificate.decode(_h(_matterJsRcac)).publicKey), isFalse);
    });

    test('ours verify, keep their bytes through TLV, and carry the right fields', () {
      final rootKey = EcKeyPair.generate();
      final root = issueRootCertificate(rootKey, rcacId: 0x1234, now: DateTime.utc(2026, 10, 17));
      final rootAgain = MatterCertificate.decode(root.encode());
      expect(rootAgain.verifySignature(rootKey.publicKey), isTrue);
      expect(rootAgain.encode(), root.encode());
      expect(rootAgain.tbsDer(), root.tbsDer());
      expect(rootAgain.rcacId, 0x1234);
      expect(rootAgain.subjectKeyId, sha1(rootKey.publicKey));
      expect(rootAgain.notBefore, matterTime(DateTime.utc(2025, 10, 17)));

      final key = EcKeyPair.generate();
      const bigNode = 0xFFFFFFEF00000001; // above 2^63: a negative Dart int
      final noc = issueNodeCertificate(
          rootKey: rootKey, root: root, publicKey: key.publicKey, nodeId: bigNode, fabricId: 0x0102030405060708);
      final nocAgain = MatterCertificate.decode(noc.encode());
      expect(nocAgain.nodeId, bigNode);
      expect(nocAgain.fabricId, 0x0102030405060708);
      expect(nocAgain.verifySignature(rootKey.publicKey), isTrue);
      expect(nocAgain.authorityKeyId, root.subjectKeyId);
      expect(nocAgain.keyUsage, KeyUsage.digitalSignature);
      // Ids are written into the DER name as 16 upper-case hex digits.
      expect(utf8.decode(noc.tbsDer(), allowMalformed: true), contains('FFFFFFEF00000001'));
      expect(utf8.decode(noc.tbsDer(), allowMalformed: true), contains('0102030405060708'));
      // Serial numbers are positive and have no leading zero byte.
      expect(noc.serialNumber.first, inInclusiveRange(1, 0x7f));
    });

    test('validity times: UTCTime until 2049, GeneralizedTime after, and "no expiry"', () {
      MatterCertificate cert(DateTime notBefore, int notAfter) => MatterCertificate(
            serialNumber: Uint8List.fromList([1]),
            issuer: const [(DnTag.rcacId, 1)],
            notBefore: matterTime(notBefore),
            notAfter: notAfter,
            subject: const [(DnTag.rcacId, 1)],
            publicKey: EcKeyPair.generate().publicKey,
            isCa: true,
            keyUsage: KeyUsage.keyCertSign,
            subjectKeyId: Uint8List(20),
            authorityKeyId: Uint8List(20),
          );
      final a = ascii.decode(cert(DateTime.utc(2049, 12, 31, 23, 59, 59), matterTime(DateTime.utc(2050, 1, 1))).tbsDer(),
          allowInvalid: true);
      expect(a, contains('491231235959Z'));
      expect(a, contains('20500101000000Z'));
      final b = ascii.decode(cert(DateTime.utc(2001, 2, 3, 4, 5, 6), 0).tbsDer(), allowInvalid: true);
      expect(b, contains('010203040506Z'));
      expect(b, contains('99991231235959Z'));
    });

    test('damaged certificates are refused', () {
      expect(() => MatterCertificate.decode(_h('1530010101')), throwsA(isA<CertificateException>()));
      expect(() => MatterCertificate.decode(_h('1518')), throwsA(isA<CertificateException>()));
      expect(() => MatterCertificate.decode(_h('04')), throwsA(isA<CertificateException>()));
    });

    test('the public key of a matter.js CSR, after checking its signature', () {
      expect(hexOf(publicKeyFromCsr(_h(_matterJsCsr))), _matterJsCsrPublicKey);
      final forged = _h(_matterJsCsr)..[_matterJsCsr.length ~/ 2 - 3] ^= 0x01;
      expect(() => publicKeyFromCsr(forged), throwsA(isA<CertificateException>()));
      expect(() => publicKeyFromCsr(_h(_matterJsCsr).sublist(0, 60)), throwsA(isA<CertificateException>()));
      final key = EcKeyPair.generate();
      expect(publicKeyFromCsr(makeCsr(key)), key.publicKey);
    });

    test('Node reads our certificates as X.509 and checks the chain', () async {
      final rootKey = EcKeyPair.generate();
      final root = issueRootCertificate(rootKey, rcacId: 7);
      final noc = issueNodeCertificate(
          rootKey: rootKey, root: root, publicKey: EcKeyPair.generate().publicKey, nodeId: 0x2a, fabricId: 0xfab);
      final r = await _node(
        'const { X509Certificate } = require("node:crypto");'
        'const root = new X509Certificate(Buffer.from(process.env.RCAC, "hex"));'
        'const noc = new X509Certificate(Buffer.from(process.env.NOC, "hex"));'
        'console.log(JSON.stringify({ selfSigned: root.verify(root.publicKey), signed: noc.verify(root.publicKey),'
        ' issued: noc.checkIssued(root), rootCa: root.ca, nocCa: noc.ca, eku: noc.keyUsage, subject: noc.subject }));',
        {'RCAC': hexOf(root.toDer()), 'NOC': hexOf(noc.toDer())},
      );
      expect(r['selfSigned'], isTrue);
      expect(r['signed'], isTrue);
      expect(r['issued'], isTrue);
      expect(r['rootCa'], isTrue);
      expect(r['nocCa'], isFalse);
      expect(r['eku'], containsAll(['1.3.6.1.5.5.7.3.1', '1.3.6.1.5.5.7.3.2']));
      expect(r['subject'], allOf(contains('000000000000002A'), contains('0000000000000FAB')));
    }, skip: _noNode());

    test('matter.js accepts our certificates and converts them to the same DER', () async {
      final rootKey = EcKeyPair.generate();
      final root = issueRootCertificate(rootKey, rcacId: randomOperationalNodeId());
      final noc = issueNodeCertificate(
          rootKey: rootKey,
          root: root,
          publicKey: EcKeyPair.generate().publicKey,
          nodeId: randomOperationalNodeId(),
          fabricId: randomOperationalNodeId());
      final r = await _node(
        'import { StandardCrypto } from "@matter/main";'
        'import { Noc, Rcac } from "@matter/main/protocol";'
        'const crypto = new StandardCrypto();'
        'const bytes = (h) => new Uint8Array(Buffer.from(h, "hex"));'
        'const hex = (b) => Buffer.from(b).toString("hex");'
        'const rcac = Rcac.fromTlv(bytes(process.env.RCAC));'
        'await rcac.verify(crypto);'
        'const noc = Noc.fromTlv(bytes(process.env.NOC));'
        'await noc.verify(crypto, rcac);'
        'console.log(JSON.stringify({ rcac: hex(rcac.asUnsignedDer()), noc: hex(noc.asUnsignedDer()) }));',
        {'RCAC': hexOf(root.encode()), 'NOC': hexOf(noc.encode())},
        module: true,
      );
      expect(r['rcac'], hexOf(root.tbsDer()));
      expect(r['noc'], hexOf(noc.tbsDer()));
    }, skip: _noMatterJs());
  });

  group('fabric', () {
    test('compressed fabric id, operational IPK and destination id: the spec test vectors', () {
      final rootPub = _h('044a9f42b1ca4840d37292bbc7f6a7e11e22200c976fc900dbc98a7a383a641cb8254a2e56d4e295a847943b4e3'
          '897c4a773e930277b4d9fbede8a052686bfacfa');
      final any = MatterFabric.create();
      final f = MatterFabric(
        rootKey: any.rootKey,
        rootCert: _unsignedRootWithKey(rootPub),
        fabricId: 0x2906C908D115D362,
        controllerNodeId: any.controllerNodeId,
        controllerKey: any.controllerKey,
        controllerNoc: any.controllerNoc,
        ipkEpochKey: _h('4a71cdd7b2a3ca9024f96f3c96a19dee'),
        nextNodeId: 1,
      );
      expect(hex64(f.compressedFabricId), '87E1B004E235A130');
      expect(hexOf(f.operationalIpk), '9bc61cd9c62a2df6d64dfcaa9dc472d4');
      const node = 0xCD5544AA7B13EF14;
      expect(hexOf(f.destinationId(_h('7e171231568dfa17206b3accf8faec2f4d21b580113196f47c7c4deb810a73dc'), node)),
          'dc35dd5fc9134cc5544538c9c3fc4297c1ec3370c839136a80e10796451d4c53');
      expect(f.instanceName(node), '87E1B004E235A130-CD5544AA7B13EF14');
    });

    test('a new fabric saves to plain JSON and comes back the same', () {
      final f = MatterFabric.create();
      final json = jsonDecode(jsonEncode(f.toJson())) as Map<String, dynamic>;
      expect(json.values.every((v) => v is String || v is int), isTrue);
      final g = MatterFabric.fromJson(json);
      expect(g.fabricId, f.fabricId);
      expect(g.controllerNodeId, f.controllerNodeId);
      expect(g.compressedFabricId, f.compressedFabricId);
      expect(g.operationalIpk, f.operationalIpk);
      expect(g.rootPublicKey, f.rootPublicKey);
      expect(g.controllerKey.publicKey, f.controllerKey.publicKey);
      expect(g.controllerNoc.encode(), f.controllerNoc.encode());
      expect(g.nextNodeId, f.nextNodeId);
      expect(g.owns(g.controllerNoc, g.controllerNodeId), isTrue);
      final device = EcKeyPair.generate();
      final noc = g.issueNoc(device.publicKey, 5);
      expect(f.owns(noc, 5), isTrue);
      expect(f.owns(noc, 6), isFalse);
      expect(MatterFabric.create().owns(noc, 5), isFalse);
    });

    test('node ids are handed out in turn, never 0 or the app\'s own', () {
      final f = MatterFabric.create()..nextNodeId = 41;
      expect([f.allocateNodeId(), f.allocateNodeId()], [41, 42]);
      f.nextNodeId = 0;
      expect(f.allocateNodeId(), 1);
      f.nextNodeId = f.controllerNodeId;
      expect(f.allocateNodeId(), isNot(f.controllerNodeId));
    });

    test('damaged settings give a clear error', () {
      final json = MatterFabric.create().toJson();
      expect(() => MatterFabric.fromJson({...json, 'rootKey': hexOf(EcKeyPair.generate().privateKey)}),
          throwsA(isA<MatterException>()));
      expect(() => MatterFabric.fromJson({...json, 'noc': 'AAAA'}), throwsA(isA<MatterException>()));
      expect(() => MatterFabric.fromJson(<String, dynamic>{}), throwsA(isA<MatterException>()));
    });
  });
}
