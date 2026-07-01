import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'bson_type.dart';
import 'objectid.dart';

part 'document.dart';
part 'bson_array.dart';

/// Core value type for all BSON data. Subclassed by [BsonDocument] and [BsonArray].
class BsonValue implements Comparable<BsonValue> {
  /// Unix epoch reference used for DateTime serialization.
  static final DateTime unixEpoch = DateTime.utc(1970, 1, 1);

  /// Singleton representing the smallest possible value.
  static final BsonValue minValue = BsonValue._init(BsonType.minValue, null);

  /// Singleton representing the largest possible value.
  static final BsonValue maxValue = BsonValue._init(BsonType.maxValue, null);

  final BsonType type;
  final Object? _rawValue;
  int __cachedSize = -1;

  /// Library-private constructor — use factory constructors or subclasses.
  BsonValue._init(this.type, this._rawValue);

  // ── Factory constructors ──────────────────────────────────────────────────

  factory BsonValue.nullValue() => BsonValue._init(BsonType.null_, null);
  factory BsonValue.fromBool(bool v) => BsonValue._init(BsonType.boolean, v);
  factory BsonValue.fromInt(int v) => BsonValue._init(BsonType.int32, v);
  factory BsonValue.fromInt64(int v) => BsonValue._init(BsonType.int64, v);
  factory BsonValue.fromDouble(double v) => BsonValue._init(BsonType.double, v);
  factory BsonValue.fromString(String v) => BsonValue._init(BsonType.string, v);
  factory BsonValue.fromDateTime(DateTime v) => BsonValue._init(BsonType.dateTime, v.toUtc());
  factory BsonValue.fromBytes(Uint8List v) => BsonValue._init(BsonType.binary, v);
  factory BsonValue.fromObjectId(ObjectId v) => BsonValue._init(BsonType.objectId, v);

  // ...existing code...
  /// Auto-detects the Dart runtime type of [v] and wraps it.
  factory BsonValue.from(Object? v) {
    if (v == null) return BsonValue.nullValue();
    if (v is BsonValue) return v;
    if (v is bool) return BsonValue.fromBool(v);
    if (v is int) return BsonValue.fromInt(v);
    if (v is double) return BsonValue.fromDouble(v);
    if (v is String) return BsonValue.fromString(v);
    if (v is DateTime) return BsonValue.fromDateTime(v);
    if (v is Uint8List) return BsonValue.fromBytes(v);
    if (v is ObjectId) return BsonValue.fromObjectId(v);
    // ── Collection types ──────────────────────────────────────────────────
    if (v is Map<String, dynamic>) {
      final doc = BsonDocument();
      for (final e in v.entries) {
        doc[e.key] = BsonValue.from(e.value);
      }
      return doc;
    }
    if (v is Map) {
      // Non-generic Map — convert keys to String
      final doc = BsonDocument();
      for (final e in v.entries) {
        doc[e.key.toString()] = BsonValue.from(e.value);
      }
      return doc;
    }
    if (v is List) return BsonArray.from(v);
    if (v is Iterable) return BsonArray.from(v.toList());
    throw ArgumentError('Cannot convert ${v.runtimeType} to BsonValue');
  }
  // ...existing code...

  // ── Type checks ───────────────────────────────────────────────────────────

  bool get isNull => type == BsonType.null_;
  bool get isMinValue => type == BsonType.minValue;
  bool get isMaxValue => type == BsonType.maxValue;
  bool get isBoolean => type == BsonType.boolean;
  bool get isInt32 => type == BsonType.int32;
  bool get isInt64 => type == BsonType.int64;
  bool get isDouble => type == BsonType.double;
  bool get isDecimal => type == BsonType.decimal;
  bool get isString => type == BsonType.string;
  bool get isDocument => type == BsonType.document;
  bool get isArray => type == BsonType.array;
  bool get isBinary => type == BsonType.binary;
  bool get isObjectId => type == BsonType.objectId;
  bool get isGuid => type == BsonType.guid;
  bool get isDateTime => type == BsonType.dateTime;
  bool get isNumber => isInt32 || isInt64 || isDouble || isDecimal;

  // ── Value accessors ───────────────────────────────────────────────────────

  BsonDocument? get asDocument => this is BsonDocument ? this as BsonDocument : null;
  BsonArray? get asArray => this is BsonArray ? this as BsonArray : null;

  String? get asString => isString ? _rawValue as String : null;
  bool? get asBoolean => isBoolean ? _rawValue as bool : null;
  DateTime? get asDateTime => isDateTime ? _rawValue as DateTime : null;
  Uint8List? get asBinary => isBinary ? _rawValue as Uint8List : null;
  ObjectId? get asObjectId => isObjectId ? _rawValue as ObjectId : null;

  int? get asInt32 {
    if (isInt32) return _rawValue as int;
    if (isInt64) return (_rawValue as int).toSigned(32);
    if (isDouble) return (_rawValue as double).toInt();
    return null;
  }

