import 'dart:typed_data';
import '../pages/base_page.dart';

/// Storage abstraction — maps to C# IDiskService.
/// Two concrete implementations:
///   [FileDiskService]   — dart:io RandomAccessFile, with journal.
///   [StreamDiskService] — in-memory Map<pageID, bytes>, no journal.
abstract class IDiskService {
  /// Open / create the backing store. Must be called once before any I/O.
  /// [password] reserved for future AES support (ignored currently).
  Future<void> initialize([String? password]);

  /// Read exactly [BasePage.pageSize] bytes for [pageID].
  Future<Uint8List> readPage(int pageID);

  /// Write exactly [BasePage.pageSize] bytes for [pageID].
  Future<void> writePage(int pageID, Uint8List buffer);

  /// Pre-allocate (or truncate) the backing store to [fileSize] bytes.
  Future<void> setLength(int fileSize);

  /// Current size of the backing store in bytes.
  Future<int> getFileLength();

  /// Whether this service supports write-ahead journaling.
  bool get isJournalEnabled;

  /// Write [pages] into the journal area appended after page [lastPageID].
  /// Journal lives in the SAME file, right after the data area.
  Future<void> writeJournal(List<Uint8List> pages, int lastPageID);

  /// Read journal pages appended after page [lastPageID].
  Future<Iterable<Uint8List>> readJournal(int lastPageID);

  /// Truncate backing store to remove the journal area (called after commit).
  Future<void> clearJournal(int lastPageID);

  /// Flush OS write-buffers to physical storage.
  Future<void> flush();

  Future<void> dispose();
}
