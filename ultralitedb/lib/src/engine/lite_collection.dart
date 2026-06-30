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

  FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Insert ────────────────────────────────────────────────────────────────

  FutureOr<BsonValue> insert(T item) => _engine.insert(_name, _toDoc(item), autoId);

  FutureOr<List<BsonValue>> insertAll(Iterable<T> items) => _engine.insertBulk(_name, items.map(_toDoc), autoId: autoId);

  // ── Update ────────────────────────────────────────────────────────────────

  FutureOr<bool> update(T item) => _engine.update(_name, _toDoc(item));

  // ── Delete ────────────────────────────────────────────────────────────────

  FutureOr<bool> deleteById(BsonValue id) => _engine.delete(_name, id);

  FutureOr<int> deleteMany(Query query) => _engine.deleteMany(_name, query);

  // ── Find ──────────────────────────────────────────────────────────────────

  FutureOr<Iterable<T>> find({Query? query, int skip = 0, int limit = -1, int order = Query.ascending}) {
    return _then(_engine.find(_name, query: query, skip: skip, limit: limit, order: order), (docs) {
      return docs.map(_fromDoc);
    });
  }

  FutureOr<T?> findById(BsonValue id) {
    return _then(_engine.findById(_name, id), (doc) {
      return doc == null ? null : _fromDoc(doc);
    });
  }

  FutureOr<T?> findOne(Query query) {
    return _then(_engine.findOne(_name, query), (doc) {
      return doc == null ? null : _fromDoc(doc);
    });
  }

  FutureOr<List<T>> findAll({int order = Query.ascending}) {
    return _then(find(order: order), (results) {
      return results.toList();
    });
  }

  FutureOr<int> count([Query? query]) => _engine.count(_name, query);

  FutureOr<bool> exists(Query query) => _engine.exists(_name, query);

  // ── Index ─────────────────────────────────────────────────────────────────

  FutureOr<bool> ensureIndex(String field, {bool unique = false}) => _engine.ensureIndex(_name, field, unique: unique);

  FutureOr<bool> dropIndex(String field) => _engine.dropIndex(_name, field);

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
