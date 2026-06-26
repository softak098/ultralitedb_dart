import 'dart:convert';
import 'dart:typed_data';
import '../structures/page_address.dart';
import 'base_page.dart';
import 'page_type.dart';

/// Page 0 of every database file — stores global metadata and collection index.
/// Maps to C# HeaderPage.
class HeaderPage extends BasePage {
  static const String headerInfo = '** UltraLiteDB **';
  static const int headerInfoLen = 27; // padded / null-terminated
  static const int fileVersion = 8; // current UltraLiteDB format version

  // Offsets relative to start of page (after 32-byte base header)
  static const int _pInfo = 32; // [32-58]  27 bytes
  static const int _pFileVersion = 59; // [59]      1 byte
  static const int _pDbId = 60; // [60-75]  16 bytes (Guid)
  static const int _pCreationTime = 76; // [76-83]   8 bytes (UTC ms)
  static const int _pChangeId = 84; // [84-91]   8 bytes
  static const int _pFreeEmptyPage = 92; // [92-95]   4 bytes
  static const int _pLastPageId = 96; // [96-99]   4 bytes
  static const int _pUserVersion = 100; // [100]     1 byte
  static const int _pCollections = 101; // [101-...]  variable

  // ── Fields ────────────────────────────────────────────────────────────────

  int dbFileVersion;
  List<int> dbId; // 16-byte Guid
  DateTime creationTime;
  int changeId; // int64
  int freeEmptyPageId; // uint32
  int lastPageId; // uint32
  int userVersion; // byte

  /// Collection name → root PageID.
  final Map<String, int> collections = {};

  HeaderPage(super.pageID)
    : dbFileVersion = fileVersion,
      dbId = List.filled(16, 0),
      creationTime = DateTime.now().toUtc(),
      changeId = 0,
      freeEmptyPageId = PageAddress.emptyPageId,
      lastPageId = 0,
      userVersion = 0 {
    pageType = PageType.header;
    itemCount = 0;
  }

  // ── Serialization ─────────────────────────────────────────────────────────

  @override
  void readContent(ByteData bd) {
    // Header info string — just validates format; skip reading
    dbFileVersion = bd.getUint8(_pFileVersion);
    for (var i = 0; i < 16; i++) dbId[i] = bd.getUint8(_pDbId + i);
    creationTime = DateTime.fromMillisecondsSinceEpoch(
      bd.getInt64(_pCreationTime, Endian.little),
      isUtc: true,
    );
    changeId = bd.getInt64(_pChangeId, Endian.little);
    freeEmptyPageId = bd.getUint32(_pFreeEmptyPage, Endian.little);
    lastPageId = bd.getUint32(_pLastPageId, Endian.little);
    userVersion = bd.getUint8(_pUserVersion);
    _readCollections(bd);
  }

  @override
  void writeContent(ByteData bd) {
    // Write header info (padded to headerInfoLen bytes)
    final infoBytes = utf8.encode(headerInfo);
    for (var i = 0; i < headerInfoLen; i++) {
      bd.setUint8(_pInfo + i, i < infoBytes.length ? infoBytes[i] : 0);
    }
    bd.setUint8(_pFileVersion, dbFileVersion);
    for (var i = 0; i < 16; i++) bd.setUint8(_pDbId + i, dbId[i]);
    bd.setInt64(
      _pCreationTime,
      creationTime.millisecondsSinceEpoch,
      Endian.little,
    );
    bd.setInt64(_pChangeId, changeId, Endian.little);
    bd.setUint32(_pFreeEmptyPage, freeEmptyPageId, Endian.little);
    bd.setUint32(_pLastPageId, lastPageId, Endian.little);
    bd.setUint8(_pUserVersion, userVersion);
    _writeCollections(bd);
  }

  void _readCollections(ByteData bd) {
    collections.clear();
    var pos = _pCollections;
    while (pos < BasePage.pageSize - 5) {
      final nameLen = bd.getUint8(pos++);
      if (nameLen == 0) break; // terminator
      final nameBytes = List.generate(nameLen, (i) => bd.getUint8(pos + i));
      pos += nameLen;
      final rootPageId = bd.getUint32(pos, Endian.little);
      pos += 4;
      collections[utf8.decode(nameBytes)] = rootPageId;
    }
  }

  void _writeCollections(ByteData bd) {
    var pos = _pCollections;
    for (final e in collections.entries) {
      final nameBytes = utf8.encode(e.key);
      bd.setUint8(pos++, nameBytes.length);
      for (final b in nameBytes) bd.setUint8(pos++, b);
      bd.setUint32(pos, e.value, Endian.little);
      pos += 4;
    }
    bd.setUint8(pos, 0); // terminator
  }

  // ── Collection helpers ────────────────────────────────────────────────────

  bool containsCollection(String name) => collections.containsKey(name);

  int? getCollectionPageId(String name) => collections[name];

  void addCollection(String name, int rootPageId) {
    collections[name] = rootPageId;
    itemCount = collections.length;
    isDirty = true;
  }

  void removeCollection(String name) {
    collections.remove(name);
    itemCount = collections.length;
    isDirty = true;
  }
}
