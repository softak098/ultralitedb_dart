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
///
/// Maps to C# LiteCollection<T>.
class LiteCollection<T> {
  final String _name;
  final UltraLiteEngine _engine;
  final BsonMapper _mapper;

  final BsonAutoId autoId;

  LiteCollection(
    this._name,
    this._engine,
    this._mapper, {
    this.autoId = BsonAutoId.objectId,
  });

  // ── Insert ────────────────────────────────────────────────────────────────

  BsonValue insert(T item) => _engine.insert(_name, _toDoc(item), autoId);

  List<BsonValue> insertAll(Iterable<T> items) =>
      _engine.insertBulk(_name, items.map(_toDoc), autoId: autoId);

  // ── Update ────────────────────────────────────────────────────────────────

  bool update(T item) => _engine.update(_name, _toDoc(item));

  // ── Delete ────────────────────────────────────────────────────────────────

  bool deleteById(BsonValue id) => _engine.delete(_name, id);

  int deleteMany(Query query) => _engine.deleteMany(_name, query);

  // ── Find ──────────────────────────────────────────────────────────────────

  Iterable<T> find({
    Query? query,
    int skip = 0,
    int limit = -1,
    int order = Query.ascending,
  }) => _engine
      .find(_name, query: query, skip: skip, limit: limit, order: order)
      .map(_fromDoc);

  T? findById(BsonValue id) {
    final doc = _engine.findById(_name, id);
    return doc == null ? null : _fromDoc(doc);
  }

  T? findOne(Query query) {
    final doc = _engine.findOne(_name, query);
    return doc == null ? null : _fromDoc(doc);
  }

  List<T> findAll({int order = Query.ascending}) => find(order: order).toList();

  int count([Query? query]) => _engine.count(_name, query);

  bool exists(Query query) => _engine.exists(_name, query);

  // ── Index ─────────────────────────────────────────────────────────────────

  bool ensureIndex(String field, {bool unique = false}) =>
      _engine.ensureIndex(_name, field, unique: unique);

  bool dropIndex(String field) => _engine.dropIndex(_name, field);

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
