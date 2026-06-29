import 'dart:math';
import 'dart:typed_data';

import '../bson/bson_auto_id.dart';
import '../bson/bson_value.dart';
import '../bson/objectid.dart';
import 'disks/file_disk_service.dart';
import 'disks/file_options.dart';
import 'disks/stream_disk_service.dart';
import 'pages/collection_page.dart';
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

  // ── Factory constructors ──────────────────────────────────────────────────

  static Future<UltraLiteEngine> file(String filename, {FileOptions? options, String? password}) async =>
      await UltraLiteEngine._open(FileDiskService(filename, options: options), password: password);

  static Future<UltraLiteEngine> memory() async => await UltraLiteEngine._open(StreamDiskService());

  static Future<UltraLiteEngine> _open(IDiskService disk, {String? password}) async {
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
    await engine._initialize(password);
    return engine;
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

  Future<void> _initialize([String? password]) async {
    await _pager.initialize(password);
    _trans.begin(); // engine always starts with an open auto-transaction
  }

  // ── Insert ────────────────────────────────────────────────────────────────

  /// Inserts [doc] into [collection]. Auto-generates `_id` if absent.
  /// Returns the `_id` value.
  Future<BsonValue> insert(String collection, BsonDocument doc, [BsonAutoId autoId = BsonAutoId.objectId]) async {
    _assertAlive();
    final col = await _colSvc.getOrCreate(collection);

    if (!doc.containsKey('_id') || doc['_id'].isNull) {
      doc['_id'] = _generateId(col, autoId);
    }

    final block = await _data.insert(col, doc);

    for (final idx in col.indexes.where((i) => i.isNotEmpty)) {
      await _indexer.addNode(idx, Query.getFieldValue(doc, idx.field), block.position);
    }

    await _autoCommit();
    return doc['_id'];
  }

  /// Inserts all [docs] inside a single transaction.
  /// Returns the list of generated `_id` values.
  Future<List<BsonValue>> insertBulk(
    String collection,
    Iterable<BsonDocument> docs, {
    BsonAutoId autoId = BsonAutoId.objectId,
  }) async {
    _assertAlive();

    // If caller is already managing a transaction, just forward each insert.
    if (_userTransaction) {
      final results = <BsonValue>[];
      for (final doc in docs) {
        results.add(await insert(collection, doc, autoId));
      }
      return results;
    }

    // Otherwise wrap in one explicit transaction.
    beginTrans();
    try {
      final results = <BsonValue>[];
      for (final doc in docs) {
        results.add(await insert(collection, doc, autoId));
      }
      await commit();
      return results;
    } catch (_) {
      await rollback();
      rethrow;
    }
  }

  // ── Update ────────────────────────────────────────────────────────────────

  /// Updates the document identified by `doc['_id']`.
  /// Returns `true` if found and updated.
  Future<bool> update(String collection, BsonDocument doc) async {
    _assertAlive();
    final col = await _colSvc.get(collection);
    if (col == null) return false;

    final id = doc['_id'];
    if (id.isNull) return false;

    final pkNode = await _findExact(col.pk, id);
    if (pkNode == null) return false;

    final oldAddr = pkNode.dataBlock;
    final block = await _data.update(col, oldAddr, doc);

    // Rebuild non-pk index entries pointing to old data block
    for (final idx in col.indexes.where((i) => i.isNotEmpty && !i.isPK)) {
      final old = await _scanForBlock(idx, oldAddr);
      if (old != null) await _indexer.deleteNode(old);
      await _indexer.addNode(idx, Query.getFieldValue(doc, idx.field), block.position);
    }

    // Update pk node's data pointer to new block location
    pkNode.dataBlock = block.position;
    _pager.setDirty(pkNode.page!);

    await _autoCommit();
    return true;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Deletes the document with [id]. Returns `true` if found and deleted.
  Future<bool> delete(String collection, BsonValue id) async {
    _assertAlive();
    final col = await _colSvc.get(collection);
    if (col == null) return false;

    final pkNode = await _findExact(col.pk, id);
    if (pkNode == null) return false;

    final addr = pkNode.dataBlock;

    for (final idx in col.indexes.where((i) => i.isNotEmpty)) {
      if (idx.isPK) {
        await _indexer.deleteNode(pkNode);
      } else {
        final n = await _scanForBlock(idx, addr);
        if (n != null) await _indexer.deleteNode(n);
      }
    }

    await _data.delete(col, addr);
    await _autoCommit();
    return true;
  }

  /// Deletes all documents matching [query]. Returns count deleted.
  Future<int> deleteMany(String collection, Query query) async {
    _assertAlive();
    // Collect all ids first to avoid mutating the index during iteration.
    final docs = await find(collection, query: query);
    final ids = docs.map((d) => d['_id']).toList();
    for (final id in ids) {
      await delete(collection, id);
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
    _assertAlive();
    final col = await _colSvc.get(collection);
    if (col == null) return const [];
    return await _executeQuery(col, query ?? Query.all(), skip, limit, order);
  }

  /// Returns the document whose `_id` == [id], or `null`.
  Future<BsonDocument?> findById(String collection, BsonValue id) async {
    _assertAlive();
    final col = await _colSvc.get(collection);
    if (col == null) return null;
    final node = await _findExact(col.pk, id);
    return node == null ? null : await _data.read(node.dataBlock);
  }

  /// Returns the first document matching [query], or `null`.
  Future<BsonDocument?> findOne(String collection, Query query) async {
    final docs = await find(collection, query: query, limit: 1);
    return docs.firstOrNull;
  }

  /// Count of documents matching [query] (all documents if [query] is null).
  Future<int> count(String collection, [Query? query]) async {
    _assertAlive();
    final col = await _colSvc.get(collection);
    if (col == null) return 0;
    if (query == null) return col.documentCount;
    final docs = await find(collection, query: query);
    return docs.length;
  }

  /// `true` if at least one document matches [query].
  Future<bool> exists(String collection, Query query) async {
    final docs = await find(collection, query: query, limit: 1);
    return docs.isNotEmpty;
  }

  // ── Index DDL ─────────────────────────────────────────────────────────────

  /// Creates an index on [field] if it does not already exist.
  /// Back-fills the index from existing documents.
  /// Returns `true` if created, `false` if it already existed.
  Future<bool> ensureIndex(String collection, String field, {bool unique = false}) async {
    _assertAlive();
    final col = await _colSvc.getOrCreate(collection);
    if (col.getIndex(field) != null) return false;

    final idx = await _indexer.createIndex(col, field, unique);

    for (final node in await _indexer.findAll(col.pk, Query.ascending)) {
      final doc = await _data.read(node.dataBlock);
      await _indexer.addNode(idx, Query.getFieldValue(doc, field), node.dataBlock);
    }

    await _autoCommit();
    return true;
  }

  /// Drops the index for [field]. Returns `true` if it existed.
  Future<bool> dropIndex(String collection, String field) async {
    _assertAlive();
    if (field == '_id') throw ArgumentError('Cannot drop the _id index');
    final col = await _colSvc.get(collection);
    if (col == null) return false;
    final idx = col.getIndex(field);
    if (idx == null) return false;
    await _indexer.dropIndex(idx);
    await _autoCommit();
    return true;
  }

  // ── Collection DDL ────────────────────────────────────────────────────────

  Future<bool> dropCollection(String collection) async {
    _assertAlive();
    if ((await _colSvc.get(collection)) == null) return false;
    await _colSvc.drop(collection);
    await _autoCommit();
    return true;
  }

  Future<bool> renameCollection(String oldName, String newName) async {
    _assertAlive();
    if ((await _colSvc.get(oldName)) == null) return false;
    await _colSvc.rename(oldName, newName);
    await _autoCommit();
    return true;
  }

  List<String> getCollectionNames() => _pager.header.collections.keys.toList();

  // ── Explicit transactions ─────────────────────────────────────────────────

  /// Switches to explicit-transaction mode.
  /// Returns `false` if already in explicit-transaction mode.
  Future<bool> beginTrans() async {
    if (_userTransaction) return false;
    if (_trans.isActive) await _trans.commit(); // flush pending auto-tx
    _trans.begin();
    _userTransaction = true;
    return true;
  }

  /// Commits the explicit transaction. Returns `false` if not in one.
  Future<bool> commit() async {
    if (!_userTransaction) return false;
    await _trans.commit();
    _userTransaction = false;
    _trans.begin(); // restart auto-tx
    return true;
  }

  /// Rolls back the explicit transaction. Returns `false` if not in one.
  Future<bool> rollback() async {
    if (!_userTransaction) return false;
    await _trans.rollback();
    _userTransaction = false;
    _trans.begin();
    return true;
  }

  /// Commit + begin a new transaction (auto-mode only; no-op in explicit mode).
  Future<void> checkpoint() async {
    if (!_userTransaction) await _trans.checkpoint();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  Future<void> dispose() async {
    if (_disposed) return;
    if (_trans.isActive) await _trans.commit();
    await _disk.dispose();
    _disposed = true;
  }

  // ── Private — transaction helpers ─────────────────────────────────────────

  void _assertAlive() {
    if (_disposed) throw StateError('UltraLiteEngine has been disposed');
  }

  Future<void> _autoCommit() async {
    if (!_userTransaction) {
      await _trans.commit();
      _trans.begin();
    }
  }

  // ── Private — query execution ─────────────────────────────────────────────

  Future<Iterable<BsonDocument>> _executeQuery(CollectionPage col, Query query, int skip, int limit, int order) async {
    // Choose the best index for this query.
    // Logical queries (And/Or/Not) have field == '' → always fall back to pk.
    final useIdx = query is QueryAll ? col.pk : (col.getIndex(query.field) ?? col.pk);

    // Only do index-optimized seek/early-exit when the index field matches.
    final indexed = query is! QueryAll && useIdx.field == query.field;

    // Determine starting PageAddress
    PageAddress startAddr;
    if (order == Query.ascending && indexed) {
      startAddr = await _seekStart(useIdx, query); // binary-search to lower bound
    } else if (order == Query.ascending) {
      startAddr = useIdx.head;
    } else {
      startAddr = useIdx.tail;
    }

    var addr = order == Query.ascending
        ? (await _indexer.getNode(startAddr)).next[0]
        : (await _indexer.getNode(startAddr)).prev[0];

    int skipped = 0;
    int yielded = 0;
    final results = <BsonDocument>[];

    while (!addr.isEmpty) {
      final node = await _indexer.getNode(addr);

      // Sentinel guard — stop at head / tail
      if (node.key.isMinValue || node.key.isMaxValue) break;

      // Early termination: skip nodes that are provably past the upper bound
      if (order == Query.ascending && indexed && _isPastUpperBound(query, node.key)) {
        break;
      }

      final doc = await _data.read(node.dataBlock);

      if (query.filterDocument(doc)) {
        if (skipped < skip) {
          skipped++;
        } else {
          results.add(doc);
          if (limit > 0 && ++yielded >= limit) break;
        }
      }

      addr = order == Query.ascending ? node.next[0] : node.prev[0];
    }

    return results;
  }

  /// Returns the position of the predecessor node (last node whose key < lower
  /// bound of [query]), so the caller can advance to the first candidate.
  Future<PageAddress> _seekStart(CollectionIndex idx, Query query) async {
    final BsonValue? lowerBound = switch (query) {
      QueryEquals q => q.value,
      QueryGreater q => q.value,
      QueryBetween q => q.start,
      _ => null,
    };
    if (lowerBound == null) return idx.head;
    return (await _indexer.find(idx, lowerBound, sibling: false)).position;
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
  Future<IndexNode?> _findExact(CollectionIndex idx, BsonValue value) async {
    final pred = await _indexer.find(idx, value, sibling: false);
    if (pred.next[0].isEmpty) return null;
    final candidate = await _indexer.getNode(pred.next[0]);
    if (candidate.key.isMaxValue) return null;
    return candidate.key == value ? candidate : null;
  }

  /// Scan an index for a node pointing to [block].
  Future<IndexNode?> _scanForBlock(CollectionIndex idx, PageAddress block) async {
    for (final node in await _indexer.findAll(idx, Query.ascending)) {
      if (node.dataBlock == block) return node;
    }
    return null;
  }

  //   /// Level-0 linear scan to find the node pointing at [addr].
  //   IndexNode? _scanForBlock(CollectionIndex idx, PageAddress addr) {
  //     var cur = _indexer.getNode(idx.head).next[0];
  //     while (!cur.isEmpty) {
  //       final node = _indexer.getNode(cur);
  //       if (node.key.isMaxValue) break;
  //       if (node.dataBlock == addr) return node;
  //       cur = node.next[0];
  //     }
  //     return null;
  //   }

  // ── Private — id generation ───────────────────────────────────────────────

  Future<BsonValue> _generateId(CollectionPage col, BsonAutoId autoId) async => switch (autoId) {
    BsonAutoId.objectId => BsonValue.fromObjectId(ObjectId.newObjectId()),
    BsonAutoId.guid => BsonValue.fromBytes(Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)))),
    BsonAutoId.int32 => BsonValue.fromInt(await _nextIntId(col)),
    BsonAutoId.int64 => BsonValue.fromInt64(await _nextIntId(col)),
  };

  /// Max existing int id + 1 (walks back from tail sentinel).
  Future<int> _nextIntId(CollectionPage col) async {
    final tail = await _indexer.getNode(col.pk.tail);
    final prev = tail.prev[0];
    if (prev.isEmpty) return 1;
    final last = await _indexer.getNode(prev);
    if (last.key.isMinValue) return 1;
    return (last.key.asInt64 ?? last.key.asInt32 ?? 0) + 1;
  }
}
