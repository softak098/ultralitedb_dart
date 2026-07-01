import 'dart:typed_data';
import 'dart:convert';
import 'bson_type.dart';
import 'bson_value.dart';
import 'objectid.dart';

/// Deserializes binary BSON bytes into [BsonDocument] / [BsonValue] trees.
/// Wire format (little-endian):
///   document = int32(total) [ type(1) cstring value ]* 0x00
///   array    = int32(total) [ type(1) cstring value ]* 0x00  (keys "0","1",...)
class BsonReader {
  static BsonDocument deserializeDocument(Uint8List bytes) => _readDocument(_Buf(bytes));

  static BsonArray deserializeArray(Uint8List bytes) => _readArray(_Buf(bytes));

  // ── internals ─────────────────────────────────────────────────────────────

  static BsonDocument _readDocument(_Buf r) {
    r.skipInt32(); // total-byte-count header — length includes itself
    final doc = BsonDocument();
    while (true) {
      final typeByte = r.readByte();
      if (typeByte == 0) break; // document terminator
      final key = r.readCString();
      doc[key] = _readValue(r, BsonType.fromByte(typeByte));
    }
    return doc;
  }

  static BsonArray _readArray(_Buf r) {
    r.skipInt32(); // total-byte-count header
    final arr = BsonArray();
    while (true) {
      final typeByte = r.readByte();
      if (typeByte == 0) break;
      r.readCString(); // discard numeric index key ("0", "1", ...)
      arr.add(_readValue(r, BsonType.fromByte(typeByte)));
    }
    return arr;
  }

  // Dart 3 exhaustive switch expression — covers all 15 BsonType values.
  static BsonValue _readValue(_Buf r, BsonType t) => switch (t) {
    BsonType.minValue => BsonValue.minValue,
    BsonType.maxValue => BsonValue.maxValue,
    BsonType.null_ => BsonValue.nullValue(),
    BsonType.boolean => BsonValue.fromBool(r.readByte() != 0),
    BsonType.int32 => BsonValue.fromInt(r.readInt32()),
    BsonType.int64 => BsonValue.fromInt64(r.readInt64()),
    BsonType.double => BsonValue.fromDouble(r.readFloat64()),
    BsonType.decimal => BsonValue.fromBytes(r.read(16)), // 128-bit, no native Dart type
    BsonType.string => BsonValue.fromString(utf8.decode(r.read(r.readInt32()))),
    BsonType.dateTime => BsonValue.fromDateTime(DateTime.fromMillisecondsSinceEpoch(r.readInt64(), isUtc: true)),
    BsonType.objectId => BsonValue.fromObjectId(ObjectId.fromBytes(r.read(12))),
    BsonType.guid => BsonValue.fromBytes(r.read(16)),
    BsonType.binary => BsonValue.fromBytes(r.read(r.readInt32())),
    BsonType.document => _readDocument(r),
    BsonType.array => _readArray(r),
  };
}

/// Read cursor over a [Uint8List]. All multi-byte reads are little-endian.
class _Buf {
  final Uint8List _b;
  late final ByteData _bd;
  int _p = 0;

  static final Map<int, String> _cache = {};

  _Buf(this._b) {
    _bd = ByteData.sublistView(_b);
  }

  int readByte() => _b[_p++];

  String readCString() {
    final start = _p;
    var hash = 0;
    while (_b[_p] != 0) {
      hash = (hash * 31 + _b[_p]) & 0xFFFFFFFF;
      _p++;
    }
    if (_cache.containsKey(hash)) {
      _p++; // skip null
      return _cache[hash]!;
    }
    final s = utf8.decode(Uint8List.sublistView(_b, start, _p));
    _p++; // consume null terminator
    if (_cache.length < 500) _cache[hash] = s;
    return s;
  }

  Uint8List read(int count) {
    final s = Uint8List.sublistView(_b, _p, _p + count);
    _p += count;
    return s;
  }

  int readInt32() {
    final v = _bd.getInt32(_p, Endian.little);
    _p += 4;
    return v;
  }

  int readInt64() {
    final v = _bd.getInt64(_p, Endian.little);
    _p += 8;
    return v;
  }

  double readFloat64() {
    final v = _bd.getFloat64(_p, Endian.little);
    _p += 8;
    return v;
  }

  void skipInt32() => _p += 4;
}
