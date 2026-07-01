import 'dart:async';
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

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  FutureOr<R> _then<T1, R>(FutureOr<T1> value, FutureOr<R> Function(T1) action) {
    if (value is Future<T1>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Insert ────────────────────────────────────────────────────────────────

  Future<BsonValue> insert(T item) => _engine.insert(_name, _toDoc(item), autoId);
  BsonValue insertSync(T item) => _engine.insertSync(_name, _toDoc(item), autoId);

  Future<List<BsonValue>> insertAll(Iterable<T> items) => _engine.insertBulk(_name, items.map(_toDoc), autoId: autoId);
  List<BsonValue> insertAllSync(Iterable<T> items) => _engine.insertBulkSync(_name, items.map(_toDoc), autoId: autoId);

  // ── Update ────────────────────────────────────────────────────────────────

  Future<bool> update(T item) => _engine.update(_name, _toDoc(item));
  bool updateSync(T item) => _engine.updateSync(_name, _toDoc(item));

  // ── Delete ────────────────────────────────────────────────────────────────

  Future<bool> deleteById(BsonValue id) => _engine.delete(_name, id);
  bool deleteByIdSync(BsonValue id) => _engine.deleteSync(_name, id);

  Future<int> deleteMany(Query query) => _engine.deleteMany(_name, query);
  int deleteManySync(Query query) => _engine.deleteManySync(_name, query);

  // ── Find ──────────────────────────────────────────────────────────────────

  Future<Iterable<T>> find({Query? query, int skip = 0, int limit = -1, int order = Query.ascending}) async {
    final docs = await _engine.find(_name, query: query, skip: skip, limit: limit, order: order);
    return docs.map(_fromDoc);
  }

  Iterable<T> findSync({Query? query, int skip = 0, int limit = -1, int order = Query.ascending}) {
    final docs = _engine.findSync(_name, query: query, skip: skip, limit: limit, order: order);
    return docs.map(_fromDoc);
  }

  Future<T?> findById(BsonValue id) async {
    final doc = await _engine.findById(_name, id);
    return doc == null ? null : _fromDoc(doc);
  }

  T? findByIdSync(BsonValue id) {
    final doc = _engine.findByIdSync(_name, id);
    return doc == null ? null : _fromDoc(doc);
  }

  Future<T?> findOne(Query query) async {
    final doc = await _engine.findOne(_name, query);
    return doc == null ? null : _fromDoc(doc);
  }

  T? findOneSync(Query query) {
    final doc = _engine.findOneSync(_name, query);
    return doc == null ? null : _fromDoc(doc);
  }

  Future<List<T>> findAll({int order = Query.ascending}) async {
    final results = await find(order: order);
    return results.toList();
  }

  List<T> findAllSync({int order = Query.ascending}) {
    final results = findSync(order: order);
    return results.toList();
  }

  Future<int> count([Query? query]) => _engine.count(_name, query);
  int countSync([Query? query]) => _engine.countSync(_name, query);

  Future<bool> exists(Query query) => _engine.exists(_name, query);
  bool existsSync(Query query) => _engine.existsSync(_name, query);

  // ── Index ─────────────────────────────────────────────────────────────────

  Future<bool> ensureIndex(String field, {bool unique = false}) => _engine.ensureIndex(_name, field, unique: unique);
  bool ensureIndexSync(String field, {bool unique = false}) => _engine.ensureIndexSync(_name, field, unique: unique);

  Future<bool> dropIndex(String field) => _engine.dropIndex(_name, field);
  bool dropIndexSync(String field) => _engine.dropIndexSync(_name, field);

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
