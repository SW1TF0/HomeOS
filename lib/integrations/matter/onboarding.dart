/// Matter setup codes: the 11 or 21 digit manual code and the "MT:" QR code
/// (Core spec 5.1).
class SetupCode {
  SetupCode({
    required this.passcode,
    required this.discriminator,
    required this.isShort,
    this.vendorId,
    this.productId,
    this.discovery,
  });

  final int passcode;

  /// The 12-bit discriminator, or only its top 4 bits when [isShort] (manual codes).
  final int discriminator;
  final bool isShort;
  final int? vendorId;
  final int? productId;

  /// Discovery capabilities from a QR code: bit 0 SoftAP, bit 1 Bluetooth, bit 2 on-network.
  final int? discovery;

  int get shortDiscriminator => isShort ? discriminator : discriminator >> 8;

  /// Whether a device advertising [d] (a full 12-bit discriminator) is the one this code is for.
  bool matches(int d) => isShort ? (d >> 8) == discriminator : d == discriminator;

  /// The 11-digit manual code for this passcode and discriminator.
  String get manualCode {
    final chunk1 = (shortDiscriminator >> 2) & 0x3;
    final chunk2 = ((shortDiscriminator & 0x3) << 14) | (passcode & 0x3fff);
    final chunk3 = passcode >> 14;
    final digits = '$chunk1${chunk2.toString().padLeft(5, '0')}${chunk3.toString().padLeft(4, '0')}';
    return '$digits${verhoeffCheckDigit(digits)}';
  }

  @override
  String toString() => 'SetupCode(passcode: $passcode, discriminator: $discriminator, short: $isShort)';
}

class SetupCodeException implements Exception {
  SetupCodeException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Reads a code typed or scanned by the user: "3497-011-2332", "34970112332", or "MT:Y.K9...".
SetupCode parseSetupCode(String input) {
  final text = input.trim();
  if (text.toUpperCase().startsWith('MT:')) return parseQrCode(text);
  final digits = text.replaceAll(RegExp(r'[\s\-]'), '');
  if (!RegExp(r'^\d+$').hasMatch(digits)) {
    throw SetupCodeException('A Matter code has 11 digits (or starts with MT: when scanned).');
  }
  return parseManualCode(digits);
}

SetupCode parseManualCode(String digits) {
  if (digits.length != 11 && digits.length != 21) {
    throw SetupCodeException('A Matter code has 11 digits. This one has ${digits.length}.');
  }
  if (!verhoeffValid(digits)) {
    throw SetupCodeException('That code has a typo. Check the digits and try again.');
  }
  final first = int.parse(digits[0]);
  if (first > 7) throw SetupCodeException('That is not a Matter code.');
  final hasVidPid = first & 0x4 != 0;
  if (hasVidPid != (digits.length == 21)) throw SetupCodeException('That is not a Matter code.');
  final chunk2 = int.parse(digits.substring(1, 6));
  final chunk3 = int.parse(digits.substring(6, 10));
  final shortDisc = ((first & 0x3) << 2) | (chunk2 >> 14);
  final passcode = (chunk3 << 14) | (chunk2 & 0x3fff);
  _checkPasscode(passcode);
  return SetupCode(
    passcode: passcode,
    discriminator: shortDisc,
    isShort: true,
    vendorId: hasVidPid ? int.parse(digits.substring(10, 15)) : null,
    productId: hasVidPid ? int.parse(digits.substring(15, 20)) : null,
  );
}

const _base38 = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ-.';

SetupCode parseQrCode(String text) {
  final body = text.substring(3).split('*').first.toUpperCase();
  final bytes = <int>[];
  for (var i = 0; i < body.length; i += 5) {
    final chunk = body.substring(i, (i + 5).clamp(0, body.length));
    var v = 0;
    for (var k = chunk.length - 1; k >= 0; k--) {
      final c = _base38.indexOf(chunk[k]);
      if (c < 0) throw SetupCodeException('That QR code is not a Matter code.');
      v = v * 38 + c;
    }
    final n = switch (chunk.length) { 5 => 3, 4 => 2, 2 => 1, _ => throw SetupCodeException('That QR code is damaged.') };
    for (var k = 0; k < n; k++) {
      bytes.add((v >> (8 * k)) & 0xff);
    }
  }
  if (bytes.length < 11) throw SetupCodeException('That QR code is too short to be a Matter code.');
  var bit = 0;
  int take(int n) {
    var v = 0;
    for (var k = 0; k < n; k++, bit++) {
      if (bytes[bit >> 3] & (1 << (bit & 7)) != 0) v |= 1 << k;
    }
    return v;
  }

  final version = take(3);
  if (version != 0) throw SetupCodeException('This Matter QR code version is not supported.');
  final vendor = take(16);
  final product = take(16);
  take(2); // commissioning flow
  final discovery = take(8);
  final discriminator = take(12);
  final passcode = take(27);
  _checkPasscode(passcode);
  return SetupCode(
    passcode: passcode,
    discriminator: discriminator,
    isShort: false,
    vendorId: vendor,
    productId: product,
    discovery: discovery,
  );
}

void _checkPasscode(int p) {
  const invalid = {0, 11111111, 22222222, 33333333, 44444444, 55555555, 66666666, 77777777, 88888888, 99999999, 12345678, 87654321};
  if (p <= 0 || p >= 99999999 || invalid.contains(p)) throw SetupCodeException('That code is not valid.');
}

const _d = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
  [1, 2, 3, 4, 0, 6, 7, 8, 9, 5],
  [2, 3, 4, 0, 1, 7, 8, 9, 5, 6],
  [3, 4, 0, 1, 2, 8, 9, 5, 6, 7],
  [4, 0, 1, 2, 3, 9, 5, 6, 7, 8],
  [5, 9, 8, 7, 6, 0, 4, 3, 2, 1],
  [6, 5, 9, 8, 7, 1, 0, 4, 3, 2],
  [7, 6, 5, 9, 8, 2, 1, 0, 4, 3],
  [8, 7, 6, 5, 9, 3, 2, 1, 0, 4],
  [9, 8, 7, 6, 5, 4, 3, 2, 1, 0],
];
const _p = [
  [0, 1, 2, 3, 4, 5, 6, 7, 8, 9],
  [1, 5, 7, 6, 2, 8, 3, 0, 9, 4],
  [5, 8, 0, 3, 7, 9, 6, 1, 4, 2],
  [8, 9, 1, 6, 0, 4, 3, 5, 2, 7],
  [9, 4, 5, 3, 1, 2, 6, 8, 7, 0],
  [4, 2, 8, 6, 5, 7, 3, 9, 0, 1],
  [2, 7, 9, 3, 8, 0, 6, 4, 1, 5],
  [7, 0, 4, 6, 9, 1, 3, 2, 5, 8],
];
const _inv = [0, 4, 3, 2, 1, 5, 6, 7, 8, 9];

String verhoeffCheckDigit(String digits) {
  var c = 0;
  final r = digits.split('').reversed.toList();
  for (var i = 0; i < r.length; i++) {
    c = _d[c][_p[(i + 1) % 8][int.parse(r[i])]];
  }
  return '${_inv[c]}';
}

bool verhoeffValid(String digits) {
  var c = 0;
  final r = digits.split('').reversed.toList();
  for (var i = 0; i < r.length; i++) {
    c = _d[c][_p[i % 8][int.parse(r[i])]];
  }
  return c == 0;
}
