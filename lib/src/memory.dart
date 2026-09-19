/// Cross-session memory: notes keyed outside any run namespace.
///
/// Notes outlive runs and sessions. Nothing is injected into the context
/// automatically — only what a search returns enters it, as an observation
/// — so a stale note can never masquerade as an instruction. The store is
/// two methods, so a database or vector index can replace the default
/// without touching the pack.
library;

import 'dart:convert';

import 'fs.dart';

import 'discovery.dart' show tokenize;
import 'ids.dart';
import 'serialization.dart';

class Note {
  Note({required this.id, required this.text, List<String>? tags, this.ts = 0.0})
      : tags = tags ?? <String>[];

  final String id;
  final String text;
  final List<String> tags;
  final double ts;

  Map<String, Object?> toDict() => {'id': id, 'text': text, 'tags': tags, 'ts': ts};

  factory Note.fromDict(Map<String, Object?> d) => Note(
        id: d['id'] as String,
        text: d['text'] as String,
        tags: ((d['tags'] as List?) ?? const []).cast<String>(),
        ts: (d['ts'] as num?)?.toDouble() ?? 0.0,
      );
}

abstract interface class MemoryStore {
  Note save(String text, List<String> tags);

  List<Note> search(String query, int k);
}

/// One JSONL file of notes, or process memory when [path] is null. Search
/// is lexical: the notes sharing the most query tokens (text and tags) come
/// first, newest first among equals.
class JsonlMemoryStore implements MemoryStore {
  JsonlMemoryStore([this.path]) {
    final target = path;
    if (target == null) return;
    for (final line in requireFileSystem('Persistent memory').readLines(target)) {
      if (line.trim().isNotEmpty) {
        _notes.add(Note.fromDict((jsonDecode(line) as Map).cast<String, Object?>()));
      }
    }
  }

  /// JSONL file path, or null to keep notes in process memory only.
  final String? path;
  final List<Note> _notes = [];

  @override
  Note save(String text, List<String> tags) {
    final note = Note(
        id: newId('note'), text: text, tags: List.of(tags), ts: DateTime.now().millisecondsSinceEpoch / 1000.0);
    _notes.add(note);
    final target = path;
    if (target != null) {
      requireFileSystem('Persistent memory')
          .appendString(target, '${dumps(note.toDict())}\n');
    }
    return note;
  }

  @override
  List<Note> search(String query, int k) {
    final terms = tokenize(query).toSet();
    if (terms.isEmpty) return [];
    final scored = [
      for (final n in _notes)
        (terms.intersection(tokenize('${n.text} ${n.tags.join(' ')}').toSet()).length, n),
    ]..removeWhere((s) => s.$1 == 0);
    scored.sort((a, b) => a.$1 != b.$1 ? b.$1.compareTo(a.$1) : b.$2.ts.compareTo(a.$2.ts));
    return [for (final s in scored.take(k)) s.$2];
  }
}
