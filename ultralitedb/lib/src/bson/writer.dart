import 'dart:typed_data';
import 'dart:convert';
import 'bson_type.dart';
import 'bson_value.dart';

/// Serializes [BsonDocument] / [BsonValue] trees to binary BSON bytes.
class BsonWriter {
  static Uint8List serializeDocument(BsonDocument doc) {
    final buf = _Buf();
    _writeDocument(buf, doc);
    return buf.toBytes();
  }

  // ── internals ─────────────────────────────────────────────────────────────

  static void _writeDocument(_Buf buf, BsonDocument doc) {
    final inner = _Buf();
    for (final e in doc.entries) {
      inner.writeByte(e.value.type.value);
      inner.writeCString(e.key);
      _writeValue(inner, e.value);
    }
    inner.writeByte(0); // document terminator
    final data = inner.toBytes();
    buf.writeInt32(4 + data.length); // total size includes the 4-byte header
    buf.write(data);
  }

  static void _writeArray(_Buf buf, BsonArray arr) {
    final inner = _Buf();
    for (var i = 0; i < arr.length; i++) {
      final v = arr[i];
      inner.writeByte(v.type.value);
      inner.writeCString('$i'); // numeric string key
      _writeValue(inner, v);
    }
    inner.writeByte(0);
    final data = inner.toBytes();
    buf.writeInt32(4 + data.length);
    buf.write(data);
  }

  static void _writeValue(_Buf buf, BsonValue v) {
    switch (v.type) {
      case BsonType.minValue || BsonType.maxValue || BsonType.null_:
        break; // no value bytes for these types

      case BsonType.boolean:
        buf.writeByte(v.asBooleanOrFalse ? 1 : 0);

      case BsonType.int32:
        buf.writeInt32(v.asInt32OrZero);

      case BsonType.int64:
        buf.writeInt64(v.asInt64OrZero);

      case BsonType.double:
        buf.writeFloat64(v.asDoubleOrZero);

      case BsonType.decimal:
        buf.write(v.asBinary ?? Uint8List(16)); // 16 raw bytes

      case BsonType.string:
        final enc = utf8.encode(v.asStringOrEmpty);
        buf.writeInt32(enc.length);
        buf.write(enc);

      case BsonType.dateTime:
        buf.writeInt64((v.asDateTime ?? BsonValue.unixEpoch).millisecondsSinceEpoch);

      case BsonType.objectId:
        buf.write(v.asObjectId!.toBytes());

      case BsonType.guid:
        buf.write(v.asBinary ?? Uint8List(16));

      case BsonType.binary:
        final bytes = v.asBinary!;
        buf.writeInt32(bytes.length);
        buf.write(bytes);

      case BsonType.document:
        _writeDocument(buf, v.asDocument!);

      case BsonType.array:
        _writeArray(buf, v.asArray!);
    }
  }
}

/// Write accumulator. All multi-byte writes are little-endian.
class _Buf {
  final BytesBuilder _bb = BytesBuilder(copy: false);

  void writeByte(int byte) => _bb.addByte(byte & 0xFF);
  void write(List<int> bytes) => _bb.add(bytes);

  void writeCString(String s) {
    _bb.add(utf8.encode(s));
    _bb.addByte(0); // null terminator
  }

  void writeInt32(int v) {
    final d = ByteData(4)..setInt32(0, v, Endian.little);
    _bb.add(d.buffer.asUint8List());
  }

  void writeInt64(int v) {
    final d = ByteData(8)..setInt64(0, v, Endian.little);
    _bb.add(d.buffer.asUint8List());
  }

  void writeFloat64(double v) {
    final d = ByteData(8)..setFloat64(0, v, Endian.little);
    _bb.add(d.buffer.asUint8List());
  }

  Uint8List toBytes() => _bb.toBytes();
}
