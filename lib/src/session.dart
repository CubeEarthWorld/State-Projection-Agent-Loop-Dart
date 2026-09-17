/// The agent loop: project → decide → validate → authorize → execute →
/// record → continue/wait/complete.
///
/// [Session] is the conversation container; [Run] (`session.run`) is the
/// unit of resumable execution it drives. Everything the model sees each
/// turn is re-projected from the Event Ledger with fidelity-graded
/// compression — there is no separately maintained conversation list. The
/// ledger IS the truth; the projection is a disposable window over it.
library;

import 'dart:collection';
import 'dart:io';

import 'artifacts.dart';
import 'builtin/builtin.dart' show defaultBuiltins, installBuiltins;
import 'checklists.dart';
import 'compaction.dart';
import 'config.dart';
import 'context.dart';
import 'discovery.dart';
import 'embeddings.dart';
import 'events.dart';
import 'ids.dart';
import 'json_schema.dart' show miniValidate;
import 'llm.dart';
import 'messages.dart';
import 'policy.dart';
import 'projection.dart';
import 'registry.dart';
import 'run.dart';
import 'serialization.dart';
import 'runtime.dart';
import 'tokens.dart';
import 'working_state.dart';


class ConcurrencyError implements Exception {
  ConcurrencyError(this.message);
  final String message;

  @override
  String toString() => 'ConcurrencyError: $message';
}

EventLedger _makeLedger(Config config) {
  if (config.persistence.ledgerDirectory != null) {
    return JsonlLedger(config.persistence.ledgerDirectory!);
  }
  return InMemoryLedger();
}

class _Continue {
  const _Continue();
}

