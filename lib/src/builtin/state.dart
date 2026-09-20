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

String _appendUnique(List<String> items, String text, String label) {
  if (!items.contains(text)) items.add(text);
  return '$label: $text';
}

String _setGoal(ToolContext ctx, Map<String, Object?> args) {
  final text = args.str('text');
  ctx.workingState.goal = text;
  return 'goal set: $text';
}

String _addFact(ToolContext ctx, Map<String, Object?> args) =>
    _appendUnique(ctx.workingState.confirmedFacts, args.str('text'), 'fact recorded');

String _addConstraint(ToolContext ctx, Map<String, Object?> args) =>
    _appendUnique(ctx.workingState.constraints, args.str('text'), 'constraint recorded');

String _recordDecision(ToolContext ctx, Map<String, Object?> args) {
  final text = args.str('text');
  final reason = args.strOrNull('reason') ?? '';
  ctx.workingState.decisions.add(RecordedDecision(text: text, reason: reason));
  return 'decision recorded: $text${reason.isNotEmpty ? ' (because: $reason)' : ''}';
}

String _addOpenQuestion(ToolContext ctx, Map<String, Object?> args) =>
    _appendUnique(ctx.workingState.openQuestions, args.str('text'), 'open question added');

String _resolveOpenQuestion(ToolContext ctx, Map<String, Object?> args) {
  final text = args.str('text');
  final ws = ctx.workingState;
  ws.openQuestions = ws.openQuestions.where((q) => q != text).toList();
  return 'open question resolved: $text';
}

String _setNextActions(ToolContext ctx, Map<String, Object?> args) {
  final actions = args.strs('actions');
  ctx.workingState.nextActions = List<String>.from(actions);
  // Python renders the list with repr(), i.e. quoted elements.
  // ponytail: plain single quotes; port Python's quote-swapping/escaping
  // repr if an action ever contains a quote or a backslash.
  return "next_actions set: [${actions.map((a) => "'$a'").join(', ')}]";
}

String _extraSet(ToolContext ctx, Map<String, Object?> args) {
  final path = args.str('path');
  final value = args['value'];
  final (node, leaf) = _walkExtra(ctx.workingState.extra, path, create: true);
  node[leaf] = value;
  return 'extra.$path = ${dumps(value)}';
}

Object? _extraGet(ToolContext ctx, Map<String, Object?> args) {
  final path = args.str('path');
  try {
    final (node, leaf) = _walkExtra(ctx.workingState.extra, path);
    if (!node.containsKey(leaf)) return '(not set: $path)';
    return node[leaf];
  } on StateError {
    // Only the missing-key case (Python catches KeyError and nothing
    // else); an empty path is an ArgumentError and must surface as a
    // failed call, not as "(not set: )".
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
