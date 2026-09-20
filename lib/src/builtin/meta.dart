/// Handlers of the `meta` pack (`meta.tool.find`, `meta.artifact.peek`,
/// `meta.history.search`) and the opt-in `spawn` pack (`meta.agent.spawn`).
///
/// There is no `done` capability: completion is `Decision.finish`, a
/// property of the model's response handled directly by the session loop,
/// not something routed through the runtime like any other call. See
/// `llm.dart`'s `extractFinish`.
library;

import 'dart:async';
import 'dart:math' show max;

import '../artifacts.dart' show isRef, refKey;
import '../capability.dart';
import '../events.dart' show Snapshot;
import '../run.dart' show ApprovalRequest, nowSeconds, terminalStates;
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

const String spawnName = 'meta.agent.spawn';
const String askName = 'meta.user.ask';

/// Wide enough for any real fan-out; narrow enough that a confused model
/// cannot open fifty model streams in one call.
const int maxFanout = 8;
const String defaultKernel = 'You are a focused sub-agent. Complete the task, then call '
    'finish(result) with the outcome. You cannot ask the user anything.';

/// One child's slice of what the parent has left of one limit.
num? _share(num? limit, num used, int n) => limit == null ? null : max(0, limit - used) / n;

/// One sub-agent: an ordinary Run in the parent's ledger, so it is
/// auditable, resumable and recoverable by the machinery that already
/// exists. [restored] reattaches a child spawned by an earlier invocation of
/// this same command.
Session childSession(Session parent, Map<String, Object?> spec, int n, {Snapshot? restored}) {
  // No scope means everything but spawn itself (no recursive swarm by
  // default). Always a subset(), so the parent's deny-list carries over.
  final scope = spec.strsOrNull('tool_scope') ??
      [
        for (final cap in parent.registry.capabilities)
          if (cap.name != spawnName) cap.name,
      ];
  final registry = parent.registry.subset(scope);
  registry.disable([askName]); // a sub-agent has no user to ask

  final cfg = parent.config.clone();
  cfg.mode = 'job';
  cfg.resultSchema = null; // the parent's finish schema is not the child's contract
  cfg.budget.maxSteps = spec.intOr('max_steps', 15);
  final used = parent.budget;
  cfg.budget.maxTokens =
      _share(cfg.budget.maxTokens, used.promptTokens + used.completionTokens, n)?.toInt();
  cfg.budget.maxCost = _share(cfg.budget.maxCost, used.cost, n)?.toDouble();
  cfg.budget.maxSeconds = _share(cfg.budget.maxSeconds, nowSeconds() - used.started, 1)?.toDouble();

  final documents = [
    for (final id in spec.strsOrNull('checklist_ids') ?? const <String>[])
      ((parent.checklists.execute('export', {'id': id}) as Map)['checklists'] as List).single,
  ];
  final model = spec.strOrNull('model');
  return Session(
    parent.spawnLlmFactory != null ? parent.spawnLlmFactory!(model) : parent.llm,
    kernel: spec.strOrNull('kernel') ?? defaultKernel,
    config: cfg,
    registry: registry,
    builtins: const [], // whatever the scope carried, nothing re-installed behind it
    embedder: parent.search.embedder,
    seed: restored != null
        ? null
        : {
            'checklists': {'version': 1, 'checklists': documents},
          },
    policy: parent.policy,
    ledger: parent.ledger,
    memory: parent.memory,
    hooks: parent.runtime.hooks,
    spawnLlmFactory: parent.spawnLlmFactory,
    restored: restored,
  );
}

/// Runs one child to a terminal state or to its next pause.
Future<void> _drive(Session child, Map<String, Object?> spec, String? resolution, bool fresh) async {
  try {
    if (resolution != null && child.run.state == 'WAITING_FOR_APPROVAL') {
      child.resolveApproval(resolution);
    }
    if (terminalStates.contains(child.run.state) || child.run.state.startsWith('WAITING')) return;
    await (fresh ? child.runJob(spec.str('task')) : child.resume());
  } catch (exc) {
    // A child's failure is the parent's observation.
    if (!terminalStates.contains(child.run.state)) child.cancel('${exc.runtimeType}: $exc');
  }
}

