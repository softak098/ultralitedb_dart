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

  factory UltraLiteDatabase.file(String filename, {FileOptions? options, String? password, BsonMapper? mapper}) =>
      UltraLiteDatabase._(
        UltraLiteEngine.file(filename, options: options, password: password),
        mapper: mapper,
      );

  factory UltraLiteDatabase.memory({BsonMapper? mapper}) => UltraLiteDatabase._(UltraLiteEngine.memory(), mapper: mapper);

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

  bool dropCollection(String name) => _engine.dropCollection(name);

  bool renameCollection(String oldName, String newName) => _engine.renameCollection(oldName, newName);

  // ── Transactions ──────────────────────────────────────────────────────────

  bool beginTrans() => _engine.beginTrans();
  bool commit() => _engine.commit();
  bool rollback() => _engine.rollback();

  /// Runs [action] inside a single explicit transaction.
  /// Commits on success; rolls back on any exception.
  T runInTransaction<T>(T Function() action) {
    beginTrans();
    try {
      final result = action();
      commit();
      return result;
    } catch (_) {
      rollback();
      rethrow;
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void dispose() => _engine.dispose();
}
