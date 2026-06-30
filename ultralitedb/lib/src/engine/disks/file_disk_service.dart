import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../pages/base_page.dart';
import '../pages/empty_page.dart';
import '../pages/header_page.dart';
import '../services/disk_service.dart';
import '../structures/page_address.dart';
import 'file_options.dart';

/// File-backed [IDiskService] using [dart:io] [RandomAccessFile].
/// Maps to C# FileDiskService.
///
/// ### Windows note
/// Uses [FileMode.append] which on Windows maps to `OPEN_ALWAYS` without
/// `FILE_APPEND_DATA`, giving full random-access R/W.
/// On POSIX (Linux/macOS), `O_APPEND` forces every write to EOF regardless
/// of [RandomAccessFile.setPositionSync]. For cross-platform production use
/// replace with a `dart:ffi` native `open(O_RDWR|O_CREAT)` binding.
class FileDiskService implements IDiskService {
  final String filename;
  final FileOptions options;

  RandomAccessFile? _raf;

  FileDiskService(this.filename, {FileOptions? options}) : options = options ?? FileOptions();

  bool get _syncIO => options.syncIO;

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  FutureOr<void> initialize([String? password]) {
    final file = File(filename);

    if (_syncIO) {
      final exists = file.existsSync();
      final isNew = !exists || file.lengthSync() == 0;
      if (isNew) file.createSync(recursive: true);
      _raf = file.openSync(mode: FileMode.append);
      if (isNew) _createDatabaseSync(password);
      return null;
    } else {
      return Future.sync(() async {
        final exists = await file.exists();
        final isNew = !exists || (await file.length()) == 0;
        if (isNew) await file.create(recursive: true);
        _raf = await file.open(mode: FileMode.append);
        if (isNew) await _createDatabase(password);
      });
    }
  }

  @override
  FutureOr<void> dispose() {
    if (_syncIO) {
      _raf?.closeSync();
      _raf = null;
    } else {
      return _raf?.close().then((_) => _raf = null);
    }
  }

  // ── Page I/O ──────────────────────────────────────────────────────────────

  @override
  FutureOr<Uint8List> readPage(int pageID) {
    final buffer = Uint8List(BasePage.pageSize);
    final pos = BasePage.getSizeOfPages(pageID);
    if (_syncIO) {
      _raf!.setPositionSync(pos);
      _raf!.readIntoSync(buffer);
      return buffer;
    } else {
      return _raf!.setPosition(pos).then((_) => _raf!.readInto(buffer)).then((_) => buffer);
    }
  }

  @override
  FutureOr<void> writePage(int pageID, Uint8List buffer) {
    final pos = BasePage.getSizeOfPages(pageID);
    if (_syncIO) {
      _raf!.setPositionSync(pos);
      _raf!.writeFromSync(buffer);
    } else {
      return _raf!.setPosition(pos).then((_) => _raf!.writeFrom(buffer));
    }
  }

  @override
  FutureOr<void> setLength(int fileSize) {
    if (fileSize > options.limitSize) {
      throw StateError('File size limit exceeded: $fileSize > ${options.limitSize}');
    }
    if (_syncIO) {
      _raf!.truncateSync(fileSize);
    } else {
      return _raf!.truncate(fileSize);
    }
  }

  @override
  FutureOr<int> getFileLength() {
    if (_syncIO) {
      return _raf?.lengthSync() ?? 0;
    } else {
      return _raf?.length() ?? Future.value(0);
    }
  }

  // ── Journal ───────────────────────────────────────────────────────────────

  @override
  bool get isJournalEnabled => options.journal;

  @override
  FutureOr<void> writeJournal(List<Uint8List> pages, int lastPageID) {
    if (!options.journal || pages.isEmpty) return null;

    final journalStart = BasePage.getSizeOfPages(lastPageID + 1);
    final totalSize = journalStart + pages.length * BasePage.pageSize;

    if (_syncIO) {
      _raf!.truncateSync(totalSize);
      _raf!.setPositionSync(journalStart);
      for (final buf in pages) _raf!.writeFromSync(buf);
      _raf!.flushSync();
    } else {
      return _raf!
          .truncate(totalSize)
          .then((_) => _raf!.setPosition(journalStart))
          .then((_) => Future.forEach(pages, (Uint8List buf) => _raf!.writeFrom(buf)))
          .then((_) => flush());
    }
  }

