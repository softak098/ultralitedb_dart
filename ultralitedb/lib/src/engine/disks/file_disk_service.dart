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

  FileDiskService(this.filename, {FileOptions? options})
    : options = options ?? FileOptions();

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  void initialize([String? password]) {
    final file = File(filename);
    final isNew = !file.existsSync() || file.lengthSync() == 0;

    if (isNew) file.createSync(recursive: true);

    // FileMode.append = OPEN_ALWAYS on Windows → full random R/W access.
    _raf = file.openSync(mode: FileMode.append);

    if (isNew) _createDatabase(password);
  }

  @override
  void dispose() {
    _raf?.closeSync();
    _raf = null;
  }

  // ── Page I/O ──────────────────────────────────────────────────────────────

  @override
  Uint8List readPage(int pageID) {
    final buffer = Uint8List(BasePage.pageSize);
    _raf!.setPositionSync(BasePage.getSizeOfPages(pageID));
    _raf!.readIntoSync(buffer);
    return buffer;
  }

  @override
  void writePage(int pageID, Uint8List buffer) {
    _raf!.setPositionSync(BasePage.getSizeOfPages(pageID));
    _raf!.writeFromSync(buffer);
  }

  @override
  void setLength(int fileSize) {
    if (fileSize > options.limitSize) {
      throw StateError(
        'File size limit exceeded: $fileSize > ${options.limitSize}',
      );
    }
    _raf!.truncateSync(fileSize); // truncateSync also extends (zero-fills)
  }

  @override
  int get fileLength => _raf?.lengthSync() ?? 0;

  // ── Journal ───────────────────────────────────────────────────────────────

  @override
  bool get isJournalEnabled => options.journal;

  /// Appends [pages] right after the data area (after page [lastPageID]).
  /// Extends the file to `(lastPageID+1)*PAGE_SIZE + pages*PAGE_SIZE`.
  @override
  void writeJournal(List<Uint8List> pages, int lastPageID) {
    if (!options.journal || pages.isEmpty) return;

    final journalStart = BasePage.getSizeOfPages(lastPageID + 1);
    final totalSize = journalStart + pages.length * BasePage.pageSize;

    _raf!.truncateSync(totalSize); // extend file to hold journal area
    _raf!.setPositionSync(journalStart);

    for (final buf in pages) {
      _raf!.writeFromSync(buf);
    }

    flush(); // ensure journal hits disk before we touch data area
  }

  /// Yields each [BasePage.pageSize]-chunk from the journal area.
  @override
  Iterable<Uint8List> readJournal(int lastPageID) sync* {
    final journalStart = BasePage.getSizeOfPages(lastPageID + 1);
    final len = _raf!.lengthSync();
    if (len <= journalStart) return;

    _raf!.setPositionSync(journalStart);
    var pos = journalStart;

    while (pos + BasePage.pageSize <= len) {
      final buf = Uint8List(BasePage.pageSize);
      final read = _raf!.readIntoSync(buf);
      if (read < BasePage.pageSize) break;
      yield buf;
      pos += BasePage.pageSize;
    }
  }

  /// Truncates the file back to the data area — removes journal.
  @override
  void clearJournal(int lastPageID) =>
      _raf!.truncateSync(BasePage.getSizeOfPages(lastPageID + 1));

  @override
  void flush() => _raf!.flushSync();

  // ── Database creation ─────────────────────────────────────────────────────

  /// Mirrors C# UltraLiteEngine.CreateDatabase(stream, password, initialSize).
  void _createDatabase(String? password) {
    final rawEmpty = options.initialSize;
    final emptyPages = rawEmpty <= 2 * BasePage.pageSize
        ? 0
        : (rawEmpty - 2 * BasePage.pageSize) ~/ BasePage.pageSize;

    // ── Page 0: HeaderPage ────────────────────────────────────────────────
    final header = HeaderPage(0)
      ..lastPageId = emptyPages == 0 ? 1 : emptyPages + 1
      ..freeEmptyPageId = emptyPages == 0 ? PageAddress.emptyPageId : 2;

    _raf!.setPositionSync(0);
    _raf!.writeFromSync(header.toBuffer());

    // ── Page 1: Lock area (plain zeros) ───────────────────────────────────
    _raf!.writeFromSync(Uint8List(BasePage.pageSize));

    // ── Pages 2..emptyPages+1: doubly-linked EmptyPage chain ─────────────
    if (emptyPages > 0) {
      _raf!.truncateSync(rawEmpty.toInt()); // pre-allocate full initial size

      for (var pageID = 2; pageID <= emptyPages + 1; pageID++) {
        final empty = EmptyPage(pageID)
          ..prevPageID = pageID == 2
              ? 0 // points back to header (list head sentinel)
              : pageID - 1
          ..nextPageID = pageID == emptyPages + 1
              ? PageAddress.emptyPageId
              : pageID + 1;

        _raf!.setPositionSync(BasePage.getSizeOfPages(pageID));
        _raf!.writeFromSync(empty.toBuffer());
      }
    }

    flush();
  }
}
