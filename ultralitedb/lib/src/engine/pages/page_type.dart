/// Identifies the content type of a 4096-byte database page.
enum PageType {
  empty(0),
  header(1),
  collection(2),
  indexPage(3),
  data(4),
  extend(5);

  final int value;
  const PageType(this.value);

  static PageType fromByte(int byte) {
    for (final t in PageType.values) {
      if (t.value == byte) return t;
    }
    throw ArgumentError('Unknown PageType byte: $byte');
  }
}
