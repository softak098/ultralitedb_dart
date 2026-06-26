import 'dart:typed_data';
import '../structures/page_address.dart';
import 'base_page.dart';
import 'page_type.dart';

part 'data_block.dart';

/// Stores serialized BSON document bytes.
/// Maps to C# DataPage.
class DataPage extends BasePage {
  final Map<int, DataBlock> dataBlocks = {};

  DataPage(super.pageID) {
    pageType = PageType.data;
  }

  // ── Block management ──────────────────────────────────────────────────────

  DataBlock? getBlock(int slot) => dataBlocks[slot];

  void addBlock(DataBlock block) {
    dataBlocks[block.position.index] = block;
    itemCount = dataBlocks.length;
    freeBytes -= DataBlock.fixedSize + block.dataLength;
    isDirty = true;
  }

  void deleteBlock(int slot) {
    final block = dataBlocks.remove(slot);
    if (block != null) {
      itemCount = dataBlocks.length;
      freeBytes += DataBlock.fixedSize + block.dataLength;
      isDirty = true;
    }
  }

  // ── Serialization ─────────────────────────────────────────────────────────

  @override
  void readContent(ByteData bd) {
    dataBlocks.clear();
    var pos = BasePage.pageHeaderSize;
    for (var i = 0; i < itemCount; i++) {
      final block = DataBlock._read(bd, pos, this);
      dataBlocks[block.position.index] = block;
      pos += DataBlock.fixedSize + block.dataLength;
    }
  }

  @override
  void writeContent(ByteData bd) {
    var pos = BasePage.pageHeaderSize;
    for (final block in dataBlocks.values) {
      block._write(bd, pos);
      pos += DataBlock.fixedSize + block.dataLength;
    }
  }
}
