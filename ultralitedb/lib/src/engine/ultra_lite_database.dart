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
/// final db = UltraLiteDatabase.file('app.db');
/// final users = db.getCollection('users');
/// users.insert(BsonDocument({'name': BsonValue.fromString('Alice')}));
/// db.dispose();
///
/// // In-memory (tests / ephemeral)
/// final db = UltraLiteDatabase.memory();
/// ```
///
/// Maps to C# LiteDatabase.
class UltraLiteDatabase {
  final UltraLiteEngine _engine;

  /// The [BsonMapper] used by all collections created through this database.
  final BsonMapper mapper;

  // ── Factories ─────────────────────────────────────────────────────────────

  static Future<UltraLiteDatabase> file(String filename, {FileOptions? options, String? password, BsonMapper? mapper}) async {
    final engine = await UltraLiteEngine.file(filename, options: options, password: password);
    return UltraLiteDatabase._(engine, mapper: mapper);
  }

  static Future<UltraLiteDatabase> memory({BsonMapper? mapper}) async {
    final engine = await UltraLiteEngine.memory();
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

  Future<bool> renameCollection(String oldName, String newName) => _engine.renameCollection(oldName, newName);

  // ── Transactions ──────────────────────────────────────────────────────────

  Future<bool> beginTrans() => _engine.beginTrans();
  Future<bool> commit() => _engine.commit();
  Future<void> rollback() => _engine.rollback();

  /// Runs [action] inside a single explicit transaction.
  /// Commits on success; rolls back on any exception.
  Future<T> runInTransaction<T>(Future<T> Function() action) async {
    beginTrans();
    try {
      final result = await action();
      await commit();
      return result;
    } catch (_) {
      await rollback();
      rethrow;
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> dispose() => _engine.dispose();
}
