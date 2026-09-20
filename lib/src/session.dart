/// The agent loop: project → decide → validate → authorize → execute →
/// record → continue/wait/complete.
///
/// [Session] is the conversation container; [Run] (`session.run`) is the
/// unit of resumable execution it drives. Everything the model sees each
/// turn is re-projected from the Event Ledger with fidelity-graded
/// compression — there is no separately maintained conversation list. The
/// ledger IS the truth; the projection is a disposable window over it.
library;

import 'dart:async';
import 'dart:collection';

import 'artifacts.dart';
import 'builtin/builtin.dart' show defaultBuiltins, installBuiltins;
import 'builtin/meta.dart' show childSession;
import 'checklists.dart';
import 'compaction.dart';
import 'config.dart';
import 'context.dart';
import 'discovery.dart';
import 'embeddings.dart';
import 'events.dart';
import 'ids.dart';
import 'json_schema.dart' show validateValue;
import 'llm.dart';
import 'memory.dart';
import 'messages.dart';
import 'policy.dart';
import 'projection.dart';
import 'registry.dart';
import 'run.dart';
import 'serialization.dart';
import 'runtime.dart';
import 'working_state.dart';


class ConcurrencyError implements Exception {
  ConcurrencyError(this.message);
  final String message;

  @override
  String toString() => 'ConcurrencyError: $message';
}

/// Why a run ended, from the last transition it recorded.
String _lastReason(Session session) {
  var reason = '';
  for (final event in session.ledger.iterRun(session.run.id)) {
    if (event.type == 'run_state_changed') reason = '${event.data['reason'] ?? ''}';
  }
  return reason;
}

EventLedger _makeLedger(Config config) {
  if (config.persistence.ledgerDirectory != null) {
    return JsonlLedger(config.persistence.ledgerDirectory!);
  }
  return InMemoryLedger();
}

const _continue = Object(); // sentinel: the loop should keep going

typedef SpawnLlmFactory = LLMAdapter Function(String? model);

class Session {
  Session(
    this.llm, {
    String kernel = '',
    Config? config,
    Registry? registry,
    Map<String, Object?>? seed,
    PolicyEngine? policy,
    EmbeddingBackend? embedder,
    List<Section>? sections,
    this.spawnLlmFactory,
    EventLedger? ledger,
    Iterable<String> builtins = defaultBuiltins,
    void Function(Event event)? onEvent,
    this.onDelta,
    Hooks hooks = const Hooks(),
    MemoryStore? memory,
    Snapshot? restored,
  })  : config = config ?? Config(),
        registry = registry ?? Registry() {
    installBuiltins(this.registry, builtins);

    // `restored` is resumeFromLedger's way in: the session continues that
    // snapshot's run instead of starting one.
    final base = ledger ?? _makeLedger(this.config);
    this.ledger = onEvent == null ? base : ObservedLedger(base, onEvent);
    if (restored == null) {
      sessionId = newId('session');
      run = Run(newId('run'), sessionId, this.ledger);
    } else {
      run = Run.fromSnapshotState(restored.runId, this.ledger, restored.state);
      sessionId = run.sessionId;
    }

    this.policy = policy ?? _defaultPolicy();
    // Cross-session notes (the `memory` pack). Beside the ledger when the
    // session persists, in process memory otherwise.
    final ledgerDir = this.config.persistence.ledgerDirectory;
    this.memory = memory ?? JsonlMemoryStore(ledgerDir == null ? null : '$ledgerDir/memory.jsonl');

    final artifactsDir = this.config.artifacts.directory;
    store = ArtifactStore(run.id, directory: artifactsDir);
    search = ToolSearch(this.registry, embedder: embedder, vector: this.config.discovery.vector);

    // What branch() hands to the new session: code, not state, so it is
    // passed on rather than rebuilt from defaults.
    _branchArgs = (
      kernel: kernel,
      sections: sections,
      builtins: builtins,
      onEvent: onEvent,
      hooks: hooks,
      onDelta: onDelta,
    );
    final sectionList = sections ??
        buildDefaultSections(
          this.config.projection.sections,
          kernelText: kernel,
        );
    projection = Projection(sectionList, windowTokens: this.config.projection.windowTokens);
    runtime = Runtime(this.registry, this.config, hooks: hooks);

    if (restored == null) {
      // Typed fields go through the same parser snapshots use, so a seeded
      // `decisions` becomes RecordedDecision objects rather than raw maps
      // that blow up on the next toDict(). Anything else is app-specific
      // state and lands in `extra`, the documented escape hatch.
      final seedMap = seed ?? const <String, Object?>{};
      workingState = WorkingState.fromDict({
        for (final e in seedMap.entries)
          if (workingStateFields.contains(e.key)) e.key: e.value,
      });
      workingState.extra.addAll({
        for (final e in seedMap.entries)
          if (!workingStateFields.contains(e.key)) e.key: e.value,
      });
      budget = BudgetState();
    } else {
      workingState = WorkingState.fromDict(
          (restored.state['working_state'] as Map?)?.cast<String, Object?>() ?? {});
      // Plans changed after the snapshot are in the ledger.
      for (final event in this.ledger.iterRun(run.id, after: restored.sequence)) {
        if (event.type == 'checklists_changed') {
          workingState.checklists = ChecklistStore.fromDict(event.data['checklists']);
        }
      }
      budget = BudgetState.fromDict(
          (restored.state['budget'] as Map?)?.cast<String, Object?>() ?? {});
    }

    // Recently used non-pinned tools (an LRU). Pinned capabilities are added
    // by _apiTools straight from the registry, so they are never tracked here
    // and can never be evicted.
    _active = LinkedHashSet<String>();
    if (restored == null) {
      this.ledger.append(
          run.id, 'run_state_changed', {'from': 'RUNNING', 'to': 'RUNNING', 'reason': 'created'});
      _snapshot();
    } else {
      _reattachBackground();
    }
  }

