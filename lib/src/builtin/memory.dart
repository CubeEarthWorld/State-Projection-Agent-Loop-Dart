/// Handlers of the `memory` pack over the session's `MemoryStore`.
library;

import '../capability.dart';
import '../session.dart';

Object? _save(ToolContext ctx, Map<String, Object?> args) {
  final note = (ctx.session as Session)
      .memory
      .save(args['text'] as String, ((args['tags'] as List?) ?? const []).cast<String>());
  return 'saved note ${note.id}';
}

Object? _search(ToolContext ctx, Map<String, Object?> args) {
  final notes = (ctx.session as Session).memory.search(args['query'] as String, (args['k'] as num?)?.toInt() ?? 5);
  if (notes.isEmpty) return 'No notes matched.';
  return [
    for (final n in notes)
      {
        'id': n.id,
        'text': n.text,
        'tags': n.tags,
        'saved': DateTime.fromMillisecondsSinceEpoch((n.ts * 1000).round(), isUtc: true)
            .toIso8601String()
            .substring(0, 10),
      },
  ];
}

final Map<String, CtxHandler> memoryHandlers = {
  'memory.note.save': _save,
  'memory.note.search': _search,
};
