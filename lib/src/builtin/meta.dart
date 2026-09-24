/// Handlers of the `meta` pack (`meta.tool.find`, `meta.artifact.peek`,
/// `meta.history.search`) and the opt-in `spawn` pack (`meta.agent.spawn`,
/// `meta.agent.join`).
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
import '../events.dart' show Event, Snapshot;
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
      hits.add('[${event.sequence}] ${event.type}: $blob');
      if (hits.length >= k) break;
    }
  }
  return hits.isNotEmpty ? hits : ['No ledger events matched "$query".'];
}

const String spawnName = 'meta.agent.spawn';
const String joinName = 'meta.agent.join';
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
          if (cap.name != spawnName && cap.name != joinName) cap.name,
      ];
  final registry = parent.registry.subset(scope);
  registry.disable([askName]); // a sub-agent has no user to ask

  final cfg = parent.config.clone();
  cfg.mode = 'job';
  cfg.resultSchema = null; // the parent's finish schema is not the child's contract
  cfg.budget.maxSteps = spec.intOr('max_steps', 15);
  final used = parent.budget;
  // Sub-agents still outstanding have spent from the same allowance but have
  // not been charged back yet; a new child must not be handed it twice.
  final live = [for (final c in parent.children) c.budget];
  var spent = used.promptTokens + used.completionTokens;
  var spentCost = used.cost;
  for (final b in live) {
    spent += b.promptTokens + b.completionTokens;
    spentCost += b.cost;
  }
  cfg.budget.maxTokens = _share(cfg.budget.maxTokens, spent, n)?.toInt();
  cfg.budget.maxCost = _share(cfg.budget.maxCost, spentCost, n)?.toDouble();
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

/// This run's `run_spawned` events, oldest first.
List<Event> _spawned(ToolContext ctx, [String? commandId]) => [
      for (final e in ctx.ledger!.iterRun(ctx.run!.id))
        if (e.type == 'run_spawned' && (commandId == null || e.data['command_id'] == commandId)) e,
    ];

/// The (child, spec) pairs a join should act on. Outstanding children are the
/// live sessions; anything already collected is rebuilt from its snapshot, so
/// a join can still read a result the nudge announced.
List<(Session, Map<String, Object?>)> _lookup(
    ToolContext ctx, Session parent, List<String>? runIds) {
  final outstanding = {for (final c in parent.children) c.run.id: c};
  final specs = <String, Map<String, Object?>>{};
  for (final event in _spawned(ctx)) {
    final command = ctx.run!.commands[event.data['command_id']];
    final tasks = (command?.arguments['tasks'] as List?) ?? const [];
    final ids = event.data['child_run_ids'] as List;
    for (var i = 0; i < ids.length && i < tasks.length; i++) {
      specs[ids[i] as String] = (tasks[i] as Map).cast<String, Object?>();
    }
  }
  if (runIds == null) {
    return [
      for (final entry in outstanding.entries)
        (entry.value, specs[entry.key] ?? const <String, Object?>{}),
    ];
  }
  final pairs = <(Session, Map<String, Object?>)>[];
  for (final runId in runIds) {
    final spec = specs[runId];
    if (spec == null) throw ArgumentError('$runId is not a sub-agent of this run');
    pairs.add((
      outstanding[runId] ?? childSession(parent, spec, 1, restored: ctx.ledger!.loadSnapshot(runId)),
      spec,
    ));
  }
  return pairs;
}

/// Drive every child to a terminal state (or stop it), then report.
///
/// Returns an [ApprovalRequest] instead when a child is waiting on one: the
/// runtime parks this command and re-invokes it with the decision.
Future<Object?> _joinChildren(Session parent, List<(Session, Map<String, Object?>)> pairs,
    String? resolution, {required bool cancel}) async {
  final children = [for (final (child, _) in pairs) child];
  // The forwarded approval belongs to the first child still waiting: the ones
  // before it are terminal, or they would have been forwarded first.
  if (resolution != null) {
    for (final child in children) {
      if (child.run.state == 'WAITING_FOR_APPROVAL') {
        child.resolveApproval(resolution);
        break;
      }
    }
  }
  final spent = [for (final c in children) (c.budget.promptTokens, c.budget.completionTokens)];

  for (final child in children) {
    if (cancel) {
      child.interrupt();
    } else {
      child.drive();
    }
  }
  await Future.wait([
    for (final c in children)
      if (c.driver != null) c.driver!.catchError((Object _) {}),
  ]);

  for (final child in children) {
    if (child.run.state == 'WAITING_FOR_USER') {
      child.cancel('a sub-agent has no user to ask');
    } else if (cancel && !terminalStates.contains(child.run.state)) {
      child.cancel('cancelled by the parent');
    }
  }
  for (var i = 0; i < children.length; i++) {
    parent.budget.noteUsage(children[i].budget.promptTokens - spent[i].$1,
        children[i].budget.completionTokens - spent[i].$2, parent.config);
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
  for (final child in children) {
    if (terminalStates.contains(child.run.state)) parent.children.remove(child);
  }
  return [for (final (child, spec) in pairs) _entry(child, spec)];
}

Future<Object?> _spawn(ToolContext ctx, Map<String, Object?> args) async {
  final tasks = args.maps('tasks');
  final background = args.boolOr('background', false);
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
  for (final event in _spawned(ctx, ctx.commandId)) {
    known = (event.data['child_run_ids'] as List).cast<String>();
  }
  final List<Session> children;
  if (known == null) {
    children = [for (final spec in tasks) childSession(parent, spec, tasks.length)];
    parent.children.addAll(children);
    ctx.ledger!.append(ctx.run!.id, 'run_spawned', {
      'command_id': ctx.commandId,
      'background': background,
      'child_run_ids': [for (final c in children) c.run.id],
    });
    for (var i = 0; i < children.length; i++) {
      children[i].drive(tasks[i].str('task'));
    }
  } else {
    final outstanding = {for (final c in parent.children) c.run.id: c};
    children = [
      for (var i = 0; i < tasks.length; i++)
        outstanding[known[i]] ??
            childSession(parent, tasks[i], tasks.length,
                restored: ctx.ledger!.loadSnapshot(known[i])),
    ];
  }

  if (background) {
    // The loop head tends them from here: it nudges the parent when one
    // finishes, and meta.agent.join collects the results.
    return [for (final c in children) {'run_id': c.run.id, 'state': c.run.state}];
  }
  return _joinChildren(
      parent, [for (var i = 0; i < children.length; i++) (children[i], tasks[i])], ctx.resolution,
      cancel: false);
}

Future<Object?> _join(ToolContext ctx, Map<String, Object?> args) async {
  final parent = ctx.session;
  if (parent is! Session) {
    throw StateError('join requires a session context');
  }
  final pairs = _lookup(ctx, parent, args.strsOrNull('run_ids'));
  if (pairs.isEmpty) return 'No sub-agents are outstanding.';
  return _joinChildren(parent, pairs, ctx.resolution, cancel: args.boolOr('cancel', false));
}

const Map<String, CtxHandler> metaHandlers = {
  'meta.tool.find': _findTools,
  'meta.artifact.peek': _peek,
  'meta.history.search': _searchHistory,
};

const Map<String, CtxHandler> spawnHandlers = {
  'meta.agent.spawn': _spawn,
  'meta.agent.join': _join,
};