  final LLMAdapter llm;
  final SpawnLlmFactory? spawnLlmFactory;
  final Config config;
  final Registry registry;
  late String sessionId;
  late final EventLedger ledger;
  late Run run;
  late final PolicyEngine policy;
  late ArtifactStore store;
  late final ToolSearch search;
  late final ({
    String kernel,
    List<Section>? sections,
    Iterable<String> builtins,
    void Function(Event)? onEvent,
    Hooks hooks,
    void Function(String, String)? onDelta,
  }) _branchArgs;
  late final MemoryStore memory;
  late final Projection projection;
  late final Runtime runtime;
  // `onDelta(source, text)` sees assistant text as it streams in (source
  // "model") and tool progress from ctx.emit (source "tool"). Delivery only:
  // the ledger still records whole turns.
  final void Function(String source, String text)? onDelta;
  Completer<void>? _inflight;
  late WorkingState workingState;
  ChecklistStore get checklists => workingState.checklists;
  late BudgetState budget;
  late final LinkedHashSet<String> _active;
  bool _interrupted = false;

  /// This run's sub-agents, until they are collected. A blocking spawn adds
  /// and removes them around its own command; a background one leaves them
  /// here for the loop head to tend.
  final List<Session> children = [];

  /// The future driving this session unattended (a background sub-agent).
  /// null means nobody is running its loop right now.
  Future<void>? driver;
  int _idleTurns = 0;
  bool _budgetGraceUsed = false;
  bool _locked = false;

  static PolicyEngine _defaultPolicy() {
    final engine = PolicyEngine(defaultDecision: 'require_approval');
    engine.applyPreset('auto_safe');
    return engine;
  }

  // -- public API -------------------------------------------------------------

  /// Derived view of renderable ledger events as Messages. Read-only;
  /// the ledger is the source of truth, this is a convenience accessor.
  List<Message> get conversation =>
      [for (final (_, message) in renderable(ledger, run.id)) message];

  /// [content] is a String, or a list of content parts (`{"type": "text",
  /// ...}`, `{"type": "image_url", ...}`) passed through to the adapter as
  /// the user message.
  Future<Object?> send(Object content) async {
    return _guarded(() async {
      ledger.append(run.id, 'user_input', {'text': content});
      _checkpoint();
      return await _loop();
    });
  }

  /// A job is started the way a chat turn is; `config.mode` is what makes it
  /// run until finish(result).
  Future<Object?> runJob(Object task) => send(task);

  /// Stop after the current step. A model call still waiting for the
  /// provider is abandoned outright; a tool that is already running
  /// finishes, so its outcome is recorded. Running sub-agents are
  /// interrupted too, and end up `CANCELLED` in the ledger.
  void interrupt() {
    _interrupted = true;
    final inflight = _inflight;
    if (inflight != null && !inflight.isCompleted) inflight.complete();
    for (final child in [...children]) {
      child.interrupt();
    }
  }

