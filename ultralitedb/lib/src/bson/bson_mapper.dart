import 'dart:math';
import 'dart:typed_data';
import 'bson_type.dart';
import 'bson_value.dart';
import 'bson_auto_id.dart';
import 'objectid.dart';

typedef ToBson<T> = BsonValue Function(T obj);
typedef FromBson<T> = T Function(BsonValue bson);

/// Maps Dart objects ↔ [BsonDocument] / [BsonValue].
///
/// Dart AOT (Flutter) has no runtime reflection — custom class types must be
/// registered explicitly via [registerType]. Built-in support:
///   null · bool · int · double · String · DateTime · Uint8List · ObjectId
///   List<dynamic> · Map<String,dynamic>
class BsonMapper {
  /// Shared global instance used by the database engine.
  static final BsonMapper global = BsonMapper._();

  /// Auto-id strategy when inserting documents without an `_id` field.
  BsonAutoId autoId;

  /// Trim whitespace from string values before storing.
  bool trimWhitespace;

  /// Convert empty strings to null instead of storing an empty string.
  bool emptyStringToNull;

  BsonMapper._({this.autoId = BsonAutoId.objectId, this.trimWhitespace = true, this.emptyStringToNull = false});

  final Map<Type, BsonValue Function(dynamic)> _toConverters = {};
  final Map<Type, dynamic Function(BsonValue)> _fromConverters = {};

  // ── Registration ──────────────────────────────────────────────────────────

  /// Registers a custom round-trip converter for type [T].
  ///
  /// ```dart
  /// BsonMapper.global.registerType<Color>(
  ///   (c) => BsonValue.fromInt(c.value),
  ///   (b) => Color(b.asInt32OrZero),
  /// );
  /// ```
  void registerType<T>(ToBson<T> to, FromBson<T> from) {
    _toConverters[T] = (v) => to(v as T);
    _fromConverters[T] = from;
  }

  // ── To BSON ───────────────────────────────────────────────────────────────

  /// Converts a [Map<String,dynamic>] to a [BsonDocument].
  BsonDocument toDocument(Map<String, dynamic> map) {
    final doc = BsonDocument();
    for (final e in map.entries) {
      doc[e.key] = toBsonValue(e.value);
    }
    return doc;
  }

  /// Converts any supported Dart value to its [BsonValue] representation.
  BsonValue toBsonValue(dynamic v) {
    if (v == null) return BsonValue.nullValue();
    if (v is BsonValue) return v;
    if (v is bool) return BsonValue.fromBool(v);
    if (v is int) return BsonValue.fromInt(v);
    if (v is double) return BsonValue.fromDouble(v);
    if (v is String) {
      final s = trimWhitespace ? v.trim() : v;
      if (emptyStringToNull && s.isEmpty) return BsonValue.nullValue();
      return BsonValue.fromString(s);
    }
    if (v is DateTime) return BsonValue.fromDateTime(v);
    if (v is Uint8List) return BsonValue.fromBytes(v);
    if (v is ObjectId) return BsonValue.fromObjectId(v);
    if (v is List) {
      final arr = BsonArray();
      for (final item in v) {
        arr.add(toBsonValue(item));
      }
      return arr;
    }
    if (v is Map<String, dynamic>) return toDocument(v);

    // try registered custom converter
    final conv = _toConverters[v.runtimeType];
    if (conv != null) return conv(v);

    throw ArgumentError(
      'BsonMapper: no converter for ${v.runtimeType}. '
      'Register one via registerType<${v.runtimeType}>().',
    );
  }

  // ── From BSON ─────────────────────────────────────────────────────────────

  /// Converts a [BsonDocument] to a [Map<String,dynamic>].
  Map<String, dynamic> fromDocument(BsonDocument doc) {
    final map = <String, dynamic>{};
    for (final e in doc.entries) {
      map[e.key] = fromBsonValue(e.value);
    }
    return map;
  }

  /// Converts a [BsonValue] to a native Dart value.
  dynamic fromBsonValue(BsonValue v) => switch (v.type) {
    BsonType.null_ || BsonType.minValue || BsonType.maxValue => null,
    BsonType.boolean => v.asBoolean,
    BsonType.int32 => v.asInt32,
    BsonType.int64 => v.asInt64,
    BsonType.double || BsonType.decimal => v.asDouble,
    BsonType.string => v.asString,
    BsonType.dateTime => v.asDateTime,
    BsonType.objectId => v.asObjectId,
    BsonType.guid || BsonType.binary => v.asBinary,
    BsonType.document => fromDocument(v.asDocument!),
    BsonType.array => v.asArray!.map(fromBsonValue).toList(),
  };

  /// Converts a [BsonValue] to type [T] using a registered converter.
  T? convertFrom<T>(BsonValue v) {
    final conv = _fromConverters[T];
    if (conv != null) return conv(v) as T;
    return fromBsonValue(v) as T?;
  }

  // ── Auto-Id ───────────────────────────────────────────────────────────────

  /// Ensures [doc] has an `_id` field, generating one if absent.
  void ensureId(BsonDocument doc, [BsonAutoId? idType]) {
    if (doc.containsKey('_id')) return;
    switch (idType ?? autoId) {
      case BsonAutoId.objectId:
        doc['_id'] = BsonValue.fromObjectId(ObjectId.newObjectId());
      case BsonAutoId.int32:
        doc['_id'] = BsonValue.fromInt(0); // sequence managed by the engine
      case BsonAutoId.int64:
        doc['_id'] = BsonValue.fromInt64(0);
      case BsonAutoId.guid:
        final rng = Random.secure();
        doc['_id'] = BsonValue.fromBytes(Uint8List.fromList(List.generate(16, (_) => rng.nextInt(256))));
    }
  }
}
