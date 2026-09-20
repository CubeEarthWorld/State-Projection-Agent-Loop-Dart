/// Handlers of the `meta` pack (`meta.tool.find`, `meta.artifact.peek`,
/// `meta.history.search`) and the opt-in `spawn` pack (`meta.agent.spawn`).
///
/// There is no `done` capability: completion is `Decision.finish`, a
/// property of the model's response handled directly by the session loop,
/// not something routed through the runtime like any other call. See
/// `llm.dart`'s `extractFinish`.
library;

import 'dart:async';

import '../artifacts.dart' show isRef, refKey;
import '../capability.dart';
import '../serialization.dart';
import '../session.dart';

Object? _findTools(ToolContext ctx, Map<String, Object?> args) {
  final query = args.str('query');
  final results =
      ctx.search!.search(query, category: args.strOrNull('category'), k: args.intOr('k', 8), layer: 3);
  if (results.isEmpty) {
    final toc = ctx.registry.tocText();
    return 'No tools matched "$query". Categories: ${toc.isNotEmpty ? toc : '(none)'}';
  }
  final session = ctx.session;
  if (session is Session) {
    session.activate([for (final s in results) s.tool.name]);
  }
  return [
    for (final s in results)
      {
        'name': s.tool.name,
        'category': s.tool.category,
        'card': s.tool.cardText(),
        'score': (s.score * 1000).round() / 1000,
      },
  ];
}

String _peek(ToolContext ctx, Map<String, Object?> args) {
  final artifact = args['artifact'];
  if (!isRef(artifact)) {
    return 'Error: ${dumps(artifact)} is not a valid artifact reference; expected {"\$artifact": "<id>"}';
  }
  return ctx.store!.peek((artifact as Map)[refKey] as String,
      query: args.strOrNull('query'), range: args.strOrNull('range'));
}

Object? _searchHistory(ToolContext ctx, Map<String, Object?> args) {
  final query = args.str('query');
  final k = args.intOr('k', 10);
  final ledger = ctx.ledger;
  final run = ctx.run;
  if (ledger == null || run == null) {
    return 'History search is unavailable (no ledger configured for this session).';
  }
  final q = query.toLowerCase();
  final hits = <String>[];
  for (final event in ledger.iterRun(run.id)) {
    final blob = event.data.toString();
    if (blob.toLowerCase().contains(q)) {
      final preview = blob.length > 300 ? blob.substring(0, 300) : blob;
      hits.add('[${event.sequence}] ${event.type}: $preview');
      if (hits.length >= k) break;
    }
  }
  return hits.isNotEmpty ? hits : ['No ledger events matched "$query".'];
}

Future<Object?> _spawn(ToolContext ctx, Map<String, Object?> args) async {
  final task = args.str('task');
  final kernel = args.strOrNull('kernel');
  final toolScope = args.strs('tool_scope');
  final model = args.strOrNull('model');
  final maxSteps = args.intOr('max_steps', 15);
  final checklistIds = args.strsOrNull('checklist_ids');

  final parent = ctx.session;
  if (parent is! Session) {
    throw StateError('spawn requires a session context');
  }
  if (model != null && parent.spawnLlmFactory == null) {
    throw StateError('spawn(model=...) requires Session(spawnLlmFactory: ...)');
  }
  if (checklistIds != null && checklistIds.toSet().length != checklistIds.length) {
    throw ArgumentError('Duplicate checklist_ids');
  }
  final documents = [for (final id in checklistIds ?? <String>[])
    ((parent.checklists.execute('export', {'id': id}) as Map)['checklists'] as List).single];
  final llm = parent.spawnLlmFactory != null ? parent.spawnLlmFactory!(model) : parent.llm;

  // No scope means everything but spawn itself (no recursive swarm by
  // default). Always a subset(), so the parent's deny-list carries over.
  final childRegistry = parent.registry.subset(toolScope.isNotEmpty
      ? toolScope
      : [
          for (final cap in parent.registry.capabilities)
            if (cap.name != 'meta.agent.spawn') cap.name,
        ]);

  final childConfig = parent.config.clone();
  childConfig.mode = 'job';
  childConfig.budget.maxSteps = maxSteps;
  childConfig.persistence.ledgerDirectory = null; // child ledger is not persisted independently

  final child = Session(
    llm,
    kernel: kernel ?? 'You are a focused sub-agent. Complete the task, then call finish(result) with the outcome.',
    config: childConfig,
    registry: childRegistry,
    embedder: parent.search.embedder,
    seed: {'checklists': {'version': 1, 'checklists': documents}},
    policy: parent.policy,
  );
  final result = await child.runJob(task);
  if (checklistIds != null) return {'result': result, 'checklists': child.checklists.toDict()};
  return result;
}

const Map<String, CtxHandler> metaHandlers = {
  'meta.tool.find': _findTools,
  'meta.artifact.peek': _peek,
  'meta.history.search': _searchHistory,
};

const Map<String, CtxHandler> spawnHandlers = {'meta.agent.spawn': _spawn};
