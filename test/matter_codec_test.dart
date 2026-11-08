// Matter setup codes, TLV and message headers against outside references:
// codes made by matter.js (tool/matter/vectors.mjs) and the TLV examples of
// the Matter specification (Appendix A).
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:smartmenukj/integrations/matter/message.dart';
import 'package:smartmenukj/integrations/matter/onboarding.dart';
import 'package:smartmenukj/integrations/matter/tlv.dart';

String _hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join(' ');

void main() {
  group('setup codes (made by matter.js)', () {
    const codes = [
      (passcode: 20202021, discriminator: 3840, vendor: 0xfff1, product: 0x8000,
          qr: 'MT:Y.K90AFN00KA0648G00', manual: '34970112332', long: '749701123365521327687'),
      (passcode: 12345679, discriminator: 0x123, vendor: 0x1234, product: 0x5678,
          qr: 'MT:CS.16.T-03YRG46Y900', manual: '02491107530', long: '424911075304660221363'),
      (passcode: 99999998, discriminator: 0xfff, vendor: 0xfff2, product: 1,
          qr: 'MT:634J0S4J271DQ36B420', manual: '35759861036', long: '757598610365522000019'),
    ];

    for (final c in codes) {
      test('${c.manual}: QR, 11 and 21 digits', () {
        final qr = parseSetupCode(c.qr);
        expect((qr.passcode, qr.discriminator, qr.isShort), (c.passcode, c.discriminator, false));
        expect((qr.vendorId, qr.productId), (c.vendor, c.product));
        expect(qr.manualCode, c.manual);

        final manual = parseSetupCode(c.manual);
        expect((manual.passcode, manual.discriminator, manual.isShort), (c.passcode, c.discriminator >> 8, true));
        expect(manual.matches(c.discriminator), isTrue);
        expect(manual.matches(c.discriminator ^ 0x100), isFalse);

        final long = parseSetupCode(c.long);
        expect((long.passcode, long.shortDiscriminator), (c.passcode, c.discriminator >> 8));
      });
    }

    test('dashes and spaces are fine, typos and other text are not', () {
      expect(parseSetupCode(' 3497-011-2332 ').passcode, 20202021);
      expect(parseSetupCode('3497 011 2332').passcode, 20202021);
      expect(() => parseSetupCode('34970112333'), throwsA(isA<SetupCodeException>()), reason: 'wrong check digit');
      expect(() => parseSetupCode('3497011233'), throwsA(isA<SetupCodeException>()));
      expect(() => parseSetupCode('hello'), throwsA(isA<SetupCodeException>()));
      expect(() => parseSetupCode('MT:###'), throwsA(isA<SetupCodeException>()));
    });
  });

  group('TLV (specification examples)', () {
    Uint8List write(void Function(TlvWriter w) body) => (TlvWriter()..also(body)).toBytes();

    test('single values', () {
      expect(_hex(write((w) => w.boolean(null, false))), '08');
      expect(_hex(write((w) => w.boolean(null, true))), '09');
      expect(_hex(write((w) => w.int_(null, 42))), '00 2a');
      expect(_hex(write((w) => w.int_(null, -17))), '00 ef');
      expect(_hex(write((w) => w.uint(null, 42))), '04 2a');
      expect(_hex(write((w) => w.int_(null, 422))), '01 a6 01');
      expect(_hex(write((w) => w.int_(null, -170000))), '02 f0 67 fd ff');
      expect(_hex(write((w) => w.int_(null, 40000000000))), '03 00 90 2f 50 09 00 00 00');
      expect(_hex(write((w) => w.string(null, 'Hello!'))), '0c 06 48 65 6c 6c 6f 21');
      expect(_hex(write((w) => w.bytes(null, [0, 1, 2, 3, 4]))), '10 05 00 01 02 03 04');
      expect(_hex(write((w) => w.nil(null))), '14');
    });

    test('containers', () {
      expect(_hex(tlvStruct((_) {})), '15 18');
      expect(_hex(write((w) => w.array(null, (_) {}))), '16 18');
      expect(_hex(write((w) => w.list(null, (_) {}))), '17 18');
      expect(_hex(tlvStruct((w) => w..int_(0, 42)..int_(1, -17))), '15 20 00 2a 20 01 ef 18');
    });

    test('what is written reads back the same', () {
      final data = tlvStruct((w) => w
        ..uint(1, 0xfffffffff)
        ..int_(2, -300000)
        ..boolean(3, true)
        ..string(4, 'Küche')
        ..bytes(5, [9, 8, 7])
        ..nil(6)
        ..array(7, (w) => w..uint(null, 1)..uint(null, 2))
        ..struct(8, (w) => w.uint(0, 5))
        ..list(9, (w) => w.uint(2, 3)));
      final s = decodeTlv(data) as TlvStruct;
      expect(s.integer(1), 0xfffffffff);
      expect(s.integer(2), -300000);
      expect(s.boolean(3), isTrue);
      expect(s.string(4), 'Küche');
      expect(s.bytes(5), [9, 8, 7]);
      expect(s.has(6) && s[6] == null, isTrue);
      expect(s.array(7), [1, 2]);
      expect(s.struct(8)!.integer(0), 5);
      expect(s.struct(9)!.isList, isTrue);
    });

    test('broken data is refused', () {
      expect(() => decodeTlv(Uint8List.fromList([0x15, 0x24, 0x01])), throwsA(isA<TlvFormatException>()));
      expect(() => decodeTlv(Uint8List.fromList([0x0c, 0x09, 0x41])), throwsA(isA<TlvFormatException>()));
    });
  });

  group('message headers', () {
    test('a secure unicast header and a payload header read back the same', () {
      final packet = PacketHeader(sessionId: 0x1234, counter: 0x89abcdef, securityFlags: 0);
      final back = PacketHeader.decode(packet.encode());
      expect((back.sessionId, back.counter, back.sourceNodeId, back.destNodeId), (0x1234, 0x89abcdef, null, null));

      final payload = PayloadHeader(
          exchangeId: 7, protocolId: Protocols.interactionModel, opcode: ImOp.readRequest, initiator: true, reliable: true, ackCounter: 42);
      final (h, rest) = PayloadHeader.decode(payload.encode([1, 2, 3]));
      expect((h.exchangeId, h.protocolId, h.opcode, h.initiator, h.reliable, h.ackCounter),
          (7, Protocols.interactionModel, ImOp.readRequest, true, true, 42));
      expect(rest, [1, 2, 3]);
    });

    test('an unsecured header carries the source node id', () {
      final packet = PacketHeader(sessionId: 0, counter: 1, securityFlags: 0, sourceNodeId: 0x0102030405060708);
      expect(PacketHeader.decode(packet.encode()).sourceNodeId, 0x0102030405060708);
    });

    test('a short packet is refused', () {
      expect(() => PacketHeader.decode(Uint8List.fromList([0, 1])), throwsA(isA<MessageFormatException>()));
    });
  });
}

extension on TlvWriter {
  void also(void Function(TlvWriter w) body) => body(this);
}
