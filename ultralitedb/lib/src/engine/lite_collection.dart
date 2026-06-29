import '../bson/bson_auto_id.dart';
import '../bson/bson_mapper.dart';
import '../bson/bson_value.dart';
import 'query/query.dart';
import 'ultra_lite_engine.dart';

/// Typed collection over [UltraLiteEngine].
///
/// ```dart
/// final col = db.getCollection('users');       // BsonDocument
/// final col = db.getTypedCollection<User>('users'); // registered type
/// ```
class LiteCollection<T> {
  final String _name;
  final UltraLiteEngine _engine;
  final BsonMapper _mapper;

  final BsonAutoId autoId;

  LiteCollection(this._name, this._engine, this._mapper, {this.autoId = BsonAutoId.objectId});

  // ── Insert ────────────────────────────────────────────────────────────────

  Future<BsonValue> insert(T item) => _engine.insert(_name, _toDoc(item), autoId);

  Future<List<BsonValue>> insertAll(Iterable<T> items) => _engine.insertBulk(_name, items.map(_toDoc), autoId: autoId);

  // ── Update ────────────────────────────────────────────────────────────────

  Future<bool> update(T item) => _engine.update(_name, _toDoc(item));

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<bool> deleteById(BsonValue id) => _engine.delete(_name, id);

  Future<int> deleteMany(Query query) => _engine.deleteMany(_name, query);

  // ── Find ──────────────────────────────────────────────────────────────────

  Future<Iterable<T>> find({Query? query, int skip = 0, int limit = -1, int order = Query.ascending}) async {
    final docs = await _engine.find(_name, query: query, skip: skip, limit: limit, order: order);
    return docs.map(_fromDoc);
  }

  Future<T?> findById(BsonValue id) async {
    final doc = await _engine.findById(_name, id);
    return doc == null ? null : _fromDoc(doc);
  }

  Future<T?> findOne(Query query) async {
    final doc = await _engine.findOne(_name, query);
    return doc == null ? null : _fromDoc(doc);
  }

  Future<List<T>> findAll({int order = Query.ascending}) async {
    final results = await find(order: order);
    return results.toList();
  }

  Future<int> count([Query? query]) => _engine.count(_name, query);

  Future<bool> exists(Query query) => _engine.exists(_name, query);

  // ── Index ─────────────────────────────────────────────────────────────────

  Future<bool> ensureIndex(String field, {bool unique = false}) => _engine.ensureIndex(_name, field, unique: unique);

  Future<bool> dropIndex(String field) => _engine.dropIndex(_name, field);

  // ── Conversion helpers ────────────────────────────────────────────────────

  BsonDocument _toDoc(T item) {
    if (item is BsonDocument) return item;
    final v = _mapper.toBsonValue(item);
    if (v is BsonDocument) return v;
    throw ArgumentError(
      'BsonMapper: cannot convert $T to BsonDocument. '
      'Register a converter via BsonMapper.global.registerType<$T>().',
    );
  }

  T _fromDoc(BsonDocument doc) {
    // Fast path: no conversion needed
    if (T == BsonDocument) return doc as T;

    // Use registered converter or mapper's default fromBsonValue
    final result = _mapper.convertFrom<T>(doc);
    if (result is T) return result;
    throw StateError(
      'BsonMapper: cannot convert BsonDocument to $T. '
      'Register a converter via BsonMapper.global.registerType<$T>().',
    );
  }
}
