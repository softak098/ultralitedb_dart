import 'dart:async';
import 'dart:math';
import '../../bson/bson_value.dart';
import '../pages/collection_page.dart';
import '../pages/index_page.dart';
import '../structures/page_address.dart';
import '../query/query.dart';
import 'page_service.dart';

/// Maintains skip-list indexes over [CollectionPage] data.
/// Maps to C# IndexService.
class IndexService {
  final PageService _pager;
  static final Random _rng = Random();

  IndexService(this._pager);

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Index DDL ─────────────────────────────────────────────────────────────

  FutureOr<CollectionIndex> createIndex(CollectionPage col, String field, bool unique) {
    final idx = col.getFreeIndex();
    if (idx == null) throw StateError('Max index count reached for collection');

    idx.field = field;
    idx.unique = unique;

    // Create head (MinValue) and tail (MaxValue) sentinel nodes
    return _then(_allocateNode(idx, BsonValue.minValue, PageAddress.empty, IndexPage.maxLevels), (head) {
      return _then(_allocateNode(idx, BsonValue.maxValue, PageAddress.empty, IndexPage.maxLevels), (tail) {
        // Link sentinels: head ↔ tail at every level
        for (var i = 0; i < IndexPage.maxLevels; i++) {
          head.next[i] = tail.position;
          tail.prev[i] = head.position;
        }
        _pager.setDirty(head.page!);
        _pager.setDirty(tail.page!);

        idx.head = head.position;
        idx.tail = tail.position;
        _pager.setDirty(col);
        return idx;
      });
    });
  }

  FutureOr<void> dropIndex(CollectionIndex index) {
    return _then(_dropIndexRecursive(index.freeIndexPageID), (_) {
      index.field = '';
      index.unique = false;
      index.head = PageAddress.empty;
      index.tail = PageAddress.empty;
      index.freeIndexPageID = PageAddress.emptyPageId;
      if (index.page != null) _pager.setDirty(index.page!);
      return null;
    });
  }

  FutureOr<void> _dropIndexRecursive(int pageId) {
    if (pageId == PageAddress.emptyPageId) {
      return null;
    }

    return _then(_pager.getPage<IndexPage>(pageId), (page) {
      final nextId = page.nextPageID;
      _pager.freePage(page);
      return _dropIndexRecursive(nextId);
    });
  }

  // ── Node DML ──────────────────────────────────────────────────────────────

  /// Inserts a new skip-list node for [key] pointing to [dataBlock].
  FutureOr<IndexNode> addNode(CollectionIndex index, BsonValue key, PageAddress dataBlock) {
    final height = _randomHeight();

    // Walk from head, finding the insertion predecessor at each level
    return _then(getNode(index.head), (headNode) {
      return _then(_walkLevelsForInsert(headNode, key, height, IndexPage.maxLevels - 1, []), (updateList) {
        // Unique constraint check at level 0
        if (index.unique && !key.isMinValue && !key.isMaxValue) {
          if (!updateList[0].next[0].isEmpty) {
            return _then(getNode(updateList[0].next[0]), (candidate) {
              if (candidate.key == key) {
                throw StateError('Unique index "${index.field}" violation: duplicate key $key');
              }
              return _allocateAndInsertNode(index, key, dataBlock, height, updateList);
            });
          }
        }
        return _allocateAndInsertNode(index, key, dataBlock, height, updateList);
      });
    });
  }

  FutureOr<List<IndexNode>> _walkLevelsForInsert(IndexNode node, BsonValue key, int height, int level, List<IndexNode> update) {
    if (level < 0) {
      return update; // update list is built from level max down to 0
    }

    return _then(_walkLevelForInsert(node, key, level), (pred) {
      update.add(pred);
      return _walkLevelsForInsert(pred, key, height, level - 1, update);
    });
  }

  FutureOr<IndexNode> _walkLevelForInsert(IndexNode node, BsonValue key, int level) {
    if (level >= node.next.length || node.next[level].isEmpty) {
      return node;
    }

    return _then(getNode(node.next[level]), (nx) {
      if (nx.key >= key) {
        return node;
      }
      return _walkLevelForInsert(nx, key, level);
    });
  }

