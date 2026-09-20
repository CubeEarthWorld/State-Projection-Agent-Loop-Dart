/// The one place `dart:io` is allowed to enter the runtime.
///
/// The core loop is pure Dart and runs anywhere; only *optional* persistence
/// needs a filesystem - the JSONL ledger and the on-disk artifact store. An
/// unconditional `import 'dart:io'` in those files would make the whole
/// library unusable on web even for callers who never ask for either, so
/// the platform implementation arrives through a conditional import and is
/// simply absent where there is no filesystem.
///
/// Nothing else under `lib/src/` may import `dart:io`. The native-only
/// filesystem and shell *toolkit* is not part of the core at all; it lives
/// behind the separate `package:state_projection_loop/toolkits.dart` entry
/// point.
library;

import 'fs_stub.dart' if (dart.library.io) 'fs_io.dart' as platform;

/// The handful of synchronous operations the ledger and artifact store need.
///
/// Paths are plain strings so no `dart:io` type reaches the public API -
/// which also brings the Dart surface in line with the Python port, where
/// these are `str`/`Path` rather than a platform object.
abstract interface class FileSystem {
  bool exists(String path);

  /// Create [path] and any missing parents; a no-op when it already exists.
  void createDir(String path);

  String readString(String path);

  /// The file's lines without terminators; empty when the file is absent.
  List<String> readLines(String path);

  void writeString(String path, String text);

  void appendString(String path, String text);

  void rename(String from, String to);

  /// Names (not full paths) of the files directly inside [path];
  /// empty when the directory is absent.
  List<String> listFiles(String path);

  /// The process working directory.
  String get currentDirectory;

  String absolutePath(String path);

  /// The parent directory, or null once [path] is a filesystem root.
  String? parentOf(String path);
}

/// The platform filesystem, or `null` where there is none (web).
final FileSystem? fileSystem = platform.createFileSystem();

/// The filesystem, or a clear explanation instead of a `NoSuchMethodError`
/// three frames deep.
FileSystem requireFileSystem(String feature) {
  final fs = fileSystem;
  if (fs == null) {
    throw UnsupportedError(
      '$feature needs a filesystem, which this platform does not provide. '
      'Leave the directory unset to keep everything in memory.',
    );
  }
  return fs;
}

/// Join with `/`, which every platform's path APIs accept, including
/// Windows. Avoids a `dart:io`-only path helper for the two call sites
/// that need one.
String joinPath(String base, String name) =>
    base.endsWith('/') || base.endsWith(r'\') ? '$base$name' : '$base/$name';
