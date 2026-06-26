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
  void initialize([String? password]) {
    _disk.initialize(password);

    // Read header to learn lastPageId (needed for journal boundary check)
    _header = getPage<HeaderPage>(0);

    // Journal recovery: file is longer than data area ⟹ incomplete commit
    final dataAreaSize = BasePage.getSizeOfPages(_header.lastPageId + 1);
    if (_disk.fileLength > dataAreaSize && _disk.isJournalEnabled) {
      _cache.clear(); // discard any cached pages
      _replayJournal(_header.lastPageId);
      _cache.clear(); // discard after replay
      _header = getPage<HeaderPage>(0); // reload clean header
    }
  }

  // ── Page access ───────────────────────────────────────────────────────────

  T getPage<T extends BasePage>(int pageID) {
    final cached = _cache.getPage<T>(pageID);
    if (cached != null) return cached;
    final page = _loadFromDisk(pageID);
    _cache.addPage(page);
    return page as T;
  }

  void setDirty(BasePage page) => _cache.setDirty(page);

  // ── Allocation ────────────────────────────────────────────────────────────

  T newPage<T extends BasePage>(
    T Function(int pageID) factory, [
    BasePage? prevPage,
  ]) {
    final T page;

    if (_header.freeEmptyPageId != PageAddress.emptyPageId) {
      final empty = getPage<EmptyPage>(_header.freeEmptyPageId);
      _header.freeEmptyPageId = empty.nextPageID;
      page = factory(empty.pageID);
    } else {
      _header.lastPageId++;
      page = factory(_header.lastPageId);
      _disk.setLength((_header.lastPageId + 1) * BasePage.pageSize);
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

  Iterable<T> getSeqPages<T extends BasePage>(int firstPageID) sync* {
    var id = firstPageID;
    while (id != PageAddress.emptyPageId) {
      final page = getPage<T>(id);
      yield page;
      id = page.nextPageID;
    }
  }

  void flushDirtyPages() {
    for (final page in _cache.getDirtyPages()) {
      _disk.writePage(page.pageID, page.toBuffer());
    }
    _cache.clearDirty();
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// Replay journal pages back into the data area, then remove journal.
  void _replayJournal(int lastPageId) {
    for (final buf in _disk.readJournal(lastPageId)) {
      // First 4 bytes of every page buffer = pageID (BasePage._pPageId = 0)
      final pageID = ByteData.sublistView(buf).getUint32(0, Endian.little);
      _disk.writePage(pageID, buf);
    }
    _disk.clearJournal(lastPageId);
    _disk.flush();
  }

  BasePage _loadFromDisk(int pageID) {
    final buffer = _disk.readPage(pageID);
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
