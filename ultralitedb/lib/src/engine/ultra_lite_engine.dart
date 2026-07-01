import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../bson/bson_auto_id.dart';
import '../bson/bson_value.dart';
import '../bson/objectid.dart';
import 'disks/file_disk_service.dart';
import 'disks/file_options.dart';
import 'disks/stream_disk_service.dart';
import 'pages/collection_page.dart';
import 'pages/data_page.dart';
import 'pages/index_page.dart';
import 'query/query.dart';
import 'services/cache_service.dart';
import 'services/collection_service.dart';
import 'services/data_service.dart';
import 'services/disk_service.dart';
import 'services/index_service.dart';
import 'services/page_service.dart';
import 'services/transaction_service.dart';
import 'structures/page_address.dart';

/// Low-level database engine — all operations work directly with [BsonDocument].
///
/// Transaction model:
///   - An auto-transaction is always open.
///   - Each DML call auto-commits unless [beginTrans] was called first.
///   - [beginTrans] / [commit] / [rollback] switch to explicit-transaction mode.
///   - [dispose] commits any pending work and releases resources.
///
/// Maps to C# UltraLiteEngine.
class UltraLiteEngine {
  final IDiskService _disk;
  final CacheService _cache;
  final PageService _pager;
  final DataService _data;
  final IndexService _indexer;
  final TransactionService _trans;
  final CollectionService _colSvc;

  bool _disposed = false;
  bool _userTransaction = false; // true while in explicit-transaction mode

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Sync version of FutureOr methods ──────────────────────────────────────

  static T _sync<T>(FutureOr<T> value) {
    if (value is Future<T>) {
      throw StateError(
        'Expected synchronous result, but got Future. '
        'Ensure database was opened with sync-compatible options (e.g. syncIO: true or memory).',
      );
    }
    return value;
  }

  // ── Factory constructors ──────────────────────────────────────────────────

  static Future<UltraLiteEngine> file(String filename, {FileOptions? options, String? password}) async {
    return await _open(FileDiskService(filename, options: options), password: password);
  }

  static UltraLiteEngine fileSync(String filename, {FileOptions? options, String? password}) {
    return _sync(_open(FileDiskService(filename, options: options), password: password));
  }

  static Future<UltraLiteEngine> memory() async {
    return await _open(StreamDiskService());
  }

  static UltraLiteEngine memorySync() {
    return _sync(_open(StreamDiskService()));
  }

  static FutureOr<UltraLiteEngine> _open(IDiskService disk, {String? password}) {
    final cache = CacheService();
    final pager = PageService(disk, cache);
    final data = DataService(pager);
    final indexer = IndexService(pager);
    final trans = TransactionService(disk, pager);
    final colSvc = CollectionService(pager, indexer);

    final engine = UltraLiteEngine._(
      disk: disk,
      cache: cache,
      pager: pager,
      data: data,
      indexer: indexer,
      trans: trans,
      colSvc: colSvc,
    );
    return engine._then(engine._initialize(password), (_) => engine);
  }

  UltraLiteEngine._({
    required this._disk,
    required this._cache,
    required this._pager,
    required this._data,
    required this._indexer,
    required this._trans,
    required this._colSvc,
  });

  FutureOr<void> _initialize([String? password]) {
    return _then(_pager.initialize(password), (_) {
      _trans.begin(); // engine always starts with an open auto-transaction
    });
  }

  // ── Insert ────────────────────────────────────────────────────────────────

  /// Inserts [doc] into [collection]. Auto-generates `_id` if absent.
  /// Returns the `_id` value.
  Future<BsonValue> insert(String collection, BsonDocument doc, [BsonAutoId autoId = BsonAutoId.objectId]) async {
    return await _insertInternal(collection, doc, autoId);
  }

  BsonValue insertSync(String collection, BsonDocument doc, [BsonAutoId autoId = BsonAutoId.objectId]) {
    return _sync(_insertInternal(collection, doc, autoId));
  }

