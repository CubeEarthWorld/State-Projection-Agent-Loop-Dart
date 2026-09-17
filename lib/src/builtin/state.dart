/// Handlers of the `state` pack: the LLM edits the structured working state
/// through a small set of typed capabilities instead of an arbitrary map.
///
/// Editors of the working state are exactly two: user code
/// (`session.workingState` / seed) and the LLM via these capabilities. A
/// game master installs this pack; a simple support bot does not — the core
/// projection is identical either way.
library;

import '../capability.dart';
import '../working_state.dart';
import '../serialization.dart';

(Map<String, Object?>, String) _walkExtra(Map<String, Object?> extra, String path,
    {bool create = false}) {
  final parts = path.split('.').where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) throw ArgumentError('empty path');
  var node = extra;
  for (final part in parts.sublist(0, parts.length - 1)) {
    final existing = node[part];
    if (existing is! Map) {
      if (!create) throw StateError('KeyError: $path');
      node[part] = <String, Object?>{};
    }
    node = (node[part] as Map).cast<String, Object?>();
  }
  return (node, parts.last);
}

String _setGoal(ToolContext ctx, Map<String, Object?> args) {
  final text = args['text'] as String;
  ctx.workingState.goal = text;
  return 'goal set: $text';
}

String _addFact(ToolContext ctx, Map<String, Object?> args) {
  final text = args['text'] as String;
  final ws = ctx.workingState;
  if (!ws.confirmedFacts.contains(text)) ws.confirmedFacts.add(text);
  return 'fact recorded: $text';
}

String _addConstraint(ToolContext ctx, Map<String, Object?> args) {
  final text = args['text'] as String;
  final ws = ctx.workingState;
  if (!ws.constraints.contains(text)) ws.constraints.add(text);
  return 'constraint recorded: $text';
}

String _recordDecision(ToolContext ctx, Map<String, Object?> args) {
  final text = args['text'] as String;
  final reason = (args['reason'] as String?) ?? '';
  ctx.workingState.decisions.add(RecordedDecision(text: text, reason: reason));
  return 'decision recorded: $text${reason.isNotEmpty ? ' (because: $reason)' : ''}';
}

String _addOpenQuestion(ToolContext ctx, Map<String, Object?> args) {
  final text = args['text'] as String;
  final ws = ctx.workingState;
  if (!ws.openQuestions.contains(text)) ws.openQuestions.add(text);
  return 'open question added: $text';
}

String _resolveOpenQuestion(ToolContext ctx, Map<String, Object?> args) {
  final text = args['text'] as String;
  final ws = ctx.workingState;
  ws.openQuestions = ws.openQuestions.where((q) => q != text).toList();
  return 'open question resolved: $text';
}

String _setNextActions(ToolContext ctx, Map<String, Object?> args) {
  final actions = ((args['actions'] as List?) ?? []).cast<String>();
  ctx.workingState.nextActions = List<String>.from(actions);
  return 'next_actions set: $actions';
}

String _extraSet(ToolContext ctx, Map<String, Object?> args) {
  final path = args['path'] as String;
  final value = args['value'];
  final (node, leaf) = _walkExtra(ctx.workingState.extra, path, create: true);
  node[leaf] = value;
  return 'extra.$path = ${dumps(value)}';
}

Object? _extraGet(ToolContext ctx, Map<String, Object?> args) {
  final path = args['path'] as String;
  try {
    final (node, leaf) = _walkExtra(ctx.workingState.extra, path);
    if (!node.containsKey(leaf)) return '(not set: $path)';
    return node[leaf];
  } catch (_) {
    return '(not set: $path)';
  }
}

const Map<String, CtxHandler> stateHandlers = {
  'state.goal.set': _setGoal,
  'state.fact.add': _addFact,
  'state.constraint.add': _addConstraint,
  'state.decision.record': _recordDecision,
  'state.question.add': _addOpenQuestion,
  'state.question.resolve': _resolveOpenQuestion,
  'state.next_actions.set': _setNextActions,
  'state.extra.set': _extraSet,
  'state.extra.get': _extraGet,
};