const _continue = _Continue();

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
  })  : config = config ?? Config(),
        registry = registry ?? Registry() {
    installBuiltins(this.registry, builtins);

    sessionId = newId('session');
    final base = ledger ?? _makeLedger(this.config);
    this.ledger = onEvent == null ? base : ObservedLedger(base, onEvent);
    run = Run(newId('run'), sessionId, this.ledger);

    this.policy = policy ?? _defaultPolicy();

    final artifactsDir = this.config.artifacts.directory;
    store = ArtifactStore(run.id, directory: artifactsDir != null ? Directory(artifactsDir) : null);
    search = ToolSearch(this.registry, embedder: embedder, vector: this.config.discovery.vector);

    _kernelText = kernel;
    final sectionList = sections ??
        buildDefaultSections(
          this.config.projection.sections,
          kernelText: kernel,
        );
    projection = Projection(sectionList, windowTokens: this.config.projection.windowTokens);
    runtime = Runtime(this.registry, this.config);

    // Typed fields go through the same parser snapshots use, so a seeded
    // `decisions` becomes RecordedDecision objects rather than raw maps that
    // blow up on the next toDict(). Anything else is app-specific state and
    // lands in `extra`, the documented escape hatch.
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

    // Recently used non-pinned tools (an LRU). Pinned capabilities are added
    // by _apiTools straight from the registry, so they are never tracked here
    // and can never be evicted.
    _active = LinkedHashSet<String>();
    this.ledger.append(
        run.id, 'run_state_changed', {'from': 'RUNNING', 'to': 'RUNNING', 'reason': 'created'});
    _snapshot();
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
  late String _kernelText;
  late final Projection projection;
  late final Runtime runtime;
  late WorkingState workingState;
  ChecklistStore get checklists => workingState.checklists;
  late BudgetState budget;
  late final LinkedHashSet<String> _active;
  bool _interrupted = false;
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
  List<Message> get conversation {
    final msgs = <Message>[];
    for (final event in ledger.iterRun(run.id)) {
      final msgDict = eventToMessage(event);
      if (msgDict == null) continue;
      msgs.add(Message(
        role: msgDict['role'] as String,
        content: msgDict['content'] ?? '',
        toolCallId: msgDict['tool_call_id'] as String?,
        name: msgDict['name'] as String?,
        toolCalls: [
          for (final tc in (msgDict['tool_calls'] as List? ?? []))
            ToolCall(
              name: (tc as Map)['name']?.toString() ?? '',
              arguments: (tc['arguments'] as Map?)?.cast<String, Object?>() ?? {},
              id: tc['id']?.toString() ?? '',
            ),
        ],
      ));
    }
    return msgs;
  }

  Future<Object?> send(String text) async {
    return _guarded(() async {
      ledger.append(run.id, 'user_input', {'text': text});
      _checkpoint();
      return await _loop();
    });
  }

  Future<Object?> runJob(String task) async {
    return _guarded(() async {
      ledger.append(run.id, 'user_input', {'text': task});
      _checkpoint();
      return await _loop();
    });
  }

  void interrupt() {
    _interrupted = true;
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
      kernel: _kernelText,
      config: Config.fromMap(deepCopy(config.toMap())),
      registry: registry,
      embedder: search.embedder,
      spawnLlmFactory: spawnLlmFactory,
      policy: policy,
    );
    newSession.workingState = WorkingState.fromDict(deepCopy(workingState.toDict()));
    final renderable = ledger
        .iterRun(run.id)
        .where((e) => renderableTypes.contains(e.type))
        .toList();
    final cut = atMessage ?? renderable.length;
    for (final event in renderable.take(cut)) {
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
  /// them; [upToTurn] stops the scan at the cut point.
  List<String> _irreversibleEffects({int? upToTurn}) {
    final notices = <String>[];
    var userCount = 0;
    for (final event in ledger.iterRun(run.id)) {
      if (event.type == 'user_input' && upToTurn != null) {
        if (userCount >= upToTurn) break;
        userCount++;
      }
      if (event.type != 'command_completed') continue;
      final command = run.commands[event.data['command_id']];
      if (command == null) continue;
      final capabilityName = command.capabilityName.contains('@')
          ? command.capabilityName.substring(0, command.capabilityName.lastIndexOf('@'))
          : command.capabilityName;
      final capability = registry.get(capabilityName);
      if (capability != null && capability.effects.any((e) => e.kind == 'external')) {
        notices.add(
            '${capability.qualifiedName} (command ${command.id}) already ran and cannot be undone');
      }
    }
    return notices;
  }

  // -- process-restart resume ------------------------------------------------

  static Session resumeFromLedger(
    LLMAdapter llm,
    String runId, {
    Config? config,
    Registry? registry,
    PolicyEngine? policy,
    EmbeddingBackend? embedder,
    SpawnLlmFactory? spawnLlmFactory,
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

    final session = Session(
      llm,
      config: cfg,
      registry: registry,
      policy: policy,
      embedder: embedder,
      spawnLlmFactory: spawnLlmFactory,
      ledger: ledger,
      onEvent: onEvent,
    );
    session.run = Run.fromSnapshotState(runId, session.ledger, snapshot.state);
    session.sessionId = (snapshot.state['session_id'] as String?) ?? session.sessionId;
    session.workingState =
        WorkingState.fromDict((snapshot.state['working_state'] as Map?)?.cast<String, Object?>() ?? {});
    for (final event in ledger.iterRun(runId, after: snapshot.sequence)) {
      if (event.type == 'checklists_changed') {
        session.workingState.checklists = ChecklistStore.fromDict(event.data['checklists']);
      }
    }
    final budgetData = (snapshot.state['budget'] as Map?)?.cast<String, Object?>() ?? {};
    session.budget = BudgetState(
      steps: (budgetData['steps'] as num?)?.toInt() ?? 0,
      promptTokens: (budgetData['prompt_tokens'] as num?)?.toInt() ?? 0,
      completionTokens: (budgetData['completion_tokens'] as num?)?.toInt() ?? 0,
      cost: (budgetData['cost'] as num?)?.toDouble() ?? 0.0,
    );
    session.store = ArtifactStore(
      session.run.id,
      directory: cfg.artifacts.directory != null ? Directory(cfg.artifacts.directory!) : null,
    );
    return session;
  }

  void _snapshot() {
    final state = <String, Object?>{
      'session_id': sessionId,
      'working_state': workingState.toDict(),
      'budget': {
        'steps': budget.steps,
        'prompt_tokens': budget.promptTokens,
        'completion_tokens': budget.completionTokens,
        'cost': budget.cost,
      },
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
        final text = _lastAssistantText();
        return text.isNotEmpty ? text : '[interrupted]';
      }

      final (budgetStop, budgetValue) = _enforceBudget();
      if (budgetStop) {
        _snapshot();
        return budgetValue;
      }

      final ctx = _context();
      final apiTools = _apiTools(ctx);
      ctx.dedupeCandidateCards = config.projection.dedupeCandidateCardsAgainstSchemas;
      final reserved =
          config.projection.reservedOutputTokens + config.projection.providerOverheadTokens;
      var messages = projection.render(ctx, apiTools: apiTools, reservedTokens: reserved);
      if (await _fold(ctx, messages)) {
        messages = projection.render(ctx, apiTools: apiTools, reservedTokens: reserved);
      }
      ledger.append(run.id, 'projection_compiled', {
        'tokens': estimateTokens(messages),
        'messages': messages.length,
        'candidates': [for (final s in ctx.candidates) s.tool.name],
      });

      final decision = extractFinish(await llm.complete(messages, ctx.apiTools.isNotEmpty ? ctx.apiTools : null));
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
      budget.steps += 1;
      ledger.append(run.id, 'model_response', {
        'text': decision.text,
        'finish': decision.finish,
        'calls': [for (final c in resolvedCalls) {'name': c.name, 'arguments': c.arguments, 'id': c.id}],
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
        final schema = config.resultSchema;
        final error = schema == null ? null : miniValidate(schema, decision.result);
        if (error != null) {
          ledger.append(run.id, 'decision_validated', {'ok': false, 'reason': 'result_schema: $error'});
          _notice('[runtime] finish(result) rejected: $error. Fix the result and call finish again.');
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

  /// Compaction: when the prompt exceeds `compaction.triggerRatio` of the
  /// window, fold history older than the full-fidelity window into the working
  /// state with one model call. Returns true when the projection must be
  /// re-rendered.
  Future<bool> _fold(TurnContext ctx, List<Message> messages) async {
    final ratio = config.compaction.triggerRatio;
    if (ratio <= 0) return false;
    final used = estimateTokens(messages) + projection.schemaTokens(ctx.apiTools);
    if (used <= ratio * config.projection.windowTokens) return false;
    final events = ledger.iterRun(run.id).where((e) => renderableTypes.contains(e.type)).toList();
    final keep = config.compression.fullWindow;
    final foldable = [
      for (final e in events.take(events.length > keep ? events.length - keep : 0))
        if (e.sequence > workingState.foldedSequence) e,
    ];
    if (foldable.isEmpty) return false;
    final transcript = [
      for (final e in foldable)
        if (eventToMessage(e) case final m?) '${m['role']}: ${m['content']}',
    ].join('\n');
    final prompt = [
      Message(role: kSystem, content: foldInstructions),
      Message(role: kUser, content: transcript),
    ];
    final decision = await llm.complete(prompt);
    budget.steps += 1;
    budget.noteDecision(decision, prompt, const [], config);
    final delta = parseFoldReply(decision.text);
    final before = workingState.toDict();
    final error = delta == null ? 'reply was not a JSON object' : applyFoldDelta(workingState, delta);
    if (error != null) {
      _notice('[runtime] compaction skipped: $error');
      return false;
    }
    workingState.foldedSequence = foldable.last.sequence;
    ledger.append(run.id, 'state_folded', {
      'through_sequence': workingState.foldedSequence,
      'before': before,
      'delta': delta,
    });
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
        _observe(result.call.id, result.call.name, result.observation);
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
      _notice('[runtime] Budget exceeded: $reason. Wrap up now with a final answer$hint.');
      return (false, null);
    }
    if (config.mode == 'job') {
      if (!['COMPLETED', 'FAILED', 'CANCELLED'].contains(run.state)) {
        run.fail('budget_stop: $reason');
      }
      return (true, run.result ?? _lastAssistantText());
    }
    final text = _lastAssistantText();
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
      );

  List<ScoredTool> _layer2Candidates() {
    final query = _candidateQueries().where((q) => q.isNotEmpty).join('\n');
    if (query.isEmpty) return [];
    final pinnedNames = registry.pinned().map((c) => c.name).toSet();
    return search.search(query, k: config.discovery.k, layer: 2, exclude: pinnedNames);
  }

  List<String> _candidateQueries() {
    final parts = <String>[];
    for (final source in config.discovery.querySources) {
      if (source == 'last_user_message') {
        parts.add(_lastText(kUser));
      } else if (source == 'last_model_thought') {
        parts.add(_lastText(kAssistant));
      } else if (source == 'goal_if_exists') {
        parts.add(workingState.goal);
      }
    }
    return parts;
  }

  String _lastText(String role) {
    final events = ledger
        .iterRun(run.id)
        .where((e) => renderableTypes.contains(e.type))
        .toList();
    for (final event in events.reversed) {
      final msgDict = eventToMessage(event);
      if (msgDict != null && msgDict['role'] == role) {
        // A part list is not a search query; keep looking further back
        // rather than stringifying it.
        final content = msgDict['content'];
        if (content is String && content.isNotEmpty) return content;
      }
    }
    return '';
  }

  String _lastAssistantText() => _lastText(kAssistant);

  List<Map<String, Object?>> _apiTools(TurnContext ctx) {
    final names = <String>{};
    for (final capability in registry.pinned()) {
      names.add(capability.name);
    }
    for (final scored in ctx.candidates) {
      names.add(scored.tool.name);
    }
    names.addAll(_active);
    final schemas = [
      for (final n in names)
        if (registry.contains(n)) registry.get(n)!.apiSchema(),
    ];
    if (config.mode == 'job') {
      schemas.add(finishSchema);
    }
    return schemas;
  }

  void _activate(String name) {
    _active.remove(name);
    _active.add(name);
    while (_active.length > config.discovery.activeTools) {
      _active.remove(_active.first);
    }
  }

  /// Mark tools recently used so their schemas are sent natively next turn.
  void activate(Iterable<String> names) {
    for (final name in names) {
      _activate(name);
    }
  }

  Object? _handleTextOnly(Decision decision) {
    if (config.mode == 'chat') return decision.text;
    _idleTurns += 1;
    if (_idleTurns > config.limits.maxIdleTurns) {
      ledger.append(run.id, 'run_state_changed',
          {'from': run.state, 'to': run.state, 'reason': 'gave_up_text_only'});
      return decision.text;
    }
    _notice('[runtime] No tool was called. Continue working with tools, '
        'or call finish(result) to finish the job.');
    return _continue;
  }

  void _observe(String callId, String name, String text) {
    ledger.append(run.id, 'observation', {'call_id': callId, 'name': name, 'text': text});
  }

  void _notice(String text) {
    ledger.append(run.id, 'notice', {'text': text});
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
  List<String> rewind({required int toTurn}) {
    final irreversible = _irreversibleEffects(upToTurn: toTurn);
    // One pass: keep renderable events before the toTurn-th user input, and
    // restore the working state from the checkpoint written right after it.
    final keptRenderable = <Event>[];
    var restoredWs = WorkingState();
    var userCount = 0;
    var cut = false;
    for (final event in ledger.iterRun(run.id)) {
      if (!cut && event.type == 'user_input' && userCount++ == toTurn) cut = true;
      if (!cut) {
        if (renderableTypes.contains(event.type)) keptRenderable.add(event);
      } else if (event.type == 'checkpoint') {
        restoredWs = WorkingState.fromDict(
            (event.data['working_state'] as Map?)?.cast<String, Object?>() ?? {});
        break;
      }
    }

    final oldRunId = run.id;
    ledger.append(oldRunId, 'rewound', {'to_turn': toTurn, 'kept_messages': keptRenderable.length});
    if (!['COMPLETED', 'FAILED', 'CANCELLED'].contains(run.state)) {
      run.cancel('rewound to turn $toTurn');
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
