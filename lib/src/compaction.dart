/// Compaction: fold old history into the structured working state with one
/// model call, instead of re-summarising prose.
///
/// The model returns a JSON delta; only the delta's *shape* is trusted (it is
/// validated with the same schema validator as tool arguments), and the
/// pre-fold working state is written to the ledger so a bad fold is
/// recoverable by `rewind`. Folded events keep living in the ledger and
/// render at `summary` fidelity afterwards.
library;

import 'dart:convert';

import 'json_schema.dart';
import 'working_state.dart';

const Map<String, Object?> foldSchema = {
  'type': 'object',
  'properties': {
    'facts_add': {'type': 'array', 'items': {'type': 'string', 'maxLength': 500}, 'maxItems': 20},
    'decisions_add': {
      'type': 'array',
      'items': {
        'type': 'object',
        'properties': {
          'text': {'type': 'string', 'maxLength': 500},
          'reason': {'type': 'string', 'maxLength': 500},
        },
        'required': ['text'],
        'additionalProperties': false,
      },
      'maxItems': 20,
    },
    'questions_add': {'type': 'array', 'items': {'type': 'string', 'maxLength': 500}, 'maxItems': 20},
    'questions_resolve': {'type': 'array', 'items': {'type': 'string', 'maxLength': 500}, 'maxItems': 20},
    'next_actions': {'type': 'array', 'items': {'type': 'string', 'maxLength': 500}, 'maxItems': 20},
  },
  'additionalProperties': false,
};

const String foldInstructions =
    'You compact an agent transcript into structured working state. Read the transcript '
    'and answer with ONE JSON object and nothing else, with these optional keys: '
    '"facts_add" (confirmed facts worth keeping), "decisions_add" (objects with "text" and '
    '"reason"), "questions_add" (still-open questions), "questions_resolve" (open questions '
    'now answered, verbatim), "next_actions" (the full remaining plan, replacing the old '
    'one). Add only what the transcript states; never invent. Keep each entry under 500 '
    'characters and each list under 20 entries.';

/// Parse the model's fold reply: a JSON object, optionally fenced.
Map<String, Object?>? parseFoldReply(String text) {
  var body = text.trim();
  final fence = RegExp(r'```(?:json)?\s*\n(.*?)```', dotAll: true).firstMatch(body);
  if (fence != null) body = fence.group(1)!.trim();
  try {
    final decoded = jsonDecode(body);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

/// Validate and merge a fold delta. Returns an error message, or null.
String? applyFoldDelta(WorkingState ws, Map<String, Object?> delta) {
  final error = validateValue(foldSchema, delta);
  if (error != null) return error;
  final resolve = ((delta['questions_resolve'] as List?) ?? []).cast<String>();
  for (final q in resolve) {
    if (!ws.openQuestions.contains(q)) return 'questions_resolve names an unknown question: $q';
  }
  for (final f in ((delta['facts_add'] as List?) ?? []).cast<String>()) {
    if (!ws.confirmedFacts.contains(f)) ws.confirmedFacts.add(f);
  }
  for (final d in ((delta['decisions_add'] as List?) ?? [])) {
    final m = (d as Map).cast<String, Object?>();
    ws.decisions.add(RecordedDecision(text: m['text'] as String, reason: (m['reason'] as String?) ?? ''));
  }
  for (final q in ((delta['questions_add'] as List?) ?? []).cast<String>()) {
    if (!ws.openQuestions.contains(q)) ws.openQuestions.add(q);
  }
  ws.openQuestions = [for (final q in ws.openQuestions) if (!resolve.contains(q)) q];
  if (delta.containsKey('next_actions')) {
    ws.nextActions = ((delta['next_actions'] as List?) ?? []).cast<String>();
  }
  return null;
}
