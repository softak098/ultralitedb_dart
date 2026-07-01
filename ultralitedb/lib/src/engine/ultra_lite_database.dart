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

  static Future<UltraLiteDatabase> file(String filename, {FileOptions? options, String? password, BsonMapper? mapper}) async {
    final engine = await UltraLiteEngine.file(filename, options: options, password: password);
    return UltraLiteDatabase._(engine, mapper: mapper);
  }

  static UltraLiteDatabase fileSync(String filename, {FileOptions? options, String? password, BsonMapper? mapper}) {
    final engine = UltraLiteEngine.fileSync(filename, options: options, password: password);
    return UltraLiteDatabase._(engine, mapper: mapper);
  }

  static Future<UltraLiteDatabase> memory({BsonMapper? mapper}) async {
    final engine = await UltraLiteEngine.memory();
    return UltraLiteDatabase._(engine, mapper: mapper);
  }

  static UltraLiteDatabase memorySync({BsonMapper? mapper}) {
    final engine = UltraLiteEngine.memorySync();
    return UltraLiteDatabase._(engine, mapper: mapper);
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

  Future<bool> dropCollection(String name) => _engine.dropCollection(name);
  bool dropCollectionSync(String name) => _engine.dropCollectionSync(name);

  Future<bool> renameCollection(String oldName, String newName) => _engine.renameCollection(oldName, newName);
  bool renameCollectionSync(String oldName, String newName) => _engine.renameCollectionSync(oldName, newName);

  // ── Transactions ──────────────────────────────────────────────────────────

  Future<bool> beginTrans() => _engine.beginTrans();
  bool beginTransSync() => _engine.beginTransSync();

  Future<bool> commit() => _engine.commit();
  bool commitSync() => _engine.commitSync();

  Future<void> rollback() => _engine.rollback();
  void rollbackSync() => _engine.rollbackSync();

  /// Runs [action] inside a single explicit transaction.
  /// Commits on success; rolls back on any exception.
  Future<T> runInTransaction<T>(Future<T> Function() action) async {
    await beginTrans();
    try {
      final val = await action();
      await commit();
      return val;
    } catch (e) {
      await rollback();
      rethrow;
    }
  }

  /// Synchronous version of [runInTransaction].
  T runInTransactionSync<T>(T Function() action) {
    beginTransSync();
    try {
      final val = action();
      commitSync();
      return val;
    } catch (e) {
      rollbackSync();
      rethrow;
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> dispose() => _engine.dispose();
  void disposeSync() => _engine.disposeSync();
}
