/// Toolkits: root-confined filesystem and shell capabilities.
///
/// Off unless installed: a generic runtime must not assume a filesystem.
/// Definitions are the shared `toolkits.json`; every path is resolved under
/// [root] and rejected if it escapes it.
library;

import 'dart:io';

import '../capability.dart';
import '../registry.dart';
import 'builtin.dart' show install;
import 'defs.g.dart';

/// Install `filesystem.file.*` (and, with [shell], `shell.command.run`)
/// confined to [root].
void installToolkits(Registry registry, Directory root, {bool shell = true}) {
  final rootPath = root.absolute.resolveSymbolicLinksSync();

  String resolve(String relative) {
    final candidate = File('$rootPath${Platform.pathSeparator}$relative').absolute.path;
    final normalized = Uri.file(candidate).normalizePath().toFilePath();
    if (normalized != rootPath && !normalized.startsWith('$rootPath${Platform.pathSeparator}')) {
      throw ArgumentError('path escapes the workspace: $relative');
    }
    return normalized;
  }

  Object? list(Map<String, Object?> args) {
    final dir = Directory(resolve((args['path'] as String?) ?? ''));
    if (!dir.existsSync()) return <String>[];
    final paths = [
      for (final e in dir.listSync(recursive: true))
        if (e is File) e.path.substring(rootPath.length + 1).replaceAll('\\', '/'),
    ]..sort();
    return paths;
  }

  Object? read(Map<String, Object?> args) => File(resolve(args['path'] as String)).readAsStringSync();

  Object? write(Map<String, Object?> args) {
    final file = File(resolve(args['path'] as String));
    file.parent.createSync(recursive: true);
    final content = args['content'] as String;
    file.writeAsStringSync(content);
    return 'wrote ${content.length} chars to ${args['path']}';
  }

  Future<Object?> run(Map<String, Object?> args) async {
    final command = args['command'] as String;
    final result = Platform.isWindows
        ? await Process.run('cmd', ['/c', command], workingDirectory: rootPath)
        : await Process.run('sh', ['-c', command], workingDirectory: rootPath);
    return 'exit=${result.exitCode}\n${result.stdout}${result.stderr}'.trimRight();
  }

  final handlers = <String, PlainHandler>{
    'filesystem.file.list': list,
    'filesystem.file.read': read,
    'filesystem.file.write': write,
    if (shell) 'shell.command.run': run,
  };
  install(registry, [
    for (final def in load('toolkits') as List)
      if (handlers.containsKey((def as Map)['name'])) def,
  ], handlers);
}
