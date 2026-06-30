import 'dart:async';
import '../bson/bson_auto_id.dart';
import '../bson/bson_mapper.dart';
import '../bson/bson_value.dart';
import 'disks/file_options.dart';
import 'lite_collection.dart';
import 'ultra_lite_engine.dart';

/// High-level database facade combining [UltraLiteEngine] with [BsonMapper].
///
/// ```dart
/// // File-backed
/// final db = await UltraLiteDatabase.file('app.db');
/// final users = db.getCollection('users');
/// await users.insert(BsonDocument({'name': BsonValue.fromString('Alice')}));
/// await db.dispose();
///
/// // In-memory (tests / ephemeral)
/// final db = await UltraLiteDatabase.memory();
/// ```
class UltraLiteDatabase {
  final UltraLiteEngine _engine;

  /// The [BsonMapper] used by all collections created through this database.
  final BsonMapper mapper;

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  static FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Factories ─────────────────────────────────────────────────────────────

  static FutureOr<UltraLiteDatabase> file(String filename, {FileOptions? options, String? password, BsonMapper? mapper}) {
    return _then(UltraLiteEngine.file(filename, options: options, password: password), (engine) {
      return UltraLiteDatabase._(engine, mapper: mapper);
    });
  }

  static FutureOr<UltraLiteDatabase> memory({BsonMapper? mapper}) {
    return _then(UltraLiteEngine.memory(), (engine) {
      return UltraLiteDatabase._(engine, mapper: mapper);
    });
  }

  UltraLiteDatabase._(UltraLiteEngine engine, {BsonMapper? mapper}) : _engine = engine, mapper = mapper ?? BsonMapper.global;

  // ── Collection access ─────────────────────────────────────────────────────

  /// Untyped [BsonDocument] collection.
  LiteCollection<BsonDocument> getCollection(String name, {BsonAutoId autoId = BsonAutoId.objectId}) =>
      LiteCollection<BsonDocument>(name, _engine, mapper, autoId: autoId);

  /// Typed collection — [T] must be [BsonDocument], [Map<String,dynamic>],
  /// or registered with [mapper] via [BsonMapper.registerType].
  LiteCollection<T> getTypedCollection<T>(String name, {BsonAutoId autoId = BsonAutoId.objectId}) =>
      LiteCollection<T>(name, _engine, mapper, autoId: autoId);

  // ── Database operations ───────────────────────────────────────────────────

  List<String> getCollectionNames() => _engine.getCollectionNames();

  bool collectionExists(String name) => _engine.getCollectionNames().contains(name);

  FutureOr<bool> dropCollection(String name) => _engine.dropCollection(name);

  FutureOr<bool> renameCollection(String oldName, String newName) => _engine.renameCollection(oldName, newName);

  // ── Transactions ──────────────────────────────────────────────────────────

  FutureOr<bool> beginTrans() => _engine.beginTrans();
  FutureOr<bool> commit() => _engine.commit();
  FutureOr<void> rollback() => _engine.rollback();

  /// Runs [action] inside a single explicit transaction.
  /// Commits on success; rolls back on any exception.
  FutureOr<T> runInTransaction<T>(FutureOr<T> Function() action) {
    return _then(beginTrans(), (_) {
      final res = action();
      final finalRes = _then(res, (val) {
        return _then(commit(), (_) => val);
      });

      if (finalRes is Future<T>) {
        return finalRes.catchError((e) {
          return _then(rollback(), (_) => throw e);
        });
      }
      return finalRes;
    });
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  FutureOr<void> dispose() => _engine.dispose();
}