  FutureOr<BsonValue> _insertInternal(String collection, BsonDocument doc, [BsonAutoId autoId = BsonAutoId.objectId]) {
    _assertAlive();
    final colRes = _colSvc.getOrCreate(collection);
    if (colRes is Future<CollectionPage>) {
      return colRes.then((col) => _insertWithCol(col, doc, autoId));
    }
    return _insertWithCol(colRes, doc, autoId);
  }

  FutureOr<BsonValue> _insertWithCol(CollectionPage col, BsonDocument doc, BsonAutoId autoId) {
    if (!doc.containsKey('_id') || doc['_id'].isNull) {
      final idRes = _generateId(col, autoId);
      if (idRes is Future<BsonValue>) {
        return idRes.then((id) {
          doc['_id'] = id;
          return _doInsert(col, doc);
        });
      }
      doc['_id'] = idRes;
    }
    return _doInsert(col, doc);
  }

  FutureOr<BsonValue> _doInsert(CollectionPage col, BsonDocument doc) {
    final blockRes = _data.insert(col, doc);
    if (blockRes is Future<DataBlock>) {
      return blockRes.then((block) => _doInsertNodes(col, doc, block.position));
    }
    return _doInsertNodes(col, doc, blockRes.position);
  }

  FutureOr<BsonValue> _doInsertNodes(CollectionPage col, BsonDocument doc, PageAddress blockAddr) {
    final res = _addNodes(col.indexes, 0, doc, blockAddr);
    if (res is Future<void>) {
      return res.then((_) => _doInsertCommit(doc['_id']));
    }
    return _doInsertCommit(doc['_id']);
  }

  FutureOr<BsonValue> _doInsertCommit(BsonValue id) {
    final res = _autoCommit();
    if (res is Future<void>) {
      return res.then((_) => id);
    }
    return id;
  }

  FutureOr<void> _addNodes(List<CollectionIndex> indexes, int index, BsonDocument doc, PageAddress blockAddr) {
    var i = index;
    while (i < indexes.length) {
      final idx = indexes[i];
      if (idx.isEmpty) {
        i++;
        continue;
      }
      final res = _indexer.addNode(idx, Query.getFieldValue(doc, idx.field), blockAddr);
      if (res is Future<IndexNode>) {
        return res.then((_) => _addNodes(indexes, i + 1, doc, blockAddr));
      }
      i++;
    }
    return null;
  }

  /// Inserts all [docs] inside a single transaction.
  /// Returns the list of generated `_id` values.
  Future<List<BsonValue>> insertBulk(
    String collection,
    Iterable<BsonDocument> docs, {
    BsonAutoId autoId = BsonAutoId.objectId,
  }) async {
    return await _insertBulkInternal(collection, docs, autoId: autoId);
  }

  List<BsonValue> insertBulkSync(String collection, Iterable<BsonDocument> docs, {BsonAutoId autoId = BsonAutoId.objectId}) {
    return _sync(_insertBulkInternal(collection, docs, autoId: autoId));
  }

  FutureOr<List<BsonValue>> _insertBulkInternal(
    String collection,
    Iterable<BsonDocument> docs, {
    BsonAutoId autoId = BsonAutoId.objectId,
  }) {
    _assertAlive();

    final docsList = docs.toList();

    // If caller is already managing a transaction, just forward each insert.
    if (_userTransaction) {
      return _insertBulkLoop(collection, docsList, 0, autoId, []);
    }

    // Otherwise wrap in one explicit transaction.
    beginTransSync();
    final res = _then(_insertBulkLoop(collection, docsList, 0, autoId, []), (results) {
      return _then(commitInternal(), (_) => results);
    });

    if (res is Future<List<BsonValue>>) {
      return res.catchError((e) {
        return _then(rollbackInternal(), (_) => throw e);
      });
    }
    return res;
  }

  FutureOr<List<BsonValue>> _insertBulkLoop(
    String collection,
    List<BsonDocument> docs,
    int index,
    BsonAutoId autoId,
    List<BsonValue> results,
  ) {
    var i = index;
    while (i < docs.length) {
      final res = _insertInternal(collection, docs[i], autoId);
      if (res is Future<BsonValue>) {
        return res.then((id) {
          results.add(id);
          return _insertBulkLoop(collection, docs, i + 1, autoId, results);
        });
      }
      results.add(res);
      i++;
    }
    return results;
  }

