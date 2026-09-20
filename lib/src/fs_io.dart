/// The `dart:io` filesystem, chosen by the conditional import in `fs.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'fs.dart';

FileSystem? createFileSystem() => const _IoFileSystem();

class _IoFileSystem implements FileSystem {
  const _IoFileSystem();

  @override
  bool exists(String path) => File(path).existsSync();

  @override
  void createDir(String path) => Directory(path).createSync(recursive: true);

  @override
  String readString(String path) => File(path).readAsStringSync();

  @override
  List<String> readLines(String path) {
    final file = File(path);
    if (!file.existsSync()) return const <String>[];
    // `readAsLinesSync` throws on malformed UTF-8. Appends are unbuffered,
    // so a crash mid-append can truncate the last line inside a multi-byte
    // character — and then a whole run becomes unreadable over one torn
    // line. Decoding permissively leaves that line as garbage for the
    // caller's own parse to reject and skip.
    return const LineSplitter()
        .convert(utf8.decode(file.readAsBytesSync(), allowMalformed: true));
  }

  @override
  void writeString(String path, String text) {
    final file = File(path);
    createDir(file.parent.path);
    file.writeAsStringSync(text, encoding: utf8);
  }

  @override
  void appendString(String path, String text) {
    final file = File(path);
    createDir(file.parent.path);
    file.writeAsStringSync(text, mode: FileMode.append, encoding: utf8);
  }

  @override
  void rename(String from, String to) => File(from).renameSync(to);

  @override
  String get currentDirectory => Directory.current.path;

  @override
  String absolutePath(String path) => Directory(path).absolute.path;

  @override
  String? parentOf(String path) {
    final parent = Directory(path).parent.path;
    return parent == path ? null : parent;
  }

  @override
  List<String> listFiles(String path) {
    final dir = Directory(path);
    if (!dir.existsSync()) return const <String>[];
    return [
      for (final entry in dir.listSync().whereType<File>())
        entry.uri.pathSegments.last,
    ];
  }
}