Map<String, Object?> _entry(Session child, Map<String, Object?> spec) {
  String reason = '';
  for (final event in child.ledger.iterRun(child.run.id)) {
    if (event.type == 'run_state_changed') reason = '${event.data['reason'] ?? ''}';
  }
  final completed = child.run.state == 'COMPLETED';
  return {
    'run_id': child.run.id,
    'state': child.run.state,
    'result': completed ? child.run.result : null,
    if (!completed) 'error': reason,
    if ((spec.strsOrNull('checklist_ids') ?? const []).isNotEmpty)
      'checklists': child.checklists.toDict(),
  };
}

Future<Object?> _spawn(ToolContext ctx, Map<String, Object?> args) async {
  final tasks = args.maps('tasks');
  final parent = ctx.session;
  if (parent is! Session) {
    throw StateError('spawn requires a session context');
  }
  if (tasks.isEmpty || tasks.length > maxFanout) {
    throw ArgumentError('spawn takes 1 to $maxFanout tasks, got ${tasks.length}');
  }
  for (final spec in tasks) {
    final ids = spec.strsOrNull('checklist_ids') ?? const <String>[];
    // Check before exporting: a duplicated id made the export throw on the
    // second lookup instead of saying what was wrong.
    if (ids.toSet().length != ids.length) {
      throw ArgumentError('Duplicate checklist_ids');
    }
    if (spec.strOrNull('model') != null && parent.spawnLlmFactory == null) {
      throw StateError('spawn(model=...) requires Session(spawnLlmFactory: ...)');
    }
  }

  // Re-invoked after forwarding a child's approval? Pick the same children
  // back up out of the ledger instead of starting the work again.
  List<String>? known;
  for (final event in ctx.ledger!.iterRun(ctx.run!.id)) {
    if (event.type == 'run_spawned' && event.data['command_id'] == ctx.commandId) {
      known = (event.data['child_run_ids'] as List).cast<String>();
    }
  }
  final fresh = known == null;
  final children = fresh
      ? [for (final spec in tasks) childSession(parent, spec, tasks.length)]
      : [
          for (var i = 0; i < tasks.length; i++)
            childSession(parent, tasks[i], tasks.length,
                restored: ctx.ledger!.loadSnapshot(known[i])),
        ];
  if (fresh) {
    ctx.ledger!.append(ctx.run!.id, 'run_spawned', {
      'command_id': ctx.commandId,
      'child_run_ids': [for (final c in children) c.run.id],
    });
  }

  // The forwarded approval belongs to the first child still waiting: the
  // ones before it are terminal, or they would have been forwarded first.
  Session? forwarded;
  if (ctx.resolution != null) {
    for (final child in children) {
      if (child.run.state == 'WAITING_FOR_APPROVAL') {
        forwarded = child;
        break;
      }
    }
  }
  final spent = [for (final c in children) (c.budget.promptTokens, c.budget.completionTokens)];

  parent.children.addAll(children);
  try {
    await Future.wait([
      for (var i = 0; i < children.length; i++)
        _drive(children[i], tasks[i], identical(children[i], forwarded) ? ctx.resolution : null, fresh),
    ]);
  } finally {
    for (final child in children) {
      parent.children.remove(child);
    }
  }
  for (var i = 0; i < children.length; i++) {
    parent.budget.noteUsage(children[i].budget.promptTokens - spent[i].$1,
        children[i].budget.completionTokens - spent[i].$2, parent.config);
  }

  for (final child in children) {
    if (child.run.state == 'WAITING_FOR_USER') {
      child.cancel('a sub-agent has no user to ask');
    } else if (!terminalStates.contains(child.run.state) &&
        child.run.state != 'WAITING_FOR_APPROVAL') {
      child.cancel('interrupted');
    }
  }
  for (final child in children) {
    if (child.run.state == 'WAITING_FOR_APPROVAL') {
      // Park this command on the child's approval; the host resolves it on
      // the root session and the runtime re-invokes us with the decision.
      final request = child.run.pendingApproval!;
      return ApprovalRequest(
        id: request.id,
        commandId: request.commandId,
        effects: request.effects,
        reason: 'sub-agent ${child.run.id}: ${request.reason}',
        policyRevision: request.policyRevision,
        expiresAt: request.expiresAt,
      );
    }
  }
  return [for (var i = 0; i < children.length; i++) _entry(children[i], tasks[i])];
}

const Map<String, CtxHandler> metaHandlers = {
  'meta.tool.find': _findTools,
  'meta.artifact.peek': _peek,
  'meta.history.search': _searchHistory,
};

const Map<String, CtxHandler> spawnHandlers = {'meta.agent.spawn': _spawn};
