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

  // ── Lifecycle ─────────────────────────────────────────────────────────────

  @override
  Future<void> initialize([String? password]) async {
    final file = File(filename);
    final exists = await file.exists();
    final isNew = !exists || (await file.length()) == 0;

    if (isNew) await file.create(recursive: true);

    // FileMode.append = OPEN_ALWAYS on Windows → full random R/W access.
    _raf = await file.open(mode: FileMode.append);

    if (isNew) await _createDatabase(password);
  }

  @override
  Future<void> dispose() async {
    await _raf?.close();
    _raf = null;
  }

  // ── Page I/O ──────────────────────────────────────────────────────────────

  @override
  Future<Uint8List> readPage(int pageID) async {
    final buffer = Uint8List(BasePage.pageSize);
    await _raf!.setPosition(BasePage.getSizeOfPages(pageID));
    await _raf!.readInto(buffer);
    return buffer;
  }

  @override
  Future<void> writePage(int pageID, Uint8List buffer) async {
    await _raf!.setPosition(BasePage.getSizeOfPages(pageID));
    await _raf!.writeFrom(buffer);
  }

  @override
  Future<void> setLength(int fileSize) async {
    if (fileSize > options.limitSize) {
      throw StateError('File size limit exceeded: $fileSize > ${options.limitSize}');
    }
    await _raf!.truncate(fileSize); // truncate also extends (zero-fills)
  }

  @override
  Future<int> getFileLength() async => await _raf?.length() ?? 0;

  // ── Journal ───────────────────────────────────────────────────────────────

  @override
  bool get isJournalEnabled => options.journal;

  /// Appends [pages] right after the data area (after page [lastPageID]).
  /// Extends the file to `(lastPageID+1)*PAGE_SIZE + pages*PAGE_SIZE`.
  @override
  Future<void> writeJournal(List<Uint8List> pages, int lastPageID) async {
    if (!options.journal || pages.isEmpty) return;

    final journalStart = BasePage.getSizeOfPages(lastPageID + 1);
    final totalSize = journalStart + pages.length * BasePage.pageSize;

    await _raf!.truncate(totalSize); // extend file to hold journal area
    await _raf!.setPosition(journalStart);

    for (final buf in pages) {
      await _raf!.writeFrom(buf);
    }

    await flush(); // ensure journal hits disk before we touch data area
  }

  /// Yields each [BasePage.pageSize]-chunk from the journal area.
  @override
  Future<Iterable<Uint8List>> readJournal(int lastPageID) async {
    final journalStart = BasePage.getSizeOfPages(lastPageID + 1);
    final len = await _raf!.length();
    if (len <= journalStart) return const [];

    await _raf!.setPosition(journalStart);
    var pos = journalStart;
    final results = <Uint8List>[];

    while (pos + BasePage.pageSize <= len) {
      final buf = Uint8List(BasePage.pageSize);
      final read = await _raf!.readInto(buf);
      if (read < BasePage.pageSize) break;
      results.add(buf);
      pos += BasePage.pageSize;
    }
    return results;
  }

  /// Truncates the file back to the data area — removes journal.
  @override
  Future<void> clearJournal(int lastPageID) async => await _raf!.truncate(BasePage.getSizeOfPages(lastPageID + 1));

  @override
  Future<void> flush() async => await _raf!.flush();

  // ── Database creation ─────────────────────────────────────────────────────

  /// Mirrors C# UltraLiteEngine.CreateDatabase(stream, password, initialSize).
  Future<void> _createDatabase(String? password) async {
    final rawEmpty = options.initialSize;
    final emptyPages = rawEmpty <= 2 * BasePage.pageSize ? 0 : (rawEmpty - 2 * BasePage.pageSize) ~/ BasePage.pageSize;

    // ── Page 0: HeaderPage ────────────────────────────────────────────────
    final header = HeaderPage(0)
      ..lastPageId = emptyPages == 0 ? 1 : emptyPages + 1
      ..freeEmptyPageId = emptyPages == 0 ? PageAddress.emptyPageId : 2;

    await _raf!.setPosition(0);
    await _raf!.writeFrom(header.toBuffer());

    // ── Page 1: Lock area (plain zeros) ───────────────────────────────────
    await _raf!.writeFrom(Uint8List(BasePage.pageSize));

    // ── Pages 2..emptyPages+1: doubly-linked EmptyPage chain ─────────────
    if (emptyPages > 0) {
      await _raf!.truncate(rawEmpty.toInt()); // pre-allocate full initial size

      for (var pageID = 2; pageID <= emptyPages + 1; pageID++) {
        final empty = EmptyPage(pageID)
          ..prevPageID = pageID == 2
              ? 0 // points back to header (list head sentinel)
              : pageID - 1
          ..nextPageID = pageID == emptyPages + 1 ? PageAddress.emptyPageId : pageID + 1;

        await _raf!.setPosition(BasePage.getSizeOfPages(pageID));
        await _raf!.writeFrom(empty.toBuffer());
      }
    }

    await flush();
  }
}