  // ── Update ────────────────────────────────────────────────────────────────

  /// Updates the document identified by `doc['_id']`.
  /// Returns `true` if found and updated.
  Future<bool> update(String collection, BsonDocument doc) async {
    return await _updateInternal(collection, doc);
  }

  bool updateSync(String collection, BsonDocument doc) {
    return _sync(_updateInternal(collection, doc));
  }

  FutureOr<bool> _updateInternal(String collection, BsonDocument doc) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return false;

      final id = doc['_id'];
      if (id.isNull) return false;

      return _then(_findExact(col.pk, id), (pkNode) {
        if (pkNode == null) return false;

        final oldAddr = pkNode.dataBlock;
        return _then(_data.update(col, oldAddr, doc), (block) {
          // Rebuild non-pk index entries pointing to old data block
          final otherIndexes = col.indexes.where((i) => i.isNotEmpty && !i.isPK).toList();
          return _then(_rebuildOtherIndexes(otherIndexes, 0, oldAddr, doc, block.position), (_) {
            // Update pk node's data pointer to new block location
            pkNode.dataBlock = block.position;
            _pager.setDirty(pkNode.page!);

            return _then(_autoCommit(), (_) => true);
          });
        });
      });
    });
  }

  FutureOr<void> _rebuildOtherIndexes(
    List<CollectionIndex> indexes,
    int index,
    PageAddress oldAddr,
    BsonDocument doc,
    PageAddress newAddr,
  ) {
    var i = index;
    while (i < indexes.length) {
      final idx = indexes[i];
      final res = _then(_scanForBlock(idx, oldAddr), (old) {
        return _then(old != null ? _indexer.deleteNode(old) : null, (_) {
          return _indexer.addNode(idx, Query.getFieldValue(doc, idx.field), newAddr);
        });
      });

      if (res is Future) {
        return (res as Future).then((_) => _rebuildOtherIndexes(indexes, i + 1, oldAddr, doc, newAddr));
      }
      i++;
    }
    return null;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Deletes the document with [id]. Returns `true` if found and deleted.
  Future<bool> delete(String collection, BsonValue id) async {
    return await _deleteInternal(collection, id);
  }

  bool deleteSync(String collection, BsonValue id) {
    return _sync(_deleteInternal(collection, id));
  }

  FutureOr<bool> _deleteInternal(String collection, BsonValue id) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return false;

      return _then(_findExact(col.pk, id), (pkNode) {
        if (pkNode == null) return false;

        final addr = pkNode.dataBlock;
        final indexes = col.indexes.where((i) => i.isNotEmpty).toList();

        return _then(_deleteFromIndexes(indexes, 0, addr, pkNode), (_) {
          return _then(_data.delete(col, addr), (_) {
            return _then(_autoCommit(), (_) => true);
          });
        });
      });
    });
  }

  // ... (keeping _deleteFromIndexes as is as it is private)

  FutureOr<void> _deleteFromIndexes(List<CollectionIndex> indexes, int index, PageAddress addr, IndexNode pkNode) {
    var i = index;
    while (i < indexes.length) {
      final idx = indexes[i];
      FutureOr<void> res;
      if (idx.isPK) {
        res = _indexer.deleteNode(pkNode);
      } else {
        res = _then(_scanForBlock(idx, addr), (n) {
          return n != null ? _indexer.deleteNode(n) : null;
        });
      }

      if (res is Future) {
        return res.then((_) => _deleteFromIndexes(indexes, i + 1, addr, pkNode));
      }
      i++;
    }
    return null;
  }

  /// Deletes all documents matching [query]. Returns count deleted.
  Future<int> deleteMany(String collection, Query query) async {
    return await _deleteManyInternal(collection, query);
  }

  int deleteManySync(String collection, Query query) {
    return _sync(_deleteManyInternal(collection, query));
  }

  FutureOr<int> _deleteManyInternal(String collection, Query query) {
    _assertAlive();
    // Collect all ids first to avoid mutating the index during iteration.
    return _then(_findInternal(collection, query: query), (docs) {
      final ids = docs.map((d) => d['_id']).toList();
      return _deleteManyLoop(collection, ids, 0);
    });
  }

  FutureOr<int> _deleteManyLoop(String collection, List<BsonValue> ids, int index) {
    var i = index;
    while (i < ids.length) {
      final res = _deleteInternal(collection, ids[i]);
      if (res is Future<bool>) {
        return res.then((_) => _deleteManyLoop(collection, ids, i + 1));
      }
      i++;
    }
    return ids.length;
  }

  // ── Find ──────────────────────────────────────────────────────────────────

  /// Returns matching documents.
  /// Uses the best available index; falls back to a full _id-index scan.
  Future<Iterable<BsonDocument>> find(
    String collection, {
    Query? query,
    int skip = 0,
    int limit = -1,
    int order = Query.ascending,
  }) async {
    return await _findInternal(collection, query: query, skip: skip, limit: limit, order: order);
  }

  Iterable<BsonDocument> findSync(String collection, {Query? query, int skip = 0, int limit = -1, int order = Query.ascending}) {
    return _sync(_findInternal(collection, query: query, skip: skip, limit: limit, order: order));
  }

  FutureOr<Iterable<BsonDocument>> _findInternal(
    String collection, {
    Query? query,
    int skip = 0,
    int limit = -1,
    int order = Query.ascending,
  }) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return const [];
      return _executeQuery(col, query ?? Query.all(), skip, limit, order);
    });
  }

  /// Returns the document whose `_id` == [id], or `null`.
  Future<BsonDocument?> findById(String collection, BsonValue id) async {
    return await _findByIdInternal(collection, id);
  }

  BsonDocument? findByIdSync(String collection, BsonValue id) {
    return _sync(_findByIdInternal(collection, id));
  }

  FutureOr<BsonDocument?> _findByIdInternal(String collection, BsonValue id) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return null;
      return _then(_findExact(col.pk, id), (node) {
        return node == null ? null : _data.read(node.dataBlock);
      });
    });
  }

  /// Returns the first document matching [query], or `null`.
  Future<BsonDocument?> findOne(String collection, Query query) async {
    return await _findOneInternal(collection, query);
  }

  BsonDocument? findOneSync(String collection, Query query) {
    return _sync(_findOneInternal(collection, query));
  }

  FutureOr<BsonDocument?> _findOneInternal(String collection, Query query) {
    return _then(_findInternal(collection, query: query, limit: 1), (docs) {
      return docs.firstOrNull;
    });
  }

  /// Count of documents matching [query] (all documents if [query] is null).
  Future<int> count(String collection, [Query? query]) async {
    return await _countInternal(collection, query);
  }

  int countSync(String collection, [Query? query]) {
    return _sync(_countInternal(collection, query));
  }

  FutureOr<int> _countInternal(String collection, [Query? query]) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return 0;
      if (query == null) return col.documentCount;
      return _then(_findInternal(collection, query: query), (docs) => docs.length);
    });
  }

  /// `true` if at least one document matches [query].
  Future<bool> exists(String collection, Query query) async {
    return await _existsInternal(collection, query);
  }

  bool existsSync(String collection, Query query) {
    return _sync(_existsInternal(collection, query));
  }

  FutureOr<bool> _existsInternal(String collection, Query query) {
    return _then(_findInternal(collection, query: query, limit: 1), (docs) => docs.isNotEmpty);
  }

  // ── Index DDL ─────────────────────────────────────────────────────────────

  /// Creates an index on [field] if it does not already exist.
  /// Back-fills the index from existing documents.
  /// Returns `true` if created, `false` if it already existed.
  Future<bool> ensureIndex(String collection, String field, {bool unique = false}) async {
    return await _ensureIndexInternal(collection, field, unique: unique);
  }

  bool ensureIndexSync(String collection, String field, {bool unique = false}) {
    return _sync(_ensureIndexInternal(collection, field, unique: unique));
  }

  FutureOr<bool> _ensureIndexInternal(String collection, String field, {bool unique = false}) {
    _assertAlive();
    return _then(_colSvc.getOrCreate(collection), (col) {
      if (col.getIndex(field) != null) return false;

      return _then(_indexer.createIndex(col, field, unique), (idx) {
        return _then(_indexer.findAll(col.pk, Query.ascending), (pkNodes) {
          return _then(_backfillIndexLoop(idx, field, pkNodes.toList(), 0), (_) {
            return _then(_autoCommit(), (_) => true);
          });
        });
      });
    });
  }

  // ... (keeping _backfillIndexLoop as is)

  FutureOr<void> _backfillIndexLoop(CollectionIndex idx, String field, List<IndexNode> pkNodes, int index) {
    var i = index;
    while (i < pkNodes.length) {
      final node = pkNodes[i];
      final res = _then(_data.read(node.dataBlock), (doc) {
        return _indexer.addNode(idx, Query.getFieldValue(doc, field), node.dataBlock);
      });

      if (res is Future) {
        return (res as Future).then((_) => _backfillIndexLoop(idx, field, pkNodes, i + 1));
      }
      i++;
    }
    return null;
  }

  /// Drops the index for [field]. Returns `true` if it existed.
  Future<bool> dropIndex(String collection, String field) async {
    return await _dropIndexInternal(collection, field);
  }

  bool dropIndexSync(String collection, String field) {
    return _sync(_dropIndexInternal(collection, field));
  }

  FutureOr<bool> _dropIndexInternal(String collection, String field) {
    _assertAlive();
    if (field == '_id') throw ArgumentError('Cannot drop the _id index');
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return false;
      final idx = col.getIndex(field);
      if (idx == null) return false;
      return _then(_indexer.dropIndex(idx), (_) {
        return _then(_autoCommit(), (_) => true);
      });
    });
  }

  // ── Collection DDL ────────────────────────────────────────────────────────

  Future<bool> dropCollection(String collection) async {
    return await _dropCollectionInternal(collection);
  }

  bool dropCollectionSync(String collection) {
    return _sync(_dropCollectionInternal(collection));
  }

  FutureOr<bool> _dropCollectionInternal(String collection) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return false;
      return _then(_colSvc.drop(collection), (_) {
        return _then(_autoCommit(), (_) => true);
      });
    });
  }

  Future<bool> renameCollection(String oldName, String newName) async {
    return await _renameCollectionInternal(oldName, newName);
  }

  bool renameCollectionSync(String oldName, String newName) {
    return _sync(_renameCollectionInternal(oldName, newName));
  }

  FutureOr<bool> _renameCollectionInternal(String oldName, String newName) {
    _assertAlive();
    return _then(_colSvc.get(oldName), (col) {
      if (col == null) return false;
      return _then(_colSvc.rename(oldName, newName), (_) {
        return _then(_autoCommit(), (_) => true);
      });
    });
  }

  List<String> getCollectionNames() => _pager.header.collections.keys.toList();

  // ── Explicit transactions ─────────────────────────────────────────────────

  /// Switches to explicit-transaction mode.
  /// Returns `false` if already in explicit-transaction mode.
  Future<bool> beginTrans() async {
    return await beginTransInternal();
  }

  bool beginTransSync() {
    return _sync(beginTransInternal());
  }

  FutureOr<bool> beginTransInternal() {
    if (_userTransaction) return false;
    if (_trans.isActive) {
      return _then(_trans.commit(), (_) {
        _trans.begin();
        _userTransaction = true;
        return true;
      });
    }
    _trans.begin();
    _userTransaction = true;
    return true;
  }

  /// Commits the explicit transaction. Returns `false` if not in one.
  Future<bool> commit() async {
    return await commitInternal();
  }

  bool commitSync() {
    return _sync(commitInternal());
  }

  FutureOr<bool> commitInternal() {
    if (!_userTransaction) return false;
    return _then(_trans.commit(), (_) {
      _userTransaction = false;
      _trans.begin(); // restart auto-tx
      return true;
    });
  }

  /// Rolls back the explicit transaction. Returns `false` if not in one.
  Future<bool> rollback() async {
    return await rollbackInternal();
  }

  bool rollbackSync() {
    return _sync(rollbackInternal());
  }

  FutureOr<bool> rollbackInternal() {
    if (!_userTransaction) return false;
    return _then(_trans.rollback(), (_) {
      _userTransaction = false;
      _trans.begin();
      return true;
    });
  }

  /// Commit + begin a new transaction (auto-mode only; no-op in explicit mode).
  Future<void> checkpoint() async {
    await checkpointInternal();
  }

  void checkpointSync() {
    _sync(checkpointInternal());
  }

  FutureOr<void> checkpointInternal() {
    if (!_userTransaction) return _trans.checkpoint();
    return null;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    await disposeInternal();
  }

  void disposeSync() {
    _sync(disposeInternal());
  }

  FutureOr<void> disposeInternal() {
    if (_disposed) return null;
    return _then(_trans.isActive ? _trans.commit() : null, (_) {
      return _then(_disk.dispose(), (_) {
        _disposed = true;
      });
    });
  }

  // ── Private — transaction helpers ─────────────────────────────────────────

  void _assertAlive() {
    if (_disposed) throw StateError('UltraLiteEngine has been disposed');
  }

  FutureOr<void> _autoCommit() {
    if (!_userTransaction) {
      return _then(_trans.commit(), (_) {
        _trans.begin();
      });
    }
    return null;
  }

  // ── Private — query execution ─────────────────────────────────────────────

  FutureOr<Iterable<BsonDocument>> _executeQuery(CollectionPage col, Query query, int skip, int limit, int order) {
    // Choose the best index for this query.
    // Logical queries (And/Or/Not) have field == '' → always fall back to pk.
    final useIdx = query is QueryAll ? col.pk : (col.getIndex(query.field) ?? col.pk);

    // Only do index-optimized seek/early-exit when the index field matches.
    final indexed = query is! QueryAll && useIdx.field == query.field;

    // Determine starting PageAddress
    return _then(
      indexed && order == Query.ascending ? _seekStart(useIdx, query) : (order == Query.ascending ? useIdx.head : useIdx.tail),
      (startAddr) {
        return _then(_indexer.getNode(startAddr), (startNode) {
          final initialAddr = order == Query.ascending ? startNode.next[0] : startNode.prev[0];
          return _scanQueryNodes(initialAddr, query, indexed, order, skip, limit, 0, 0, []);
        });
      },
    );
  }

  FutureOr<List<BsonDocument>> _scanQueryNodes(
    PageAddress addr,
    Query query,
    bool indexed,
    int order,
    int skip,
    int limit,
    int skipped,
    int yielded,
    List<BsonDocument> results,
  ) {
    var curAddr = addr;
    var curSkipped = skipped;
    var curYielded = yielded;

    while (!curAddr.isEmpty) {
      final nodeRes = _indexer.getNode(curAddr);
      if (nodeRes is Future<IndexNode>) {
        return nodeRes.then(
          (node) => _handleQueryNode(node, curAddr, query, indexed, order, skip, limit, curSkipped, curYielded, results),
        );
      }

      final node = nodeRes;
      if (node.key.isMinValue || node.key.isMaxValue) return results;
      if (order == Query.ascending && indexed && _isPastUpperBound(query, node.key)) return results;

      final docRes = _data.read(node.dataBlock);
      if (docRes is Future<BsonDocument>) {
        return docRes.then((doc) {
          if (query.filterDocument(doc)) {
            if (curSkipped < skip) {
              curSkipped++;
            } else {
              results.add(doc);
              curYielded++;
              if (limit > 0 && curYielded >= limit) return results;
            }
          }
          final nextAddr = order == Query.ascending ? node.next[0] : node.prev[0];
          return _scanQueryNodes(nextAddr, query, indexed, order, skip, limit, curSkipped, curYielded, results);
        });
      }

      final doc = docRes;
      if (query.filterDocument(doc)) {
        if (curSkipped < skip) {
          curSkipped++;
        } else {
          results.add(doc);
          curYielded++;
          if (limit > 0 && curYielded >= limit) return results;
        }
      }
      curAddr = order == Query.ascending ? node.next[0] : node.prev[0];
    }
    return results;
  }

  FutureOr<List<BsonDocument>> _handleQueryNode(
    IndexNode node,
    PageAddress addr,
    Query query,
    bool indexed,
    int order,
    int skip,
    int limit,
    int skipped,
    int yielded,
    List<BsonDocument> results,
  ) {
    if (node.key.isMinValue || node.key.isMaxValue) return results;
    if (order == Query.ascending && indexed && _isPastUpperBound(query, node.key)) return results;

    return _then(_data.read(node.dataBlock), (doc) {
      var nextSkipped = skipped;
      var nextYielded = yielded;

      if (query.filterDocument(doc)) {
        if (nextSkipped < skip) {
          nextSkipped++;
        } else {
          results.add(doc);
          nextYielded++;
          if (limit > 0 && nextYielded >= limit) return results;
        }
      }

      final nextAddr = order == Query.ascending ? node.next[0] : node.prev[0];
      return _scanQueryNodes(nextAddr, query, indexed, order, skip, limit, nextSkipped, nextYielded, results);
    });
  }

  /// Returns the position of the predecessor node (last node whose key < lower
  /// bound of [query]), so the caller can advance to the first candidate.
  FutureOr<PageAddress> _seekStart(CollectionIndex idx, Query query) {
    final BsonValue? lowerBound = switch (query) {
      QueryEquals q => q.value,
      QueryGreater q => q.value,
      QueryBetween q => q.start,
      _ => null,
    };
    if (lowerBound == null) return idx.head;
    return _then(_indexer.find(idx, lowerBound, sibling: false), (node) => node.position);
  }

  /// `true` when [key] is provably past the upper bound of [query].
  bool _isPastUpperBound(Query query, BsonValue key) => switch (query) {
    QueryEquals q => key > q.value,
    QueryLess q => q.isEquals ? key > q.value : key >= q.value,
    QueryBetween q => q.endEquals ? key > q.end : key >= q.end,
    _ => false,
  };

  // ── Private — index helpers ───────────────────────────────────────────────

  /// Binary-search exact match in a skip-list index.
  FutureOr<IndexNode?> _findExact(CollectionIndex idx, BsonValue value) {
    return _then(_indexer.find(idx, value, sibling: false), (pred) {
      if (pred.next[0].isEmpty) return null;
      return _then(_indexer.getNode(pred.next[0]), (candidate) {
        if (candidate.key.isMaxValue) return null;
        return candidate.key == value ? candidate : null;
      });
    });
  }

  /// Scan an index for a node pointing to [block].
  FutureOr<IndexNode?> _scanForBlock(CollectionIndex idx, PageAddress block) {
    return _then(_indexer.findAll(idx, Query.ascending), (nodes) {
      for (final node in nodes) {
        if (node.dataBlock == block) return node;
      }
      return null;
    });
  }

  // ── Private — id generation ───────────────────────────────────────────────

  FutureOr<BsonValue> _generateId(CollectionPage col, BsonAutoId autoId) => switch (autoId) {
    BsonAutoId.objectId => BsonValue.fromObjectId(ObjectId.newObjectId()),
    BsonAutoId.guid => BsonValue.fromBytes(Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)))),
    BsonAutoId.int32 => _then(_nextIntId(col), (id) => BsonValue.fromInt(id)),
    BsonAutoId.int64 => _then(_nextIntId(col), (id) => BsonValue.fromInt64(id)),
  };

  /// Max existing int id + 1 (walks back from tail sentinel).
  FutureOr<int> _nextIntId(CollectionPage col) {
    return _then(_indexer.getNode(col.pk.tail), (tail) {
      final prev = tail.prev[0];
      if (prev.isEmpty) return 1;
      return _then(_indexer.getNode(prev), (last) {
        if (last.key.isMinValue) return 1;
        return (last.key.asInt64 ?? last.key.asInt32 ?? 0) + 1;
      });
    });
  }
}