  int? get asInt64 {
    if (isInt32 || isInt64) return _rawValue as int;
    if (isDouble) return (_rawValue as double).toInt();
    return null;
  }

  double? get asDouble {
    if (isDouble) return _rawValue as double;
    if (isInt32 || isInt64) return (_rawValue as int).toDouble();
    return null;
  }

  // Convenience non-nullable getters with safe defaults
  String get asStringOrEmpty => asString ?? '';
  int get asInt32OrZero => asInt32 ?? 0;
  int get asInt64OrZero => asInt64 ?? 0;
  double get asDoubleOrZero => asDouble ?? 0.0;
  bool get asBooleanOrFalse => asBoolean ?? false;

  Object? get rawValue => _rawValue;

  // ── Byte-size calculation (used for BSON serialization) ───────────────────

  int getBytesCount(bool recalc) {
    switch (type) {
      case BsonType.null_:
      case BsonType.minValue:
      case BsonType.maxValue:
        return 0;
      case BsonType.boolean:
        return 1;
      case BsonType.int32:
        return 4;
      case BsonType.int64:
        return 8;
      case BsonType.double:
        return 8;
      case BsonType.decimal:
        return 16;
      case BsonType.string:
        // Cache the encoded string length
        if (_rawValue is String) {
          final s = _rawValue as String;
          return 4 + utf8.encode(s).length;
        }
        return 4 + (asStringOrEmpty.length); // Fallback but types are matching above
      case BsonType.binary:
        return 4 + (asBinary?.length ?? 0);
      case BsonType.objectId:
        return 12;
      case BsonType.guid:
        return 16;
      case BsonType.dateTime:
        return 8;
      case BsonType.document:
        return (this as BsonDocument)._getBytesCount(recalc);
      case BsonType.array:
        return (this as BsonArray)._getBytesCount(recalc);
    }
  }

  // ── Comparison ────────────────────────────────────────────────────────────

  @override
  int compareTo(BsonValue other) {
    if (type == other.type) return _compareValues(other);
    if (isNumber && other.isNumber) {
      return asDoubleOrZero.compareTo(other.asDoubleOrZero);
    }
    return type.value.compareTo(other.type.value);
  }

  int _compareValues(BsonValue other) {
    switch (type) {
      case BsonType.null_:
      case BsonType.minValue:
      case BsonType.maxValue:
        return 0;
      case BsonType.boolean:
        final a = _rawValue as bool;
        final b = other._rawValue as bool;
        return a == b ? 0 : (a ? 1 : -1);
      case BsonType.int32:
      case BsonType.int64:
        final a = _rawValue as int;
        final b = other._rawValue as int;
        return a.compareTo(b);
      case BsonType.double:
      case BsonType.decimal:
        final a = _rawValue as double;
        final b = other._rawValue as double;
        return a.compareTo(b);
      case BsonType.string:
        final a = _rawValue as String;
        final b = other._rawValue as String;
        return a.compareTo(b);
      case BsonType.dateTime:
        return (asDateTime ?? unixEpoch).compareTo(other.asDateTime ?? unixEpoch);
      case BsonType.objectId:
        return (asObjectId ?? ObjectId()).compareTo(other.asObjectId ?? ObjectId());
      case BsonType.array:
        return (this as BsonArray)._compare(other as BsonArray);
      case BsonType.document:
        return (this as BsonDocument)._compare(other as BsonDocument);
      default:
        return 0;
    }
  }

  bool operator <(BsonValue other) => compareTo(other) < 0;
  bool operator >(BsonValue other) => compareTo(other) > 0;
  bool operator <=(BsonValue other) => compareTo(other) <= 0;
  bool operator >=(BsonValue other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BsonValue) return false;
    if (type != other.type) {
      if (isNumber && other.isNumber) {
        return asDoubleOrZero == other.asDoubleOrZero;
      }
      return false;
    }
    if (isBinary) {
      final a = asBinary!, b = other.asBinary!;
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }
    return _rawValue == other._rawValue;
  }

  @override
  int get hashCode => type.hashCode ^ _rawValue.hashCode;

  @override
  String toString() {
    switch (type) {
      case BsonType.null_:
        return 'null';
      case BsonType.minValue:
        return 'MinValue';
      case BsonType.maxValue:
        return 'MaxValue';
      case BsonType.boolean:
        return (asBoolean ?? false).toString();
      case BsonType.int32:
      case BsonType.int64:
        return _rawValue.toString();
      case BsonType.double:
        return (_rawValue as double).toString();
      case BsonType.string:
        return asString ?? '';
      case BsonType.dateTime:
        return asDateTime?.toIso8601String() ?? '';
      case BsonType.objectId:
        return asObjectId?.toString() ?? '';
      default:
        return _rawValue?.toString() ?? 'null';
    }
  }
}
