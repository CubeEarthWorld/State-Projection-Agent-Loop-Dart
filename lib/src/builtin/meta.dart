/// Resident meta capabilities: `find_tools`, `peek`, and `search_history`
/// are always present; `spawn` is opt-in via [installSpawn].
///
/// There is no `done` capability anymore: completion is `Decision.finish`,
/// a property of the model's response handled directly by the session
/// loop, not something routed through the runtime like any other call. See
/// `llm.dart`'s `extractFinish`.
library;

import 'dart:async';

import '../artifacts.dart' show ArtifactStore, isRef, refKey;
import '../capability.dart';
import '../config.dart';
import '../discovery.dart' show ToolSearch;
import '../events.dart' show EventLedger;
import '../registry.dart';
import '../serialization.dart';
import '../run.dart' show Run;
import '../session.dart';
import 'defs.g.dart';

Object? _findTools(ToolContext ctx, Map<String, Object?> args) {
  final query = args['query'] as String;
  final category = args['category'] as String?;
  final k = (args['k'] as num?)?.toInt() ?? 8;
  final search = ctx.search as ToolSearch;
  final results = search.search(query, category: category, k: k, layer: 3);
  if (results.isEmpty) {
    final toc = (ctx.registry as Registry).tocText();
    return 'No tools matched "$query". Categories: ${toc.isNotEmpty ? toc : '(none)'}';
  }
  final session = ctx.session;
  if (session is Session) {
    session.activateTools([for (final s in results) s.tool.name]);
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
  final query = args['query'] as String?;
  final range = args['range'] as String?;
  if (!isRef(artifact)) {
    return 'Error: $artifact is not a valid artifact reference; expected {"\$artifact": "<id>"}';
  }
  final store = ctx.store as ArtifactStore;
  return store.peek((artifact as Map)[refKey] as String, query: query, range: range);
}

Object? _searchHistory(ToolContext ctx, Map<String, Object?> args) {
  final query = args['query'] as String;
  final k = (args['k'] as num?)?.toInt() ?? 10;
  final ledger = ctx.ledger as EventLedger?;
  final run = ctx.run as Run?;
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
  final task = args['task'] as String;
  final kernel = args['kernel'] as String?;
  final toolScope = (args['tool_scope'] as List?)?.cast<String>();
  final model = args['model'] as String?;
  final maxSteps = (args['max_steps'] as num?)?.toInt() ?? 15;
  final checklistIds = (args['checklist_ids'] as List?)?.cast<String>();

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

  Registry childRegistry;
  if (toolScope != null && toolScope.isNotEmpty) {
    childRegistry = parent.registry.subset(toolScope);
  } else {
    childRegistry = Registry();
    for (final cap in parent.registry.all_) {
      if (cap.name != 'meta.agent.spawn') {
        // no recursive swarm by default
        childRegistry.register(cap, replace: true);
      }
    }
  }

  final childConfig = Config.fromMap(deepCopy(parent.config.toMap()));
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

const Map<String, Function> _handlers = {
  'meta.tool.find': _findTools,
  'meta.artifact.peek': _peek,
  'meta.history.search': _searchHistory,
};

/// Register the resident meta capabilities if absent.
void ensureMetaTools(Registry registry) {
  for (final definition in load('meta') as List) {
    final map = (definition as Map).cast<String, Object?>();
    final name = map['name'] as String;
    if (!registry.contains(name)) {
      registry.register(map, handler: _handlers[name], wantsCtx: true);
    }
  }
}

/// Opt-in sub-agent capability for swarm-style setups.
void installSpawn(Registry registry) {
  if (!registry.contains('meta.agent.spawn')) {
    registry.register((load('spawn') as Map).cast<String, Object?>(),
        handler: _spawn, wantsCtx: true);
  }
}
