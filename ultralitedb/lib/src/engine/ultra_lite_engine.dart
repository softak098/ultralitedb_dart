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

  factory UltraLiteEngine.file(String filename, {FileOptions? options, String? password}) =>
      UltraLiteEngine._open(FileDiskService(filename, options: options), password: password);

  factory UltraLiteEngine.memory() => UltraLiteEngine._open(StreamDiskService());

  factory UltraLiteEngine._open(IDiskService disk, {String? password}) {
    final cache = CacheService();
    final pager = PageService(disk, cache);
    final data = DataService(pager);
    final indexer = IndexService(pager);
    final trans = TransactionService(disk, pager);
    final colSvc = CollectionService(pager, indexer);

    return UltraLiteEngine._(disk: disk, cache: cache, pager: pager, data: data, indexer: indexer, trans: trans, colSvc: colSvc)
      .._initialize(password);
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

  void _initialize([String? password]) {
    _pager.initialize(password);
    _trans.begin(); // engine always starts with an open auto-transaction
  }

  // ── Insert ────────────────────────────────────────────────────────────────

  /// Inserts [doc] into [collection]. Auto-generates `_id` if absent.
  /// Returns the `_id` value.
  BsonValue insert(String collection, BsonDocument doc, [BsonAutoId autoId = BsonAutoId.objectId]) {
    _assertAlive();
    final col = _colSvc.getOrCreate(collection);

    if (!doc.containsKey('_id') || doc['_id'].isNull) {
      doc['_id'] = _generateId(col, autoId);
    }

    final block = _data.insert(col, doc);

    for (final idx in col.indexes.where((i) => i.isNotEmpty)) {
      _indexer.addNode(idx, Query.getFieldValue(doc, idx.field), block.position);
    }

    _autoCommit();
    return doc['_id'];
  }

  /// Inserts all [docs] inside a single transaction.
  /// Returns the list of generated `_id` values.
  List<BsonValue> insertBulk(String collection, Iterable<BsonDocument> docs, {BsonAutoId autoId = BsonAutoId.objectId}) {
    _assertAlive();

    // If caller is already managing a transaction, just forward each insert.
    if (_userTransaction) {
      return docs.map((d) => insert(collection, d, autoId)).toList();
    }

    // Otherwise wrap in one explicit transaction.
    beginTrans();
    try {
      final ids = docs.map((d) => insert(collection, d, autoId)).toList();
      commit();
      return ids;
    } catch (_) {
      rollback();
      rethrow;
    }
  }

  // ── Update ────────────────────────────────────────────────────────────────

  /// Updates the document identified by `doc['_id']`.
  /// Returns `true` if found and updated.
  bool update(String collection, BsonDocument doc) {
    _assertAlive();
    final col = _colSvc.get(collection);
    if (col == null) return false;

    final id = doc['_id'];
    if (id.isNull) return false;

    final pkNode = _findExact(col.pk, id);
    if (pkNode == null) return false;

    final oldAddr = pkNode.dataBlock;
    final block = _data.update(col, oldAddr, doc);

    // Rebuild non-pk index entries pointing to old data block
    for (final idx in col.indexes.where((i) => i.isNotEmpty && !i.isPK)) {
      final old = _scanForBlock(idx, oldAddr);
      if (old != null) _indexer.deleteNode(old);
      _indexer.addNode(idx, Query.getFieldValue(doc, idx.field), block.position);
    }

    // Update pk node's data pointer to new block location
    pkNode.dataBlock = block.position;
    _pager.setDirty(pkNode.page!);

    _autoCommit();
    return true;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Deletes the document with [id]. Returns `true` if found and deleted.
  bool delete(String collection, BsonValue id) {
    _assertAlive();
    final col = _colSvc.get(collection);
    if (col == null) return false;

    final pkNode = _findExact(col.pk, id);
    if (pkNode == null) return false;

    final addr = pkNode.dataBlock;

    for (final idx in col.indexes.where((i) => i.isNotEmpty)) {
      if (idx.isPK) {
        _indexer.deleteNode(pkNode);
      } else {
        final n = _scanForBlock(idx, addr);
        if (n != null) _indexer.deleteNode(n);
      }
    }

    _data.delete(col, addr);
    _autoCommit();
    return true;
  }

  /// Deletes all documents matching [query]. Returns count deleted.
  int deleteMany(String collection, Query query) {
    _assertAlive();
    // Collect all ids first to avoid mutating the index during iteration.
    final ids = find(collection, query: query).map((d) => d['_id']).toList();
    for (final id in ids) {
      delete(collection, id);
    }
    return ids.length;
  }

  // ── Find ──────────────────────────────────────────────────────────────────

  /// Returns a lazy [Iterable] of matching documents.
  /// Uses the best available index; falls back to a full _id-index scan.
  Iterable<BsonDocument> find(String collection, {Query? query, int skip = 0, int limit = -1, int order = Query.ascending}) {
    _assertAlive();
    final col = _colSvc.get(collection);
    if (col == null) return const [];
    return _executeQuery(col, query ?? Query.all(), skip, limit, order);
  }

  /// Returns the document whose `_id` == [id], or `null`.
  BsonDocument? findById(String collection, BsonValue id) {
    _assertAlive();
    final col = _colSvc.get(collection);
    if (col == null) return null;
    final node = _findExact(col.pk, id);
    return node == null ? null : _data.read(node.dataBlock);
  }

  /// Returns the first document matching [query], or `null`.
  BsonDocument? findOne(String collection, Query query) => find(collection, query: query, limit: 1).firstOrNull;

  /// Count of documents matching [query] (all documents if [query] is null).
  int count(String collection, [Query? query]) {
    _assertAlive();
    final col = _colSvc.get(collection);
    if (col == null) return 0;
    if (query == null) return col.documentCount;
    return find(collection, query: query).length;
  }

  /// `true` if at least one document matches [query].
  bool exists(String collection, Query query) => find(collection, query: query, limit: 1).isNotEmpty;

  // ── Index DDL ─────────────────────────────────────────────────────────────

  /// Creates an index on [field] if it does not already exist.
  /// Back-fills the index from existing documents.
  /// Returns `true` if created, `false` if it already existed.
  bool ensureIndex(String collection, String field, {bool unique = false}) {
    _assertAlive();
    final col = _colSvc.getOrCreate(collection);
    if (col.getIndex(field) != null) return false;

    final idx = _indexer.createIndex(col, field, unique);

    for (final node in _indexer.findAll(col.pk, Query.ascending)) {
      final doc = _data.read(node.dataBlock);
      _indexer.addNode(idx, Query.getFieldValue(doc, field), node.dataBlock);
    }

    _autoCommit();
    return true;
  }

  /// Drops the index for [field]. Returns `true` if it existed.
  bool dropIndex(String collection, String field) {
    _assertAlive();
    if (field == '_id') throw ArgumentError('Cannot drop the _id index');
    final col = _colSvc.get(collection);
    if (col == null) return false;
    final idx = col.getIndex(field);
    if (idx == null) return false;
    _indexer.dropIndex(idx);
    _autoCommit();
    return true;
  }

  // ── Collection DDL ────────────────────────────────────────────────────────

  bool dropCollection(String collection) {
    _assertAlive();
    if (_colSvc.get(collection) == null) return false;
    _colSvc.drop(collection);
    _autoCommit();
    return true;
  }

  bool renameCollection(String oldName, String newName) {
    _assertAlive();
    if (_colSvc.get(oldName) == null) return false;
    _colSvc.rename(oldName, newName);
    _autoCommit();
    return true;
  }

  List<String> getCollectionNames() => _pager.header.collections.keys.toList();

  // ── Explicit transactions ─────────────────────────────────────────────────

  /// Switches to explicit-transaction mode.
  /// Returns `false` if already in explicit-transaction mode.
  bool beginTrans() {
    if (_userTransaction) return false;
    if (_trans.isActive) _trans.commit(); // flush pending auto-tx
    _trans.begin();
    _userTransaction = true;
    return true;
  }

  /// Commits the explicit transaction. Returns `false` if not in one.
  bool commit() {
    if (!_userTransaction) return false;
    _trans.commit();
    _userTransaction = false;
    _trans.begin(); // restart auto-tx
    return true;
  }

  /// Rolls back the explicit transaction. Returns `false` if not in one.
  bool rollback() {
    if (!_userTransaction) return false;
    _trans.rollback();
    _userTransaction = false;
    _trans.begin();
    return true;
  }

  /// Commit + begin a new transaction (auto-mode only; no-op in explicit mode).
  void checkpoint() {
    if (!_userTransaction) _trans.checkpoint();
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  void dispose() {
    if (_disposed) return;
    if (_trans.isActive) _trans.commit();
    _disk.dispose();
    _disposed = true;
  }

  // ── Private — transaction helpers ─────────────────────────────────────────

  void _assertAlive() {
    if (_disposed) throw StateError('UltraLiteEngine has been disposed');
  }

  void _autoCommit() {
    if (!_userTransaction) {
      _trans.commit();
      _trans.begin();
    }
  }

  // ── Private — query execution ─────────────────────────────────────────────

  Iterable<BsonDocument> _executeQuery(CollectionPage col, Query query, int skip, int limit, int order) sync* {
    // Choose the best index for this query.
    // Logical queries (And/Or/Not) have field == '' → always fall back to pk.
    final useIdx = query is QueryAll ? col.pk : (col.getIndex(query.field) ?? col.pk);

    // Only do index-optimized seek/early-exit when the index field matches.
    final indexed = query is! QueryAll && useIdx.field == query.field;

    // Determine starting PageAddress
    PageAddress startAddr;
    if (order == Query.ascending && indexed) {
      startAddr = _seekStart(useIdx, query); // binary-search to lower bound
    } else if (order == Query.ascending) {
      startAddr = useIdx.head;
    } else {
      startAddr = useIdx.tail;
    }

    var addr = order == Query.ascending ? _indexer.getNode(startAddr).next[0] : _indexer.getNode(startAddr).prev[0];

    int skipped = 0;
    int yielded = 0;

    while (!addr.isEmpty) {
      final node = _indexer.getNode(addr);

      // Sentinel guard — stop at head / tail
      if (node.key.isMinValue || node.key.isMaxValue) break;

      // Early termination: skip nodes that are provably past the upper bound
      if (order == Query.ascending && indexed && _isPastUpperBound(query, node.key)) {
        break;
      }

      final doc = _data.read(node.dataBlock);

      if (query.filterDocument(doc)) {
        if (skipped < skip) {
          skipped++;
        } else {
          yield doc;
          if (limit > 0 && ++yielded >= limit) return;
        }
      }

      addr = order == Query.ascending ? node.next[0] : node.prev[0];
    }
  }

  /// Returns the position of the predecessor node (last node whose key < lower
  /// bound of [query]), so the caller can advance to the first candidate.
  PageAddress _seekStart(CollectionIndex idx, Query query) {
    final BsonValue? lowerBound = switch (query) {
      QueryEquals q => q.value,
      QueryGreater q => q.value,
      QueryBetween q => q.start,
      _ => null,
    };
    if (lowerBound == null) return idx.head;
    return _indexer.find(idx, lowerBound, sibling: false).position;
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
  IndexNode? _findExact(CollectionIndex idx, BsonValue value) {
    final pred = _indexer.find(idx, value, sibling: false);
    if (pred.next[0].isEmpty) return null;
    final candidate = _indexer.getNode(pred.next[0]);
    if (candidate.key.isMaxValue) return null;
    return candidate.key == value ? candidate : null;
  }

  /// Level-0 linear scan to find the node pointing at [addr].
  IndexNode? _scanForBlock(CollectionIndex idx, PageAddress addr) {
    var cur = _indexer.getNode(idx.head).next[0];
    while (!cur.isEmpty) {
      final node = _indexer.getNode(cur);
      if (node.key.isMaxValue) break;
      if (node.dataBlock == addr) return node;
      cur = node.next[0];
    }
    return null;
  }

  // ── Private — id generation ───────────────────────────────────────────────

  BsonValue _generateId(CollectionPage col, BsonAutoId autoId) => switch (autoId) {
    BsonAutoId.objectId => BsonValue.fromObjectId(ObjectId.newObjectId()),
    BsonAutoId.guid => BsonValue.fromBytes(Uint8List.fromList(List.generate(16, (_) => Random.secure().nextInt(256)))),
    BsonAutoId.int32 => BsonValue.fromInt(_nextIntId(col)),
    BsonAutoId.int64 => BsonValue.fromInt64(_nextIntId(col)),
  };

  /// Max existing int id + 1 (walks back from tail sentinel).
  int _nextIntId(CollectionPage col) {
    final tail = _indexer.getNode(col.pk.tail);
    final prev = tail.prev[0];
    if (prev.isEmpty) return 1;
    final last = _indexer.getNode(prev);
    if (last.key.isMinValue) return 1;
    return (last.key.asInt64 ?? last.key.asInt32 ?? 0) + 1;
  }
}
