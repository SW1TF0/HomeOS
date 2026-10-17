import 'dart:convert';
import 'dart:typed_data';

/// Matter TLV, the binary format of every Matter message (Core spec, appendix A).
///
/// Integers are Dart ints. Unsigned 64-bit values above 2^63 come back as
/// negative ints with the same bits, which is all node and fabric ids need.

/// A decoded struct or list: fields in order, looked up by context tag.
class TlvStruct {
  TlvStruct(this.fields, {this.isList = false});

  final List<(int?, Object?)> fields;
  final bool isList;

  bool has(int tag) => fields.any((f) => f.$1 == tag);

  Object? operator [](int tag) {
    for (final f in fields) {
      if (f.$1 == tag) return f.$2;
    }
    return null;
  }

  int? integer(int tag) => this[tag] as int?;
  bool? boolean(int tag) => this[tag] as bool?;
  String? string(int tag) => this[tag] as String?;
  Uint8List? bytes(int tag) => this[tag] as Uint8List?;
  TlvStruct? struct(int tag) => this[tag] as TlvStruct?;
  List<Object?>? array(int tag) {
    final v = this[tag];
    if (v is List<Object?>) return v;
    if (v is TlvStruct) return v.fields.map((f) => f.$2).toList();
    return null;
  }

  @override
  String toString() => '${isList ? 'List' : 'Struct'}{${fields.map((f) => '${f.$1}: ${f.$2}').join(', ')}}';
}

class TlvFormatException implements Exception {
  TlvFormatException(this.message);
  final String message;
  @override
  String toString() => 'Bad TLV: $message';
}

/// Decodes one TLV element, usually the anonymous struct at the top of a message.
Object? decodeTlv(Uint8List data) => TlvReader(data).read().$2;

/// Reads TLV elements one after another.
class TlvReader {
  TlvReader(this.data, [this.pos = 0]);

  final Uint8List data;
  int pos;

  bool get done => pos >= data.length;

  int _byte() {
    if (pos >= data.length) throw TlvFormatException('ran out of data');
    return data[pos++];
  }

  int _le(int n) {
    if (pos + n > data.length) throw TlvFormatException('ran out of data');
    var v = 0;
    for (var i = 0; i < n; i++) {
      v |= data[pos + i] << (8 * i);
    }
    pos += n;
    return v;
  }

  int _signed(int n) {
    final v = _le(n);
    if (n == 8) return v;
    final bits = 8 * n;
    return v >= (1 << (bits - 1)) ? v - (1 << bits) : v;
  }

  /// Returns the element's context tag (null when anonymous) and its value.
  /// The end-of-container marker comes back as [TlvReader.end].
  (int?, Object?) read() {
    final control = _byte();
    final type = control & 0x1f;
    final tagControl = control >> 5;
    int? tag;
    switch (tagControl) {
      case 0:
        tag = null;
      case 1:
        tag = _byte();
      case 2:
        tag = 0x10000 | _le(2);
      case 3:
        tag = 0x10000 | _le(4);
      case 4:
        tag = 0x20000 | _le(2);
      case 5:
        tag = 0x20000 | _le(4);
      case 6:
        _le(4);
        tag = 0x30000 | _le(2);
      case 7:
        _le(4);
        tag = 0x30000 | _le(4);
    }
    switch (type) {
      case 0x00:
        return (tag, _signed(1));
      case 0x01:
        return (tag, _signed(2));
      case 0x02:
        return (tag, _signed(4));
      case 0x03:
        return (tag, _signed(8));
      case 0x04:
        return (tag, _le(1));
      case 0x05:
        return (tag, _le(2));
      case 0x06:
        return (tag, _le(4));
      case 0x07:
        return (tag, _le(8));
      case 0x08:
        return (tag, false);
      case 0x09:
        return (tag, true);
      case 0x0a:
        return (tag, ByteData.sublistView(_take(4)).getFloat32(0, Endian.little));
      case 0x0b:
        return (tag, ByteData.sublistView(_take(8)).getFloat64(0, Endian.little));
      case 0x0c || 0x0d || 0x0e || 0x0f:
        final len = _le(1 << (type - 0x0c));
        return (tag, utf8.decode(_take(len), allowMalformed: true));
      case 0x10 || 0x11 || 0x12 || 0x13:
        final len = _le(1 << (type - 0x10));
        return (tag, Uint8List.fromList(_take(len)));
      case 0x14:
        return (tag, null);
      case 0x15 || 0x17:
        final fields = <(int?, Object?)>[];
        while (true) {
          final e = read();
          if (identical(e.$2, end)) break;
          fields.add(e);
        }
        return (tag, TlvStruct(fields, isList: type == 0x17));
      case 0x16:
        final items = <Object?>[];
        while (true) {
          final e = read();
          if (identical(e.$2, end)) break;
          items.add(e.$2);
        }
        return (tag, items);
      case 0x18:
        return (null, end);
    }
    throw TlvFormatException('unknown element type $type');
  }

