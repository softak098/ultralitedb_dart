/// Configuration for [FileDiskService].
/// Maps to C# FileOptions.
class FileOptions {
  /// Enable write-ahead journal for crash recovery. Default: `true`.
  bool journal;

  /// Pre-allocate the file to this byte size on creation. 0 = no pre-allocation.
  int initialSize;

  /// Maximum allowed file size in bytes. Writes that exceed this throw.
  int limitSize;

  /// If `true`, [FileDiskService.flush] calls `flushSync` with OS flush.
  /// Default: `false` (rely on OS buffering).
  bool forceFlush;

  FileOptions({
    this.journal = true,
    this.initialSize = 0,
    this.limitSize = 9223372036854775807, // int max
    this.forceFlush = false,
  });
}
