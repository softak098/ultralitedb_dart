import 'dart:typed_data';
import '../pages/base_page.dart';
import '../pages/collection_page.dart';
import '../pages/data_page.dart';
import '../pages/empty_page.dart';
import '../pages/extend_page.dart';
import '../pages/header_page.dart';
import '../pages/index_page.dart';
import '../pages/page_type.dart';
import '../structures/page_address.dart';
import 'cache_service.dart';
import 'disk_service.dart';

class PageService {
  final IDiskService _disk;
  final CacheService _cache;
  late HeaderPage _header;

  PageService(this._disk, this._cache);

  HeaderPage get header => _header;
  CacheService get cache => _cache;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Call once after constructing services.
  /// Opens the backing store, recovers from journal if needed, loads header.
  Future<void> initialize([String? password]) async {
    await _disk.initialize(password);

    // Read header to learn lastPageId (needed for journal boundary check)
    _header = await getPage<HeaderPage>(0);

    // Journal recovery: file is longer than data area ⟹ incomplete commit
    final dataAreaSize = BasePage.getSizeOfPages(_header.lastPageId + 1);
    if ((await _disk.getFileLength()) > dataAreaSize && _disk.isJournalEnabled) {
      _cache.clear(); // discard any cached pages
      await _replayJournal(_header.lastPageId);
      _cache.clear(); // discard after replay
      _header = await getPage<HeaderPage>(0); // reload clean header
    }
  }

  // ── Page access ───────────────────────────────────────────────────────────

  Future<T> getPage<T extends BasePage>(int pageID) async {
    var page = _cache.getPage<BasePage>(pageID);
    if (page != null) return page as T;
    page = await _loadFromDisk(pageID);
    _cache.addPage(page);
    return page as T;
  }

  void setDirty(BasePage page) => _cache.setDirty(page);

  // ── Allocation ────────────────────────────────────────────────────────────

  Future<T> newPage<T extends BasePage>(T Function(int pageID) pageCallback, [BasePage? prevPage]) async {
    final T page;

    if (_header.freeEmptyPageId != PageAddress.emptyPageId) {
      final empty = await getPage<EmptyPage>(_header.freeEmptyPageId);
      _header.freeEmptyPageId = empty.nextPageID;
      page = pageCallback(empty.pageID);
    } else {
      _header.lastPageId++;
      page = pageCallback(_header.lastPageId);
      await _disk.setLength((_header.lastPageId + 1) * BasePage.pageSize);
    }

    page
      ..itemCount = 0
      ..freeBytes = BasePage.pageAvailableBytes
      ..isDirty = true;

    if (prevPage != null) {
      page.prevPageID = prevPage.pageID;
      prevPage.nextPageID = page.pageID;
      setDirty(prevPage);
    }

    setDirty(_header);
    _cache.addPage(page);
    return page;
  }

  void freePage(BasePage page) {
    final empty = EmptyPage(page.pageID)
      ..nextPageID = _header.freeEmptyPageId
      ..prevPageID = PageAddress.emptyPageId
      ..isDirty = true;

    _header.freeEmptyPageId = page.pageID;
    setDirty(_header);
    _cache.addPage(empty);
  }

  Future<Iterable<T>> getSeqPages<T extends BasePage>(int firstPageID) async {
    final results = <T>[];
    var id = firstPageID;
    while (id != PageAddress.emptyPageId) {
      final page = await getPage<T>(id);
      results.add(page);
      id = page.nextPageID;
    }
    return results;
  }

  Future<void> flushDirtyPages() async {
    for (final page in _cache.getDirtyPages()) {
      await _disk.writePage(page.pageID, page.toBuffer());
    }
    _cache.clearDirty();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// Replay journal pages back into the data area, then remove journal.
  Future<void> _replayJournal(int lastPageId) async {
    for (final buf in await _disk.readJournal(lastPageId)) {
      // First 4 bytes of every page buffer = pageID (BasePage._pPageId = 0)
      final pageID = ByteData.sublistView(buf).getUint32(0, Endian.little);
      await _disk.writePage(pageID, buf);
    }
    await _disk.clearJournal(lastPageId);
    await _disk.flush();
  }

  Future<BasePage> _loadFromDisk(int pageID) async {
    final buffer = await _disk.readPage(pageID);
    final bd = ByteData.sublistView(buffer);
    final type = PageType.fromByte(bd.getUint8(4)); // offset 4 = pageType

    final page = switch (type) {
      PageType.header => HeaderPage(pageID),
      PageType.collection => CollectionPage(pageID),
      PageType.indexPage => IndexPage(pageID),
      PageType.data => DataPage(pageID),
      PageType.extend => ExtendPage(pageID),
      PageType.empty => EmptyPage(pageID),
    };

    page.readHeader(bd);
    page.readContent(bd);
    return page;
  }
}