  FutureOr<IndexNode> _allocateAndInsertNode(
    CollectionIndex index,
    BsonValue key,
    PageAddress dataBlock,
    int height,
    List<IndexNode> update,
  ) {
    // Reverse update list because it was built from IndexPage.maxLevels-1 down to 0,
    // but we want update[i] to be the insertion predecessor at level i.
    final reversedUpdate = update.reversed.toList();

    return _then(_allocateNode(index, key, dataBlock, height), (newNode) {
      return _then(_spliceNodeAtLevel(newNode, reversedUpdate, 0), (_) => newNode);
    });
  }

  FutureOr<void> _spliceNodeAtLevel(IndexNode newNode, List<IndexNode> update, int level) {
    if (level >= newNode.levels) {
      return null;
    }

    final pred = update[level];
    final oldNext = level < pred.next.length ? pred.next[level] : PageAddress.empty;

    newNode.next[level] = oldNext;
    newNode.prev[level] = pred.position;

    return _then(
      oldNext.isEmpty
          ? null
          : _then(getNode(oldNext), (oldNextNode) {
              if (level < oldNextNode.prev.length) {
                oldNextNode.prev[level] = newNode.position;
                _pager.setDirty(oldNextNode.page!);
              }
              return null;
            }),
      (_) {
        if (level < pred.next.length) {
          pred.next[level] = newNode.position;
          _pager.setDirty(pred.page!);
        }
        _pager.setDirty(newNode.page!);
        return _spliceNodeAtLevel(newNode, update, level + 1);
      },
    );
  }

  /// Removes [node] from the skip-list and its page.
  FutureOr<void> deleteNode(IndexNode node) {
    return _then(_deleteNodeAtLevel(node, 0), (_) {
      node.page!.deleteNode(node.slot);
      _pager.setDirty(node.page!);
      return null;
    });
  }

  FutureOr<void> _deleteNodeAtLevel(IndexNode node, int level) {
    if (level >= node.levels) {
      return null;
    }

    final deletePrev = node.prev[level].isEmpty
        ? null
        : _then(getNode(node.prev[level]), (p) {
            if (level < p.next.length) {
              p.next[level] = node.next[level];
              _pager.setDirty(p.page!);
            }
            return null;
          });

    return _then(deletePrev, (_) {
      final deleteNext = node.next[level].isEmpty
          ? null
          : _then(getNode(node.next[level]), (n) {
              if (level < n.prev.length) {
                n.prev[level] = node.prev[level];
                _pager.setDirty(n.page!);
              }
              return null;
            });
      return _then(deleteNext, (_) => _deleteNodeAtLevel(node, level + 1));
    });
  }

  // ── Search ────────────────────────────────────────────────────────────────

  /// Loads the node at [address].
  FutureOr<IndexNode> getNode(PageAddress address) {
    return _then(_pager.getPage<IndexPage>(address.pageID), (page) {
      return page.getNode(address.index)!;
    });
  }

  /// Iterates all data nodes (excluding head/tail sentinels) in [order].
  FutureOr<Iterable<IndexNode>> findAll(CollectionIndex index, int order) {
    return _then(getNode(index.head), (head) {
      final tail = index.tail;
      if (order == Query.ascending) {
        return _findAllAscending(head.next[0], tail, []);
      } else {
        return _then(getNode(index.tail), (tailNode) {
          return _findAllDescending(tailNode.prev[0], index.head, []);
        });
      }
    });
  }

  FutureOr<List<IndexNode>> _findAllAscending(PageAddress addr, PageAddress tail, List<IndexNode> results) {
    var curAddr = addr;
    while (!curAddr.isEmpty && curAddr != tail) {
      final res = getNode(curAddr);
      if (res is Future<IndexNode>) {
        return res.then((node) {
          results.add(node);
          return _findAllAscending(node.next[0], tail, results);
        });
      }
      results.add(res);
      curAddr = res.next[0];
    }
    return results;
  }