  /// Stop every sub-agent at its next step boundary and wait for it.
  ///
  /// A parked child is `RUNNING` in the ledger with a snapshot at the
  /// boundary it stopped at, so the next turn - or the next process - picks
  /// it up. A host calls this before it exits.
  Future<void> park() async {
    for (final child in [...children]) {
      child.interrupt();
    }
    for (final child in [...children]) {
      if (child.driver != null) {
        await child.driver!.catchError((Object _) {});
      }
      await child.park();
      // The interrupt was ours and it has done its job. Leaving the flag set
      // would eat the child's first step when it resumes.
      child._interrupted = false;
    }
  }

  /// Run this session's loop unattended: the one way a sub-agent moves
  /// without its parent awaiting it. Fresh with [task], otherwise a resume.
  /// A no-op unless the run is RUNNING and nobody drives it.
  void drive([Object? task]) {
    if (driver != null || run.state != 'RUNNING') return;
    driver = () async {
      try {
        await (task != null ? runJob(task) : resume());
      } catch (exc) {
        // A driver must not lose its error.
        if (!terminalStates.contains(run.state)) cancel('$exc');
      } finally {
        driver = null;
      }
    }();
  }

  void _cancelChildren(String reason) {
    for (final child in [...children]) {
      child.interrupt();
      if (!terminalStates.contains(child.run.state)) child.cancel(reason);
    }
    children.clear();
  }

  /// Fail this run. Never leaves a sub-agent running behind it.
  void _fail(String reason) {
    _cancelChildren(reason);
    run.fail(reason);
  }

  /// Collect and re-drive sub-agents, once per step.
  ///
  /// The loop head is the only safe place: it is always after a batch has
  /// been applied and snapshotted and before the next projection, so a
  /// notice can never land between an assistant's tool calls and their
  /// results - a message sequence no provider accepts.
  void _tendChildren() {
    for (final child in [...children]) {
      if (child.run.state == 'WAITING_FOR_USER') {
        child.cancel('a sub-agent has no user to ask');
      }
      if (terminalStates.contains(child.run.state)) {
        budget.noteUsage(child.budget.promptTokens, child.budget.completionTokens, config);
        final detail = child.run.state == 'COMPLETED' ? '' : ' (${_lastReason(child)})';
        notice(
          '[runtime] sub-agent ${child.run.id} finished: ${child.run.state}$detail. '
          'Call meta.agent.join(run_ids=["${child.run.id}"]) for its result.',
          data: {'child_run_id': child.run.id},
        );
        children.remove(child);
      } else {
        child.drive();
      }
    }
  }

  /// After a restart, pick background sub-agents back up out of the ledger.
  /// One already announced by a notice was collected; the rest are this
  /// run's again, and the next loop head drives or reports them.
  void _reattachBackground() {
    final announced = <String>{
      for (final e in ledger.iterRun(run.id))
        if (e.type == 'notice' && e.data['child_run_id'] != null) e.data['child_run_id'] as String,
    };
    for (final event in ledger.iterRun(run.id)) {
      if (event.type != 'run_spawned' || event.data['background'] != true) continue;
      final command = run.commands[event.data['command_id']];
      final specs = (command?.arguments['tasks'] as List?) ?? const [];
      final ids = event.data['child_run_ids'] as List;
      for (var i = 0; i < ids.length && i < specs.length; i++) {
        final snapshot = ledger.loadSnapshot(ids[i] as String);
        if (announced.contains(ids[i]) || snapshot == null) continue;
        children.add(childSession(this, (specs[i] as Map).cast<String, Object?>(), 1,
            restored: snapshot));
      }
    }
  }

  /// End this run for good. For abandoning a run parked on an approval or a
  /// question — [interrupt] only stops a loop that is moving.
  void cancel([String reason = 'cancelled']) {
    _cancelChildren(reason);
    run.cancel(reason);
    _snapshot();
  }

  /// Put out-of-band text into the run's context.
  ///
  /// For what the host did outside the loop and the model must still know
  /// about: a command the user typed that ran locally, a skill loaded on
  /// demand (`session.notice(await session.invoke('skill.foo.load'))`), a
  /// file that was attached. It renders as a system message, costs no turn
  /// and calls no model — what the *user* said goes through [send].
  void notice(String text, {Map<String, Object?> data = const {}}) {
    ledger.append(run.id, 'notice', {'text': text, ...data});
  }

  void addSection(Section section, {String before = 'candidates'}) {
    projection.insertBefore(before, section);
  }