  Uint8List _take(int n) {
    if (pos + n > data.length) throw TlvFormatException('ran out of data');
    final out = Uint8List.sublistView(data, pos, pos + n);
    pos += n;
    return out;
  }

  /// Marks the end of a container while reading.
  static const end = _End();
}

class _End {
  const _End();
}

/// Builds TLV. Tags are context tags (0-255), or null for anonymous elements.
class TlvWriter {
  final _b = BytesBuilder(copy: false);

  Uint8List toBytes() => _b.toBytes();

  void _head(int type, int? tag) {
    if (tag == null) {
      _b.addByte(type);
    } else {
      _b.addByte(0x20 | type);
      _b.addByte(tag & 0xff);
    }
  }

  void _le(int v, int n) {
    for (var i = 0; i < n; i++) {
      _b.addByte((v >>> (8 * i)) & 0xff);
    }
  }

  /// Unsigned integer in the smallest width that holds it.
  void uint(int? tag, int v) {
    if (v < 0) {
      _head(0x07, tag);
      _le(v, 8);
    } else if (v < 0x100) {
      _head(0x04, tag);
      _le(v, 1);
    } else if (v < 0x10000) {
      _head(0x05, tag);
      _le(v, 2);
    } else if (v < 0x100000000) {
      _head(0x06, tag);
      _le(v, 4);
    } else {
      _head(0x07, tag);
      _le(v, 8);
    }
  }

  /// Signed integer in the smallest width that holds it.
  void int_(int? tag, int v) {
    if (v >= -0x80 && v < 0x80) {
      _head(0x00, tag);
      _le(v, 1);
    } else if (v >= -0x8000 && v < 0x8000) {
      _head(0x01, tag);
      _le(v, 2);
    } else if (v >= -0x80000000 && v < 0x80000000) {
      _head(0x02, tag);
      _le(v, 4);
    } else {
      _head(0x03, tag);
      _le(v, 8);
    }
  }

  void boolean(int? tag, bool v) => _head(v ? 0x09 : 0x08, tag);

  void nil(int? tag) => _head(0x14, tag);

  void float(int? tag, double v) {
    _head(0x0a, tag);
    final b = ByteData(4)..setFloat32(0, v, Endian.little);
    _b.add(b.buffer.asUint8List());
  }

  void _withLength(int base, int? tag, List<int> bytes) {
    final n = bytes.length;
    if (n < 0x100) {
      _head(base, tag);
      _le(n, 1);
    } else if (n < 0x10000) {
      _head(base + 1, tag);
      _le(n, 2);
    } else {
      _head(base + 2, tag);
      _le(n, 4);
    }
    _b.add(bytes);
  }

  void bytes(int? tag, List<int> v) => _withLength(0x10, tag, v);

  void string(int? tag, String v) => _withLength(0x0c, tag, utf8.encode(v));

  void _container(int type, int? tag, void Function(TlvWriter w) body) {
    _head(type, tag);
    body(this);
    _b.addByte(0x18);
  }

  void struct(int? tag, void Function(TlvWriter w) body) => _container(0x15, tag, body);
  void array(int? tag, void Function(TlvWriter w) body) => _container(0x16, tag, body);
  void list(int? tag, void Function(TlvWriter w) body) => _container(0x17, tag, body);

  /// Copies an already encoded element (it must carry the wanted tag itself).
  void raw(List<int> encoded) => _b.add(encoded);
}

/// Encodes an anonymous struct built by [body].
Uint8List tlvStruct(void Function(TlvWriter w) body) => (TlvWriter()..struct(null, body)).toBytes();
