import 'dart:convert';
import 'dart:typed_data';
import '../../bson/bson_value.dart';
import '../../bson/bson_type.dart';
import '../../bson/writer.dart';
import '../../bson/reader.dart';
import '../../bson/objectid.dart';
import '../structures/page_address.dart';
import 'base_page.dart';
import 'page_type.dart';

part 'index_node.dart';

/// Stores skip-list index nodes.
/// Maps to C# IndexPage.
class IndexPage extends BasePage {
  /// Maximum skip-list height supported.
  static const int maxLevels = 32;

  /// Slot map: slotIndex → IndexNode.
  final Map<int, IndexNode> nodes = {};

  IndexPage(super.pageID) {
    pageType = PageType.indexPage;
  }

  // ── Node management ───────────────────────────────────────────────────────

  IndexNode? getNode(int slot) => nodes[slot];

  void addNode(IndexNode node) {
    nodes[node.slot] = node;
    itemCount = nodes.length;
    freeBytes -= node.totalSize;
    isDirty = true;
  }

  void deleteNode(int slot) {
    final node = nodes.remove(slot);
    if (node != null) {
      itemCount = nodes.length;
      freeBytes += node.totalSize;
      isDirty = true;
    }
  }

  // ── Serialization ─────────────────────────────────────────────────────────

  @override
  void readContent(ByteData bd) {
    nodes.clear();
    var pos = BasePage.pageHeaderSize;
    for (var i = 0; i < itemCount; i++) {
      final node = IndexNode._read(bd, pos, this);
      nodes[node.slot] = node;
      pos += node.totalSize;
    }
  }

  @override
  void writeContent(ByteData bd) {
    var pos = BasePage.pageHeaderSize;
    for (final node in nodes.values) {
      node._write(bd, pos);
      pos += node.totalSize;
    }
  }
}