  // -- approval lifecycle -------------------------------------------------

  ApprovalRequest resolveApproval(String decision) {
    return run.resolveApproval(decision, currentPolicyRevision: policy.revision);
  }

  /// Answer the question the model asked through `meta.user.ask`; the run is
  /// `RUNNING` again and continues with [resume].
  PendingQuestion answer(String text) {
    final question = run.answer(text);
    _observe(question.callId, 'meta.user.ask', text);
    _snapshot();
    return question;
  }

  Future<Object?> resume() async {
    return _guarded(() async {
      if (run.state != 'RUNNING') {
        throw RunStateError('Run ${run.id} is not resumable from state ${run.state}');
      }
      final batch = await runtime.resumePending(run, _context(), policy);
      _applyBatch(batch);
      _snapshot();
      if (batch.halted) return _pending;
      return await _loop();
    });
  }

  Object? get _pending => run.pendingApproval ?? run.pendingQuestion;

  // -- direct invocation ---------------------------------------------------

  Future<Object?> invoke(String capabilityName, [Map<String, Object?>? arguments]) async {
    return _guarded(() async {
      final call = ToolCall(name: capabilityName, arguments: arguments ?? {});
      final batch = await runtime.execute([call], _context(), run, policy);
      _applyBatch(batch, record: false);
      _snapshot();
      if (batch.halted) return _pending;
      final result = batch.results[0];
      if (!result.ok) {
        throw StateError(result.observation.isNotEmpty
            ? result.observation
            : (result.error ?? 'invoke failed'));
      }
      return result.value;
    });
  }

  // -- branching -------------------------------------------------------------

  (Session, List<String>) branch({int? atMessage}) {
    final newSession = Session(
      llm,
      kernel: _branchArgs.kernel,
      sections: _branchArgs.sections,
      builtins: _branchArgs.builtins,
      onEvent: _branchArgs.onEvent,
      hooks: _branchArgs.hooks,
      onDelta: _branchArgs.onDelta,
      memory: memory,
      config: config.clone(),
      registry: registry,
      embedder: search.embedder,
      spawnLlmFactory: spawnLlmFactory,
      policy: policy,
    );
    newSession.workingState = WorkingState.fromDict(deepCopy(workingState.toDict()));
    final events = [for (final (event, _) in renderable(ledger, run.id)) event];
    final cut = atMessage ?? events.length;
    for (final event in events.take(cut)) {
      newSession.ledger.append(newSession.run.id, event.type, Map.of(event.data));
    }
    newSession.ledger.append(newSession.run.id, 'branch_created', {
      'parent_run_id': run.id,
      'parent_session_id': sessionId,
      'at_message': cut,
    });
    newSession._snapshot();
    return (newSession, _irreversibleEffects());
  }

  /// External effects this run already committed — a sent email, a pushed
  /// commit. Neither branching nor rewinding can undo them, so both report
  /// them ([rewind] collects its own, up to the cut point).
  List<String> _irreversibleEffects() => [
        for (final event in ledger.iterRun(run.id))
          if (_effectNotice(event) case final effect?) effect,
      ];

  /// The note for one already-committed external effect, or null when the
  /// event is not one.
  String? _effectNotice(Event event) {
    if (event.type != 'command_completed') return null;
    final command = run.commands[event.data['command_id']];
    if (command == null) return null;
    final at = command.capabilityName.lastIndexOf('@');
    final capability = registry.get(at < 0 ? command.capabilityName : command.capabilityName.substring(0, at));
    // plannedEffects, not effects: a capability that declared none is
    // treated as external everywhere else (policy, runtime), and it is
    // exactly the one whose handler might have done something real without
    // anyone noticing. Reading the raw list here reported it as safe to
    // rewind past.
    if (capability == null || !capability.plannedEffects.any((e) => e.kind == 'external')) {
      return null;
    }
    return '${capability.qualifiedName} (command ${command.id}) already ran and cannot be undone';
  }

  // -- process-restart resume ------------------------------------------------

