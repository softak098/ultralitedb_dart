part of 'bson_value.dart';

/// An ordered map of string keys to [BsonValue] values.
/// Mirrors C# BsonDocument in UltraLiteDB.
class BsonDocument extends BsonValue {
  final Map<String, BsonValue> _fields;
  int _cachedBytesCount = 0;

  BsonDocument([Map<String, BsonValue>? fields]) : _fields = fields ?? {}, super._init(BsonType.document, null);

  /// Creates a document from a plain Dart map; values are auto-converted.
  BsonDocument.from(Map<String, dynamic> map) : _fields = {}, super._init(BsonType.document, null) {
    for (final e in map.entries) {
      _fields[e.key] = BsonValue.from(e.value);
    }
  }

  // ── Indexer ───────────────────────────────────────────────────────────────

  /// Returns the value for [key], or [BsonValue.nullValue()] if absent.
  BsonValue operator [](String key) => _fields[key] ?? BsonValue.nullValue();

  /// Sets [key] to [value]. Accepts [BsonValue] or any auto-convertible type.
  void operator []=(String key, dynamic value) {
    _fields[key] = value is BsonValue ? value : BsonValue.from(value);
    _cachedBytesCount = 0;
  }

  // ── Collection operations ─────────────────────────────────────────────────

  bool containsKey(String key) => _fields.containsKey(key);

  void remove(String key) {
    _fields.remove(key);
    _cachedBytesCount = 0;
  }

  void clear() {
    _fields.clear();
    _cachedBytesCount = 0;
  }

  Iterable<String> get keys => _fields.keys;
  Iterable<BsonValue> get values => _fields.values;
  Iterable<MapEntry<String, BsonValue>> get entries => _fields.entries;
  int get count => _fields.length;
  bool get isEmpty => _fields.isEmpty;

  /// Copies all entries from [other] into this document.
  void copyFrom(BsonDocument other) {
    for (final e in other._fields.entries) {
      _fields[e.key] = e.value;
    }
    _cachedBytesCount = 0;
  }

  // ── Byte count ────────────────────────────────────────────────────────────

  // Called by BsonValue.getBytesCount via the `part` relationship.
  int _getBytesCount(bool recalc) {
    if (_cachedBytesCount != 0 && !recalc) return _cachedBytesCount;
    // BSON doc: int32 (total) + [ type(1) + key_cstring(N+1) + value_bytes ]* + 0x00
    var size = 5; // 4-byte header + 1-byte terminator
    for (final e in _fields.entries) {
      size += 1; // type byte
      size += utf8.encode(e.key).length + 1; // key as null-terminated cstring
      size += e.value.getBytesCount(recalc);
    }
    _cachedBytesCount = size;
    return size;
  }

  // ── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BsonDocument) return false;
    if (_fields.length != other._fields.length) return false;
    for (final e in _fields.entries) {
      if (!other._fields.containsKey(e.key)) return false;
      if (e.value != other._fields[e.key]) return false;
    }
    return true;
  }

  @override
  int get hashCode => _fields.hashCode;

  @override
  String toString() {
    final sb = StringBuffer('{');
    var first = true;
    for (final e in _fields.entries) {
      if (!first) sb.write(', ');
      sb.write('"${e.key}": ${e.value}');
      first = false;
    }
    sb.write('}');
    return sb.toString();
  }
}