  @override
  FutureOr<Iterable<Uint8List>> readJournal(int lastPageID) {
    if (_syncIO) {
      final len = _raf!.lengthSync();
      final start = BasePage.getSizeOfPages(lastPageID + 1);
      if (len <= start) return const [];

      final count = (len - start) ~/ BasePage.pageSize;
      final result = <Uint8List>[];
      _raf!.setPositionSync(start);
      for (var i = 0; i < count; i++) {
        final buf = Uint8List(BasePage.pageSize);
        _raf!.readIntoSync(buf);
        result.add(buf);
      }
      return result;
    } else {
      return _raf!.length().then((len) {
        final start = BasePage.getSizeOfPages(lastPageID + 1);
        if (len <= start) return const <Uint8List>[];
        final count = (len - start) ~/ BasePage.pageSize;
        return _readJournalAsync(start, count);
      });
    }
  }

  Future<Iterable<Uint8List>> _readJournalAsync(int start, int count) async {
    final result = <Uint8List>[];
    await _raf!.setPosition(start);
    for (var i = 0; i < count; i++) {
      final buf = Uint8List(BasePage.pageSize);
      await _raf!.readInto(buf);
      result.add(buf);
    }
    return result;
  }

  @override
  FutureOr<void> clearJournal(int lastPageID) {
    final size = BasePage.getSizeOfPages(lastPageID + 1);
    if (_syncIO) {
      _raf!.truncateSync(size);
      _raf!.flushSync();
    } else {
      return _raf!.truncate(size).then((_) => flush());
    }
  }

  @override
  FutureOr<void> flush() {
    if (_syncIO) {
      _raf!.flushSync();
    } else {
      return _raf!.flush();
    }
  }

  // ── Database creation ─────────────────────────────────────────────────────

  void _createDatabaseSync([String? password]) {
    final rawEmpty = options.initialSize;
    final emptyPages = rawEmpty <= 2 * BasePage.pageSize ? 0 : (rawEmpty - 2 * BasePage.pageSize) ~/ BasePage.pageSize;

    final header = HeaderPage(0)
      ..lastPageId = emptyPages == 0 ? 1 : emptyPages + 1
      ..freeEmptyPageId = emptyPages == 0 ? PageAddress.emptyPageId : 2;

    _raf!.setPositionSync(0);
    _raf!.writeFromSync(header.toBuffer());
    _raf!.writeFromSync(Uint8List(BasePage.pageSize)); // lock area

    if (emptyPages > 0) {
      _raf!.truncateSync(rawEmpty.toInt());
      for (var pageID = 2; pageID <= emptyPages + 1; pageID++) {
        final empty = EmptyPage(pageID)
          ..prevPageID = pageID == 2 ? 0 : pageID - 1
          ..nextPageID = pageID == emptyPages + 1 ? PageAddress.emptyPageId : pageID + 1;
        _raf!.setPositionSync(BasePage.getSizeOfPages(pageID));
        _raf!.writeFromSync(empty.toBuffer());
      }
    }
    _raf!.flushSync();
  }

  Future<void> _createDatabase([String? password]) async {
    final rawEmpty = options.initialSize;
    final emptyPages = rawEmpty <= 2 * BasePage.pageSize ? 0 : (rawEmpty - 2 * BasePage.pageSize) ~/ BasePage.pageSize;

    final header = HeaderPage(0)
      ..lastPageId = emptyPages == 0 ? 1 : emptyPages + 1
      ..freeEmptyPageId = emptyPages == 0 ? PageAddress.emptyPageId : 2;

    await _raf!.setPosition(0);
    await _raf!.writeFrom(header.toBuffer());
    await _raf!.writeFrom(Uint8List(BasePage.pageSize));

    if (emptyPages > 0) {
      await _raf!.truncate(rawEmpty.toInt());
      for (var pageID = 2; pageID <= emptyPages + 1; pageID++) {
        final empty = EmptyPage(pageID)
          ..prevPageID = pageID == 2 ? 0 : pageID - 1
          ..nextPageID = pageID == emptyPages + 1 ? PageAddress.emptyPageId : pageID + 1;
        await _raf!.setPosition(BasePage.getSizeOfPages(pageID));
        await _raf!.writeFrom(empty.toBuffer());
      }
    }
    await flush();
  }
}
