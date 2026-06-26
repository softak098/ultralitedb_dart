import 'dart:typed_data';
import 'dart:math';
import 'dart:io';
import 'dart:convert';

/// A 12-byte unique identifier.
/// Layout: 4-byte timestamp (seconds since epoch, big-endian)
/// + 3-byte machine hash + 2-byte pid + 3-byte increment.
class ObjectId implements Comparable<ObjectId> {
  final int timestamp; // 32-bit
  final int machine; // 3 bytes
  final int pid; // 2 bytes
  final int increment; // 3 bytes

  ObjectId([
    this.timestamp = 0,
    this.machine = 0,
    this.pid = 0,
    this.increment = 0,
  ]);

  ObjectId.fromObjectId(ObjectId other)
    : timestamp = other.timestamp,
      machine = other.machine,
      pid = other.pid,
      increment = other.increment;

  factory ObjectId.fromBytes(Uint8List bytes, [int startIndex = 0]) {
    if (bytes.length - startIndex < 12) {
      throw ArgumentError('Need at least 12 bytes to create ObjectId');
    }

    final ts =
        (bytes[startIndex + 0] << 24) |
        (bytes[startIndex + 1] << 16) |
        (bytes[startIndex + 2] << 8) |
        (bytes[startIndex + 3]);

    final machine =
        (bytes[startIndex + 4] << 16) |
        (bytes[startIndex + 5] << 8) |
        (bytes[startIndex + 6]);

    final pid = (bytes[startIndex + 7] << 8) | (bytes[startIndex + 8]);

    final inc =
        (bytes[startIndex + 9] << 16) |
        (bytes[startIndex + 10] << 8) |
        (bytes[startIndex + 11]);

    return ObjectId(ts, machine, pid, inc);
  }

  factory ObjectId.fromHex(String hex) {
    if (hex.length != 24) {
      throw ArgumentError('ObjectId hex must be 24 hex characters');
    }
    final bytes = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      final pair = hex.substring(i * 2, i * 2 + 2);
      bytes[i] = int.parse(pair, radix: 16);
    }
    return ObjectId.fromBytes(bytes);
  }

  Uint8List toBytes() {
    final b = Uint8List(12);
    b[0] = (timestamp >> 24) & 0xFF;
    b[1] = (timestamp >> 16) & 0xFF;
    b[2] = (timestamp >> 8) & 0xFF;
    b[3] = (timestamp) & 0xFF;
    b[4] = (machine >> 16) & 0xFF;
    b[5] = (machine >> 8) & 0xFF;
    b[6] = (machine) & 0xFF;
    b[7] = (pid >> 8) & 0xFF;
    b[8] = (pid) & 0xFF;
    b[9] = (increment >> 16) & 0xFF;
    b[10] = (increment >> 8) & 0xFF;
    b[11] = (increment) & 0xFF;
    return b;
  }

  DateTime get creationTime =>
      DateTime.fromMillisecondsSinceEpoch(timestamp * 1000, isUtc: true);

  @override
  String toString() => _bytesToHex(toBytes());

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ObjectId) return false;
    return timestamp == other.timestamp &&
        machine == other.machine &&
        pid == other.pid &&
        increment == other.increment;
  }

  // Dart supports operator overloading for comparison operators,
  // so provide <, >, <=, >= to match C# semantics.
  bool operator <(ObjectId other) => compareTo(other) < 0;
  bool operator >(ObjectId other) => compareTo(other) > 0;
  bool operator <=(ObjectId other) => compareTo(other) <= 0;
  bool operator >=(ObjectId other) => compareTo(other) >= 0;

  @override
  int get hashCode {
    var hash = 17;
    hash = 37 * hash + timestamp.hashCode;
    hash = 37 * hash + machine.hashCode;
    hash = 37 * hash + pid.hashCode;
    hash = 37 * hash + increment.hashCode;
    return hash;
  }

  @override
  int compareTo(ObjectId other) {
    var r = timestamp.compareTo(other.timestamp);
    if (r != 0) return r;
    r = machine.compareTo(other.machine);
    if (r != 0) return r;
    r = pid.compareTo(other.pid);
    if (r != 0) return r < 0 ? -1 : 1;
    return increment.compareTo(other.increment);
  }

  // --- Static helpers and generator ---

  static int _machine = _computeMachine();
  static int _pid = _computePid();
  static int _increment = Random().nextInt(1 << 24);

  static int _computeMachine() {
    try {
      final host = Platform.localHostname;
      return host.hashCode & 0x00ffffff;
    } catch (_) {
      return Random().nextInt(1 << 24) & 0x00ffffff;
    }
  }

  static int _computePid() {
    try {
      // Dart VM exposes pid via pid property on Process? Not standard across runtimes.
      // Use environment fallback when unavailable.
      return pidFromPlatform() & 0xffff;
    } catch (_) {
      return Random().nextInt(0x10000);
    }
  }

  static int pidFromPlatform() {
    // best-effort: try Process.runSync('bash','-c','echo $PPID') not ideal on Windows.
    // Provide conservative fallback to current timestamp bits.
    return DateTime.now().microsecondsSinceEpoch & 0xffff;
  }

  // ...existing code...
  static ObjectId newObjectId() {
    final ts = (DateTime.now().toUtc().millisecondsSinceEpoch / 1000).floor();
    _increment = (_increment + 1) & 0x00ffffff;
    return ObjectId(ts, _machine, _pid, _increment); // ← was missing
  }
  // ...existing code...

  // --- utilities ---

  static String _bytesToHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      final s = b.toRadixString(16).padLeft(2, '0');
      sb.write(s);
    }
    return sb.toString();
  }
}