  /// Continue a persisted run in a new process. Everything but [llm],
  /// [runId] and [config] is [Session]'s own argument: code, not state, so
  /// the caller passes what the first process passed.
  static Session resumeFromLedger(
    LLMAdapter llm,
    String runId, {
    Config? config,
    String kernel = '',
    Registry? registry,
    PolicyEngine? policy,
    EmbeddingBackend? embedder,
    List<Section>? sections,
    SpawnLlmFactory? spawnLlmFactory,
    Iterable<String> builtins = defaultBuiltins,
    void Function(Event event)? onEvent,
  }) {
    final cfg = config ?? Config();
    if (cfg.persistence.ledgerDirectory == null) {
      throw RunStateError('resumeFromLedger requires config.persistence.ledgerDirectory');
    }
    final ledger = JsonlLedger(cfg.persistence.ledgerDirectory!);
    final snapshot = ledger.loadSnapshot(runId);
    if (snapshot == null) {
      throw RunStateError('No snapshot found for run "$runId"; nothing to resume');
    }
    return Session(
      llm,
      kernel: kernel,
      config: cfg,
      registry: registry,
      policy: policy,
      embedder: embedder,
      sections: sections,
      spawnLlmFactory: spawnLlmFactory,
      ledger: ledger,
      builtins: builtins,
      onEvent: onEvent,
      restored: snapshot,
    );
  }

  void _snapshot() {
    final state = <String, Object?>{
      'working_state': workingState.toDict(),
      'budget': budget.toDict(),
      ...run.toSnapshotState(),
    };
    ledger.saveSnapshot(Snapshot(
      runId: run.id,
      sequence: ledger.lastSequence(run.id),
      ts: DateTime.now().millisecondsSinceEpoch / 1000.0,
      state: state,
    ));
  }

  // -- concurrency guard ---------------------------------------------

  Future<T> _guarded<T>(Future<T> Function() body) async {
    if (_locked) {
      throw ConcurrencyError(
          'Session $sessionId (run ${run.id}) already has a turn in flight; '
          'concurrent send()/runJob()/resume()/invoke() calls are not allowed on one session');
    }
    _locked = true;
    try {
      return await body();
    } finally {
      _locked = false;
    }
  }

  // -- loop -----------------------------------------------------------------

  Future<Object?> _loop() async {
    while (true) {
      if (_interrupted) {
        _interrupted = false;
        ledger.append(run.id, 'run_state_changed',
            {'from': run.state, 'to': run.state, 'reason': 'interrupted'});
        // Snapshot at the boundary we stopped at, so a parked sub-agent
        // resumes here and not from an older step.
        _snapshot();
        final text = _lastText(kAssistant);
        return text.isNotEmpty ? text : '[interrupted]';
      }

      _tendChildren();
      final (budgetStop, budgetValue) = _enforceBudget();
      if (budgetStop) {
        _snapshot();
        return budgetValue;
      }

      var (ctx, messages) = _project();
      final folded = await _fold();
      // The fold makes a model call of its own: an interrupt there stops the
      // turn here, before this one can run tools the user asked us to skip.
      if (_interrupted) continue;
      if (folded) {
        // From scratch: shrinking the first rendering consumed its candidates
        // and schemas, and the fold may have moved the goal.
        (ctx, messages) = _project();
      }
      ledger.append(run.id, 'projection_compiled', {
        'tokens': projection.lastMessageTokens,
        'messages': messages.length,
        'candidates': [for (final s in ctx.candidates) s.tool.name],
      });

      final started = Stopwatch()..start();
      final answer = await _complete(messages, ctx.apiTools.isNotEmpty ? ctx.apiTools : null);
      if (answer == null) continue; // interrupt() abandoned the call; the loop head records it
      final decision = extractFinish(answer);
      budget.noteDecision(decision, messages, ctx.apiTools, config);
      final resolvedCalls = [
        for (final call in decision.calls)
          ToolCall(
            name: registry.resolveApiName(call.name),
            arguments: call.arguments,
            id: call.id,
            rawArguments: call.rawArguments,
          ),
      ];
      ledger.append(run.id, 'model_response', {
        'text': decision.text,
        'finish': decision.finish,
        'calls': [for (final c in resolvedCalls) c.toDict()],
        'usage': decision.usage?.toDict(),
        'latency_ms': started.elapsedMilliseconds,
      });

      if (decision.finish && resolvedCalls.isNotEmpty) {
        ledger.append(run.id, 'decision_validated',
            {'ok': false, 'reason': 'finish combined with tool calls in the same decision'});
        for (final call in resolvedCalls) {
          _observe(
            call.id,
            call.name,
            'Rejected: cannot call finish(result) together with other tools in the same '
                'decision. Call finish(result) alone once you are done.',
          );
        }
        continue;
      }

      if (decision.finish) {
        // A run must never reach a terminal state with sub-agent work
        // outstanding: that is how results go missing and how "stopped"
        // sessions leave agents running. Collect whatever finished during
        // the call first, so the only thing that bounces a finish is work
        // that is genuinely unfinished.
        _tendChildren();
        if (children.isNotEmpty) {
          final running = [for (final c in children) c.run.id].join(', ');
          ledger.append(run.id, 'decision_validated',
              {'ok': false, 'reason': 'background sub-agents still running: $running'});
          notice('[runtime] finish(result) rejected: sub-agents $running are still running. '
              'Call meta.agent.join to wait for them (cancel=true to stop them), then finish.');
          continue;
        }
        final schema = config.resultSchema;
        final error = schema == null ? null : validateValue(schema, decision.result);
        if (error != null) {
          ledger.append(run.id, 'decision_validated', {'ok': false, 'reason': 'result_schema: $error'});
          notice('[runtime] finish(result) rejected: $error. Fix the result and call finish again.');
          continue;
        }
        ledger.append(run.id, 'decision_validated', {'ok': true, 'finish': true});
        if (config.mode == 'job') {
          run.complete(decision.result);
          _snapshot();
          return run.result;
        }
        return decision.result ?? decision.text;
      }

      if (resolvedCalls.isEmpty) {
        final outcome = _handleTextOnly(decision);
        if (!identical(outcome, _continue)) {
          _snapshot();
          return outcome;
        }
        continue;
      }

      _idleTurns = 0;
      ledger.append(run.id, 'decision_validated', {'ok': true, 'finish': false});
      final batch = await runtime.execute(resolvedCalls, ctx, run, policy);
      _applyBatch(batch);
      _snapshot();
      if (batch.halted) return _pending;
    }
  }

