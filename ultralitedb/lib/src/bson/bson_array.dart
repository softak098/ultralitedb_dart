part of 'bson_value.dart';

/// An ordered list of [BsonValue] items.
/// Mirrors C# BsonArray in UltraLiteDB.
class BsonArray extends BsonValue with Iterable<BsonValue> {
  final List<BsonValue> _items;
  int _cachedBytesCount = 0;

  BsonArray() : _items = [], super._init(BsonType.array, null);

  /// Creates an array from a Dart iterable; items are auto-converted.
  BsonArray.from(Iterable<dynamic> items)
    : _items = [],
      super._init(BsonType.array, null) {
    for (final item in items) {
      _items.add(item is BsonValue ? item : BsonValue.from(item));
    }
  }

  // ── Indexer ───────────────────────────────────────────────────────────────

  BsonValue operator [](int index) => _items[index];

  void operator []=(int index, dynamic value) {
    _items[index] = value is BsonValue ? value : BsonValue.from(value);
    _cachedBytesCount = 0;
  }

  // ── Mutation ──────────────────────────────────────────────────────────────

  void add(dynamic value) {
    _items.add(value is BsonValue ? value : BsonValue.from(value));
    _cachedBytesCount = 0;
  }

  void addAll(Iterable<dynamic> values) {
    for (final v in values) add(v);
  }

  bool remove(dynamic value) {
    final bv = value is BsonValue ? value : BsonValue.from(value);
    final removed = _items.remove(bv);
    if (removed) _cachedBytesCount = 0;
    return removed;
  }

  void removeAt(int index) {
    _items.removeAt(index);
    _cachedBytesCount = 0;
  }

  void clear() {
    _items.clear();
    _cachedBytesCount = 0;
  }

  // ── Query ─────────────────────────────────────────────────────────────────

  @override
  int get length => _items.length;

  int get count => _items.length;

  @override
  bool get isEmpty => _items.isEmpty;

  @override
  bool get isNotEmpty => _items.isNotEmpty;

  @override
  Iterator<BsonValue> get iterator => _items.iterator;

  // ── Byte count ────────────────────────────────────────────────────────────

  int _getBytesCount(bool recalc) {
    if (_cachedBytesCount != 0 && !recalc) return _cachedBytesCount;
    // Array is BSON-encoded as a document with "0","1","2",... string keys
    var size = 5;
    for (var i = 0; i < _items.length; i++) {
      size += 1; // type byte
      size += i.toString().length + 1; // string index as cstring
      size += _items[i].getBytesCount(recalc);
    }
    _cachedBytesCount = size;
    return size;
  }

  // ── Equality ──────────────────────────────────────────────────────────────

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BsonArray) return false;
    if (_items.length != other._items.length) return false;
    for (var i = 0; i < _items.length; i++) {
      if (_items[i] != other._items[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => _items.fold(0, (h, e) => h ^ e.hashCode);

  @override
  String toString() => '[${_items.join(', ')}]';
}
