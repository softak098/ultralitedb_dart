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

  // ── Index DDL ─────────────────────────────────────────────────────────────

  Future<CollectionIndex> createIndex(CollectionPage col, String field, bool unique) async {
    final idx = col.getFreeIndex();
    if (idx == null) throw StateError('Max index count reached for collection');

    idx.field = field;
    idx.unique = unique;

    // Create head (MinValue) and tail (MaxValue) sentinel nodes
    final head = await _allocateNode(idx, BsonValue.minValue, PageAddress.empty, IndexPage.maxLevels);
    final tail = await _allocateNode(idx, BsonValue.maxValue, PageAddress.empty, IndexPage.maxLevels);

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
  }

  Future<void> dropIndex(CollectionIndex index) async {
    // Free every IndexPage in the index's page chain
    var pageId = index.freeIndexPageID;
    while (pageId != PageAddress.emptyPageId) {
      final page = await _pager.getPage<IndexPage>(pageId);
      final nextId = page.nextPageID;
      _pager.freePage(page);
      pageId = nextId;
    }
    index.field = '';
    index.unique = false;
    index.head = PageAddress.empty;
    index.tail = PageAddress.empty;
    index.freeIndexPageID = PageAddress.emptyPageId;
    if (index.page != null) _pager.setDirty(index.page!);
  }

  // ── Node DML ──────────────────────────────────────────────────────────────

  /// Inserts a new skip-list node for [key] pointing to [dataBlock].
  Future<IndexNode> addNode(CollectionIndex index, BsonValue key, PageAddress dataBlock) async {
    final height = _randomHeight();
    final update = <IndexNode>[];

    // Walk from head, finding the insertion predecessor at each level
    var node = await getNode(index.head);
    for (var i = IndexPage.maxLevels - 1; i >= 0; i--) {
      while (i < node.next.length && !node.next[i].isEmpty) {
        final nx = await getNode(node.next[i]);
        if (nx.key >= key) break;
        node = nx;
      }
      update.add(node); // update is filled in reverse order
    }
    update.setRange(0, update.length, update.reversed.toList());
    // update[i] = last node at level i whose key < key

    // Unique constraint check at level 0
    if (index.unique && !key.isMinValue && !key.isMaxValue) {
      if (!update[0].next[0].isEmpty) {
        final candidate = await getNode(update[0].next[0]);
        if (candidate.key == key) {
          throw StateError('Unique index "${index.field}" violation: duplicate key $key');
        }
      }
    }

    final newNode = await _allocateNode(index, key, dataBlock, height);

    // Splice newNode into the skip-list at each level
    for (var i = 0; i < height; i++) {
      final pred = update[i];
      final oldNext = i < pred.next.length ? pred.next[i] : PageAddress.empty;

      newNode.next[i] = oldNext;
      newNode.prev[i] = pred.position;

      if (!oldNext.isEmpty) {
        final oldNextNode = await getNode(oldNext);
        if (i < oldNextNode.prev.length) {
          oldNextNode.prev[i] = newNode.position;
          _pager.setDirty(oldNextNode.page!);
        }
      }

      if (i < pred.next.length) {
        pred.next[i] = newNode.position;
        _pager.setDirty(pred.page!);
      }
    }

    _pager.setDirty(newNode.page!);
    return newNode;
  }

  /// Removes [node] from the skip-list and its page.
  Future<void> deleteNode(IndexNode node) async {
    for (var i = 0; i < node.levels; i++) {
      if (!node.prev[i].isEmpty) {
        final p = await getNode(node.prev[i]);
        if (i < p.next.length) {
          p.next[i] = node.next[i];
          _pager.setDirty(p.page!);
        }
      }
      if (!node.next[i].isEmpty) {
        final n = await getNode(node.next[i]);
        if (i < n.prev.length) {
          n.prev[i] = node.prev[i];
          _pager.setDirty(n.page!);
        }
      }
    }
    node.page!.deleteNode(node.slot);
    _pager.setDirty(node.page!);
  }

  // ── Search ────────────────────────────────────────────────────────────────

  /// Loads the node at [address].
  Future<IndexNode> getNode(PageAddress address) async {
    final page = await _pager.getPage<IndexPage>(address.pageID);
    return page.getNode(address.index)!;
  }

  /// Iterates all data nodes (excluding head/tail sentinels) in [order].
  Future<Iterable<IndexNode>> findAll(CollectionIndex index, int order) async {
    final head = await getNode(index.head);
    final tail = index.tail;

    var addr = order == Query.ascending ? head.next[0] : (await getNode(index.tail)).prev[0];

    final results = <IndexNode>[];

    while (!addr.isEmpty && addr != (order == Query.ascending ? tail : index.head)) {
      final node = await getNode(addr);
      results.add(node);
      addr = order == Query.ascending ? node.next[0] : node.prev[0];
    }

    return results;
  }

  /// Binary-searches the skip-list for [value].
  /// Returns the last node whose key < [value] (exclusive) or
  /// the node whose key == [value] when [sibling] is `true`.
  Future<IndexNode> find(CollectionIndex index, BsonValue value, {bool sibling = false}) async {
    var node = await getNode(index.head);
    for (var i = IndexPage.maxLevels - 1; i >= 0; i--) {
      while (i < node.next.length && !node.next[i].isEmpty) {
        final nx = await getNode(node.next[i]);
        final cmp = nx.key.compareTo(value);
        if (sibling ? cmp > 0 : cmp >= 0) break;
        node = nx;
      }
    }
    return node;
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// Geometric distribution: 50 % chance of height increase per level.
  int _randomHeight() {
    var h = 1;
    while (h < IndexPage.maxLevels && _rng.nextBool()) h++;
    return h;
  }

  Future<IndexNode> _allocateNode(CollectionIndex index, BsonValue key, PageAddress dataBlock, int levels) async {
    final page = await _getOrCreateIndexPage(index, levels);
    final slot = _nextSlot(page.nodes.keys);
    final node = IndexNode(slot: slot, levels: levels, key: key, page: page)..dataBlock = dataBlock;
    page.addNode(node);
    _pager.setDirty(page);
    return node;
  }

  Future<IndexPage> _getOrCreateIndexPage(CollectionIndex index, int requiredLevels) async {
    // Estimate bytes needed: baseSize + key(max ~64) + levels * 10
    final needed = IndexNode.baseSize + 64 + requiredLevels * 10;

    if (index.freeIndexPageID != PageAddress.emptyPageId) {
      final page = await _pager.getPage<IndexPage>(index.freeIndexPageID);
      if (page.freeBytes >= needed) return page;
    }

    IndexPage? last;
    if (index.freeIndexPageID != PageAddress.emptyPageId) {
      last = await _pager.getPage<IndexPage>(index.freeIndexPageID);
    }

    final newPage = await _pager.newPage<IndexPage>((id) => IndexPage(id), last);
    index.freeIndexPageID = newPage.pageID;
    if (index.page != null) _pager.setDirty(index.page!);
    return newPage;
  }

  static int _nextSlot(Iterable<int> used) {
    final s = used.toSet();
    var i = 0;
    while (s.contains(i)) i++;
    return i;
  }
}