  /// One model call under `config.model`: a timeout, retries with backoff,
  /// abandonment by [interrupt] (null). Every failed attempt is a
  /// `model_call_failed` event; when the last one fails, a job run fails and
  /// the error reaches the caller.
  Future<Decision?> _complete(List<Message> messages, List<Map<String, Object?>>? tools) async {
    final cfg = config.model;
    // Only a host that observes deltas asks the adapter to stream.
    final onModelDelta = onDelta == null ? null : (String text) => onDelta!('model', text);
    for (var attempt = 1; attempt <= cfg.retries + 1; attempt++) {
      final interrupted = _inflight = Completer<void>();
      try {
        var call = llm.complete(messages, tools, onModelDelta);
        if (cfg.timeoutS != null) {
          call = call.timeout(Duration(milliseconds: (cfg.timeoutS! * 1000).round()));
        }
        final outcome = await Future.any<Object?>([call, interrupted.future]);
        if (outcome == null) return null;
        return outcome as Decision;
      } catch (e) {
        final error = e is TimeoutException ? 'timed out after ${cfg.timeoutS}s' : '${e.runtimeType}: $e';
        ledger.append(run.id, 'model_call_failed', {'attempt': attempt, 'error': error});
        if (attempt > cfg.retries) {
          if (config.mode == 'job' && !terminalStates.contains(run.state)) {
            _fail('model_error: $error');
          }
          _snapshot();
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: (cfg.backoffS * attempt * 1000).round()));
      } finally {
        _inflight = null;
      }
    }
    throw StateError('unreachable');
  }

  void _emit(String text) => onDelta?.call('tool', text);

  /// Move the history's verbatim point forward in steps: only when the
  /// verbatim tail has grown to four times `fullWindow` is it cut back to
  /// `fullWindow`. Between steps the rendering of every older message is
  /// unchanged, so the prompt prefix stays byte-identical and a provider's
  /// cache keeps hitting; a step is one deliberate rebuild.
  void _stepTiers() {
    final keep = config.compression.fullWindow;
    final history = renderable(ledger, run.id);
    final tail = history.where((h) => h.$1.sequence >= workingState.verbatimSequence).length;
    if (keep <= 0 || tail <= 4 * keep) return;
    workingState.verbatimSequence = history[history.length - keep].$1.sequence;
  }

  (TurnContext, List<Message>) _project() {
    _stepTiers();
    final ctx = _context();
    final messages = projection.render(
      ctx,
      apiTools: _apiTools(ctx),
      reservedTokens:
          config.projection.reservedOutputTokens + config.projection.providerOverheadTokens,
    );
    return (ctx, messages);
  }

  /// Compaction: when the prompt exceeds `compaction.triggerRatio` of the
  /// window, fold history older than the full-fidelity window into the working
  /// state with one model call. Returns true when the projection must be
  /// re-rendered.
  Future<bool> _fold() async {
    final ratio = config.compaction.triggerRatio;
    if (ratio <= 0) return false;
    // The ratio applies to the room the render actually has for messages
    // and schemas: the window less the reserved output. Measured against the
    // whole window it is unreachable once the reserve exceeds the slack, and
    // measured with the reserve counted it fires every turn of a small window.
    final cfg = config.projection;
    final room = cfg.windowTokens - cfg.reservedOutputTokens - cfg.providerOverheadTokens;
    final used = projection.lastMessageTokens + projection.lastSchemaTokens;
    if (used <= ratio * room) return false;
    // Fold from the ledger, never from the projection: what masking cleared
    // from the prompt is exactly what a fold must still read. The region is
    // everything before the verbatim point and after the last fold, so a
    // fold happens at most once per step of the point, when the prefix is
    // being rebuilt anyway, and always has a step's worth of messages to
    // work on. Forcing the point down to fold sooner produced a fold every
    // turn under a window the verbatim tail alone overflows, each one a
    // model call and a cache rebuild.
    final foldable = [
      for (final (e, m) in renderable(ledger, run.id))
        if (workingState.foldedSequence < e.sequence && e.sequence < workingState.verbatimSequence) (e, m),
    ];
    if (foldable.isEmpty) return false;
    final transcript = [for (final (_, m) in foldable) '${m.role}: ${m.content}'].join('\n');
    final prompt = [
      Message(role: kSystem, content: foldInstructions),
      Message(role: kUser, content: transcript),
    ];
    final decision = await _complete(prompt, null);
    if (decision == null) return false;
    budget.noteDecision(decision, prompt, const [], config);
    final delta = parseFoldReply(decision.text);
    final before = workingState.toDict();
    final error = delta == null
        ? 'reply was not a JSON object'
        : applyFoldDelta(workingState, delta, transcript: transcript);
    if (error != null) {
      notice('[runtime] compaction skipped: $error');
      return false;
    }
    workingState.foldedSequence = foldable.last.$1.sequence;
    ledger.append(run.id, 'state_folded', {
      'through_sequence': workingState.foldedSequence,
      'before': before,
      'delta': delta,
    });
    // A fold is the one place the working state changes without a tool call
    // behind it, and the event records `before` + `delta` rather than the
    // result — replaying it would need the transcript the grounding check
    // ran against. Snapshot instead, or a restart before the next one
    // silently loses everything the fold merged.
    _snapshot();
    return true;
  }

  void _applyBatch(ExecuteBatchResult batch, {bool record = true}) {
    for (final result in batch.results) {
      // A call parked on an approval has no result yet. Recording a
      // placeholder observation would either be overwritten by the real one
      // on resume (two results for one call) or stand in for a call that
      // never ran; instead the whole decision stays out of the projection
      // until it completes — see pairToolCalls.
      if (record && !waitingOutcomes.contains(result.outcome)) {
        _observe(result.call.id, result.call.name, result.observation, ok: result.ok);
      }
      if (result.ok) {
        _activate(result.call.name);
      }
    }
  }

  // -- loop helpers -----------------------------------------------------------

  (bool, Object?) _enforceBudget() {
    final reason = budget.exceeded(config);
    if (reason == null) return (false, null);
    if (!_budgetGraceUsed) {
      _budgetGraceUsed = true;
      final hint = config.mode == 'job' ? ' or call finish(result)' : '';
      notice('[runtime] Budget exceeded: $reason. Wrap up now with a final answer$hint.');
      return (false, null);
    }
    if (config.mode == 'job') {
      if (!terminalStates.contains(run.state)) {
        _fail('budget_stop: $reason');
      }
      return (true, run.result ?? _lastText(kAssistant));
    }
    final text = _lastText(kAssistant);
    return (true, text.isNotEmpty ? text : '[budget exhausted]');
  }

  TurnContext _context() => TurnContext(
        config: config,
        registry: registry,
        ledger: ledger,
        run: run,
        workingState: workingState,
        session: this,
        store: store,
        search: search,
        candidates: _layer2Candidates(),
        emit: _emit,
      );

  List<ScoredTool> _layer2Candidates() {
    final sources = <String, String Function()>{
      'last_user_message': () => _lastText(kUser),
      'last_model_thought': () => _lastText(kAssistant),
      'goal_if_exists': () => workingState.goal,
    };
    final query = [
      for (final source in config.discovery.querySources)
        if (sources[source]?.call() case final text? when text.isNotEmpty) text,
    ].join('\n');
    if (query.isEmpty) return [];
    final pinnedNames = registry.pinned().map((c) => c.name).toSet();
    return search.search(query, k: config.discovery.k, layer: 2, exclude: pinnedNames);
  }

  String _lastText(String role) {
    for (final (_, message) in renderable(ledger, run.id).reversed) {
      // A part list is not a search query; keep looking further back rather
      // than stringifying it.
      final content = message.content;
      if (message.role == role && content is String && content.isNotEmpty) return content;
    }
    return '';
  }

  List<Map<String, Object?>> _apiTools(TurnContext ctx) {
    // Ordered and deduplicated: pinned, then candidates, then the LRU.
    final names = <String>{
      for (final capability in registry.pinned()) capability.name,
      for (final scored in ctx.candidates) scored.tool.name,
      ..._active,
    };
    return [
      for (final n in names)
        if (registry.get(n) case final capability?) capability.toolSpec(),
      if (config.mode == 'job') finishSpec,
    ];
  }

  void _activate(String name) {
    _active.remove(name);
    _active.add(name);
    while (_active.length > config.discovery.activeTools) {
      _active.remove(_active.first);
    }
  }

  /// Mark tools recently used so their schemas are sent natively next turn.
  void activate(Iterable<String> names) => names.forEach(_activate);

  Object? _handleTextOnly(Decision decision) {
    if (config.mode == 'chat') return decision.text;
    _idleTurns += 1;
    if (_idleTurns > config.limits.maxIdleTurns) {
      ledger.append(run.id, 'run_state_changed',
          {'from': run.state, 'to': run.state, 'reason': 'gave_up_text_only'});
      return decision.text;
    }
    notice('[runtime] No tool was called. Continue working with tools, '
        'or call finish(result) to finish the job.');
    return _continue;
  }

  void _observe(String callId, String name, String text, {bool ok = true}) {
    ledger.append(run.id, 'observation', {'call_id': callId, 'name': name, 'text': text, 'ok': ok});
  }

  void _checkpoint() {
    ledger.append(run.id, 'checkpoint', {'working_state': workingState.toDict()});
  }

  /// Destructive rewind: cancel the current run and replace it in-place with
  /// a new run containing only events up to [toTurn] (counted in user-input
  /// turns, 0-indexed). The session continues as if everything after that
  /// turn never happened.
  ///
  /// Returns a list of irreversible external effects that already executed
  /// and cannot be undone.
  ///
  /// [toTurn] must name an existing turn: past the last one there is no
  /// checkpoint to restore from, and rewinding anyway would keep the whole
  /// history while resetting the working state to an empty one.
  List<String> rewind({required int toTurn}) {
    // One pass: the effects committed before the toTurn-th user input, the
    // renderable events to keep, and the working state from the checkpoint
    // written right after it.
    final irreversible = <String>[];
    final keptRenderable = <Event>[];
    var restoredWs = WorkingState();
    var userCount = 0;
    var cut = false;
    for (final event in ledger.iterRun(run.id)) {
      if (!cut && event.type == 'user_input' && userCount++ == toTurn) cut = true;
      if (!cut) {
        if (renderableTypes.contains(event.type)) {
          keptRenderable.add(event);
        } else if (_effectNotice(event) case final effect?) {
          irreversible.add(effect);
        }
      } else if (event.type == 'checkpoint') {
        restoredWs = WorkingState.fromDict(
            (event.data['working_state'] as Map?)?.cast<String, Object?>() ?? {});
        break;
      }
    }
    if (!cut) {
      throw ArgumentError(
          'rewind(toTurn: $toTurn) is out of range: this run has $userCount user turn(s)');
    }

    final oldRunId = run.id;
    ledger.append(oldRunId, 'rewound', {'to_turn': toTurn, 'kept_messages': keptRenderable.length});
    if (!terminalStates.contains(run.state)) {
      cancel('rewound to turn $toTurn');
    }

    run = Run(newId('run'), sessionId, ledger);
    for (final event in keptRenderable) {
      ledger.append(run.id, event.type, Map.of(event.data));
    }
    ledger.append(run.id, 'checkpoint', {'working_state': restoredWs.toDict()});

    workingState = restoredWs;
    budget = BudgetState();
    _idleTurns = 0;
    _budgetGraceUsed = false;
    _active.clear();
    runtime.reset();
    _snapshot();

    return irreversible;
  }
}