  FutureOr<List<IndexNode>> _findAllDescending(PageAddress addr, PageAddress head, List<IndexNode> results) {
    var curAddr = addr;
    while (!curAddr.isEmpty && curAddr != head) {
      final res = getNode(curAddr);
      if (res is Future<IndexNode>) {
        return res.then((node) {
          results.add(node);
          return _findAllDescending(node.prev[0], head, results);
        });
      }
      results.add(res);
      curAddr = res.prev[0];
    }
    return results;
  }

  /// Binary-searches the skip-list for [value].
  /// Returns the last node whose key < [value] (exclusive) or
  /// the node whose key == [value] when [sibling] is `true`.
  FutureOr<IndexNode> find(CollectionIndex index, BsonValue value, {bool sibling = false}) {
    return _then(getNode(index.head), (headNode) {
      return _findAtLevel(headNode, value, sibling, IndexPage.maxLevels - 1);
    });
  }

  FutureOr<IndexNode> _findAtLevel(IndexNode node, BsonValue value, bool sibling, int level) {
    var current = node;
    var i = level;
    while (i >= 0) {
      final res = _findInLevel(current, value, sibling, i);
      if (res is Future<IndexNode>) {
        return res.then((next) => _findAtLevel(next, value, sibling, i - 1));
      }
      current = res;
      i--;
    }
    return current;
  }

  FutureOr<IndexNode> _findInLevel(IndexNode node, BsonValue value, bool sibling, int level) {
    var current = node;
    while (level < current.next.length && !current.next[level].isEmpty) {
      final res = getNode(current.next[level]);
      if (res is Future<IndexNode>) {
        return res.then((nx) {
          final cmp = nx.key.compareTo(value);
          if (sibling ? cmp > 0 : cmp >= 0) {
            return current;
          }
          return _findInLevel(nx, value, sibling, level);
        });
      }

      final nx = res;
      final cmp = nx.key.compareTo(value);
      if (sibling ? cmp > 0 : cmp >= 0) {
        return current;
      }
      current = nx;
    }
    return current;
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// Geometric distribution: 50 % chance of height increase per level.
  int _randomHeight() {
    var h = 1;
    while (h < IndexPage.maxLevels && _rng.nextBool()) h++;
    return h;
  }

  FutureOr<IndexNode> _allocateNode(CollectionIndex index, BsonValue key, PageAddress dataBlock, int levels) {
    return _then(_getOrCreateIndexPage(index, levels), (page) {
      final slot = _nextSlot(page.nodes.keys);
      final node = IndexNode(slot: slot, levels: levels, key: key, page: page)..dataBlock = dataBlock;
      page.addNode(node);
      _pager.setDirty(page);
      return node;
    });
  }

  FutureOr<IndexPage> _getOrCreateIndexPage(CollectionIndex index, int requiredLevels) {
    // Estimate bytes needed: baseSize + key(max ~64) + levels * 10
    final needed = IndexNode.baseSize + 64 + requiredLevels * 10;

    if (index.freeIndexPageID != PageAddress.emptyPageId) {
      return _then(_pager.getPage<IndexPage>(index.freeIndexPageID), (page) {
        if (page.freeBytes >= needed) return page;

        // Current page is full, create a new one
        return _createNewIndexPage(index, page);
      });
    }

    // No index page yet, create first one
    return _createNewIndexPage(index, null);
  }

  FutureOr<IndexPage> _createNewIndexPage(CollectionIndex index, IndexPage? last) {
    return _then(_pager.newPage<IndexPage>((id) => IndexPage(id), last), (newPage) {
      index.freeIndexPageID = newPage.pageID;
      if (index.page != null) _pager.setDirty(index.page!);
      return newPage;
    });
  }

  static int _nextSlot(Iterable<int> used) {
    final s = used.toSet();
    var i = 0;
    while (s.contains(i)) i++;
    return i;
  }
}
