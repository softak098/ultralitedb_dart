import 'dart:typed_data';
import 'base_page.dart';
import 'page_type.dart';

/// Overflow page that holds continuation bytes for large documents.
/// Maps to C# ExtendPage.
class ExtendPage extends BasePage {
  late Uint8List content;

  ExtendPage(super.pageID) {
    pageType = PageType.extend;
    content = Uint8List(BasePage.pageAvailableBytes);
  }

  // ── Serialization ─────────────────────────────────────────────────────────

  @override
  void readContent(ByteData bd) {
    content = Uint8List.sublistView(
      bd.buffer.asUint8List(),
      BasePage.pageHeaderSize,
      BasePage.pageSize,
    );
  }

  @override
  void writeContent(ByteData bd) {
    for (var i = 0; i < content.length; i++) {
      bd.setUint8(BasePage.pageHeaderSize + i, content[i]);
    }
  }
}
