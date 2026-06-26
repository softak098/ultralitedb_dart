import 'dart:typed_data';
import 'base_page.dart';
import 'page_type.dart';

/// A free page in the empty-page chain — no content.
/// Maps to C# EmptyPage.
class EmptyPage extends BasePage {
  EmptyPage(super.pageID) {
    pageType = PageType.empty;
  }

  @override
  void readContent(ByteData bd) {} // nothing to read

  @override
  void writeContent(ByteData bd) {} // nothing to write
}
