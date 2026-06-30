import 'dart:async';
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

  // ── Helper for chaining FutureOr operations ────────────────────────────────

  FutureOr<R> _then<T, R>(FutureOr<T> value, FutureOr<R> Function(T) action) {
    if (value is Future<T>) {
      return value.then((v) => action(v));
    }
    return action(value);
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  /// Call once after constructing services.
  /// Opens the backing store, recovers from journal if needed, loads header.
  FutureOr<void> initialize([String? password]) {
    return _then(_disk.initialize(password), (_) {
      // Read header to learn lastPageId (needed for journal boundary check)
      return _then(getPage<HeaderPage>(0), (header) {
        _header = header;

        // Journal recovery: file is longer than data area ⟹ incomplete commit
        return _then(_disk.getFileLength(), (fileLength) {
          final dataAreaSize = BasePage.getSizeOfPages(_header.lastPageId + 1);
          if (fileLength > dataAreaSize && _disk.isJournalEnabled) {
            _cache.clear(); // discard any cached pages
            return _then(_replayJournal(_header.lastPageId), (_) {
              _cache.clear(); // discard after replay
              return _then(getPage<HeaderPage>(0), (cleanHeader) {
                _header = cleanHeader;
                return null;
              });
            });
          }
          return null;
        });
      });
    });
  }

  // ── Page access ───────────────────────────────────────────────────────────

  FutureOr<T> getPage<T extends BasePage>(int pageID) {
    var page = _cache.getPage<T>(pageID);
    if (page != null) return page;

    return _then(_loadFromDisk(pageID), (loaded) {
      _cache.addPage(loaded);
      return loaded as T;
    });
  }

  void setDirty(BasePage page) => _cache.setDirty(page);

  // ── Allocation ────────────────────────────────────────────────────────────

  FutureOr<T> newPage<T extends BasePage>(T Function(int pageID) pageCallback, [BasePage? prevPage]) {
    if (_header.freeEmptyPageId != PageAddress.emptyPageId) {
      return _then(getPage<EmptyPage>(_header.freeEmptyPageId), (empty) {
        _header.freeEmptyPageId = empty.nextPageID;
        final page = pageCallback(empty.pageID);
        _initializeAndCachePage(page, prevPage);
        return page as T;
      });
    } else {
      _header.lastPageId++;
      final pageID = _header.lastPageId;
      final page = pageCallback(pageID);

      return _then(_disk.setLength((pageID + 1) * BasePage.pageSize), (_) {
        _initializeAndCachePage(page, prevPage);
        return page as T;
      });
    }
  }

  void _initializeAndCachePage<T extends BasePage>(T page, BasePage? prevPage) {
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

  FutureOr<Iterable<T>> getSeqPages<T extends BasePage>(int firstPageID) {
    return _getSeqPagesLoop<T>(firstPageID, []);
  }

  FutureOr<Iterable<T>> _getSeqPagesLoop<T extends BasePage>(int id, List<T> results) {
    var curId = id;
    while (curId != PageAddress.emptyPageId) {
      final res = getPage<T>(curId);
      if (res is Future<T>) {
        return res.then((page) {
          results.add(page);
          return _getSeqPagesLoop<T>(page.nextPageID, results);
        });
      }
      results.add(res);
      curId = res.nextPageID;
    }
    return results;
  }

  FutureOr<void> flushDirtyPages() {
    final dirtyPages = _cache.getDirtyPages();
    return _flushDirtyPagesLoop(dirtyPages, 0);
  }

  FutureOr<void> _flushDirtyPagesLoop(List<BasePage> pages, int index) {
    var i = index;
    while (i < pages.length) {
      final page = pages[i];
      final res = _disk.writePage(page.pageID, page.toBuffer());
      if (res is Future) {
        return res.then((_) => _flushDirtyPagesLoop(pages, i + 1));
      }
      i++;
    }
    _cache.clearDirty();
    return null;
  }

  // ── Private ───────────────────────────────────────────────────────────────

  /// Replay journal pages back into the data area, then remove journal.
  FutureOr<void> _replayJournal(int lastPageId) {
    return _then(_disk.readJournal(lastPageId), (buffers) {
      return _replayJournalLoop(buffers.toList(), 0, lastPageId);
    });
  }

  FutureOr<void> _replayJournalLoop(List<Uint8List> buffers, int index, int lastPageId) {
    var i = index;
    while (i < buffers.length) {
      final buf = buffers[i];
      // First 4 bytes of every page buffer = pageID (BasePage._pPageId = 0)
      final pageID = ByteData.sublistView(buf).getUint32(0, Endian.little);
      final res = _disk.writePage(pageID, buf);
      if (res is Future) {
        return res.then((_) => _replayJournalLoop(buffers, i + 1, lastPageId));
      }
      i++;
    }

    return _then(_disk.clearJournal(lastPageId), (_) {
      return _disk.flush();
    });
  }

  FutureOr<BasePage> _loadFromDisk(int pageID) {
    return _then(_disk.readPage(pageID), (buffer) {
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
    });
  }
}
