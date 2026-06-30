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

  // ── Factory constructors ──────────────────────────────────────────────────

  static FutureOr<UltraLiteEngine> file(String filename, {FileOptions? options, String? password}) {
    return _open(FileDiskService(filename, options: options), password: password);
  }

  static FutureOr<UltraLiteEngine> memory() {
    return _open(StreamDiskService());
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
  FutureOr<BsonValue> insert(String collection, BsonDocument doc, [BsonAutoId autoId = BsonAutoId.objectId]) {
    _assertAlive();
    return _then(_colSvc.getOrCreate(collection), (col) {
      if (!doc.containsKey('_id') || doc['_id'].isNull) {
        return _then(_generateId(col, autoId), (id) {
          doc['_id'] = id;
          return _doInsert(col, doc);
        });
      }
      return _doInsert(col, doc);
    });
  }

  FutureOr<BsonValue> _doInsert(CollectionPage col, BsonDocument doc) {
    return _then(_data.insert(col, doc), (block) {
      return _then(_addNodes(col.indexes.where((i) => i.isNotEmpty).toList(), 0, doc, block.position), (_) {
        return _then(_autoCommit(), (_) => doc['_id']);
      });
    });
  }

  FutureOr<void> _addNodes(List<CollectionIndex> indexes, int index, BsonDocument doc, PageAddress blockAddr) {
    var i = index;
    while (i < indexes.length) {
      final idx = indexes[i];
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
  FutureOr<List<BsonValue>> insertBulk(
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
    beginTrans();
    final res = _then(_insertBulkLoop(collection, docsList, 0, autoId, []), (results) {
      return _then(commit(), (_) => results);
    });

    if (res is Future<List<BsonValue>>) {
      return res.catchError((e) {
        return _then(rollback(), (_) => throw e);
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
      final res = insert(collection, docs[i], autoId);
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
  FutureOr<bool> update(String collection, BsonDocument doc) {
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
  FutureOr<bool> delete(String collection, BsonValue id) {
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
  FutureOr<int> deleteMany(String collection, Query query) {
    _assertAlive();
    // Collect all ids first to avoid mutating the index during iteration.
    return _then(find(collection, query: query), (docs) {
      final ids = docs.map((d) => d['_id']).toList();
      return _deleteManyLoop(collection, ids, 0);
    });
  }

  FutureOr<int> _deleteManyLoop(String collection, List<BsonValue> ids, int index) {
    var i = index;
    while (i < ids.length) {
      final res = delete(collection, ids[i]);
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
  FutureOr<Iterable<BsonDocument>> find(
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
  FutureOr<BsonDocument?> findById(String collection, BsonValue id) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return null;
      return _then(_findExact(col.pk, id), (node) {
        return node == null ? null : _data.read(node.dataBlock);
      });
    });
  }

  /// Returns the first document matching [query], or `null`.
  FutureOr<BsonDocument?> findOne(String collection, Query query) {
    return _then(find(collection, query: query, limit: 1), (docs) {
      return docs.firstOrNull;
    });
  }

  /// Count of documents matching [query] (all documents if [query] is null).
  FutureOr<int> count(String collection, [Query? query]) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return 0;
      if (query == null) return col.documentCount;
      return _then(find(collection, query: query), (docs) => docs.length);
    });
  }

  /// `true` if at least one document matches [query].
  FutureOr<bool> exists(String collection, Query query) {
    return _then(find(collection, query: query, limit: 1), (docs) => docs.isNotEmpty);
  }

  // ── Index DDL ─────────────────────────────────────────────────────────────

  /// Creates an index on [field] if it does not already exist.
  /// Back-fills the index from existing documents.
  /// Returns `true` if created, `false` if it already existed.
  FutureOr<bool> ensureIndex(String collection, String field, {bool unique = false}) {
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
  FutureOr<bool> dropIndex(String collection, String field) {
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

  FutureOr<bool> dropCollection(String collection) {
    _assertAlive();
    return _then(_colSvc.get(collection), (col) {
      if (col == null) return false;
      return _then(_colSvc.drop(collection), (_) {
        return _then(_autoCommit(), (_) => true);
      });
    });
  }

  FutureOr<bool> renameCollection(String oldName, String newName) {
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
  FutureOr<bool> beginTrans() {
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
  FutureOr<bool> commit() {
    if (!_userTransaction) return false;
    return _then(_trans.commit(), (_) {
      _userTransaction = false;
      _trans.begin(); // restart auto-tx
      return true;
    });
  }

  /// Rolls back the explicit transaction. Returns `false` if not in one.
  FutureOr<bool> rollback() {
    if (!_userTransaction) return false;
    return _then(_trans.rollback(), (_) {
      _userTransaction = false;
      _trans.begin();
      return true;
    });
  }

  /// Commit + begin a new transaction (auto-mode only; no-op in explicit mode).
  FutureOr<void> checkpoint() {
    if (!_userTransaction) return _trans.checkpoint();
    return null;
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  FutureOr<void> dispose() {
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
