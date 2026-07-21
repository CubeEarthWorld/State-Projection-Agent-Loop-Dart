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
import 'builtin/meta.dart' show ensureMetaTools;
import 'capability.dart';
import 'config.dart';
import 'discovery.dart';
import 'embeddings.dart';
import 'events.dart';
import 'ids.dart';
import 'llm.dart';
import 'messages.dart';
import 'policy.dart';
import 'projection.dart';
import 'registry.dart';
import 'run.dart';
import 'runtime.dart';
import 'tokens.dart';
import 'working_state.dart';

const int _activeToolCap = 48;

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
    Map<String, Section>? extraSections,
    this.spawnLlmFactory,
    EventLedger? ledger,
  })  : config = config ?? Config(),
        registry = registry ?? Registry() {
    ensureMetaTools(this.registry);

    sessionId = newId('session');
    this.ledger = ledger ?? _makeLedger(this.config);
    run = Run(newId('run'), sessionId, this.ledger);

    this.policy = policy ?? _defaultPolicy();

    final artifactsDir = this.config.artifacts.directory;
    store = ArtifactStore(run.id, directory: artifactsDir != null ? Directory(artifactsDir) : null);
    search = ToolSearch(this.registry, embedder: embedder, vector: this.config.discovery.vector);

    _kernelText = kernel;
    final pinned = this.registry.pinned();
    final sectionList = sections ??
        buildDefaultSections(
          this.config.projection.sections,
          kernelText: kernel,
          pinned: pinned,
          extra: extraSections,
        );
    projection = Projection(sectionList, windowTokens: this.config.projection.windowTokens);
    runtime = Runtime(this.registry, store, this.config);
    runtime.seenSpecs.addAll(pinned.map((c) => c.name));

    workingState = WorkingState();
    for (final entry in (seed ?? {}).entries) {
      _seedWorkingState(entry.key, entry.value);
    }

    budget = BudgetState();

    _active = LinkedHashSet<String>.from(pinned.map((c) => c.name));
    this.ledger.append(
        run.id, 'run_state_changed', {'from': 'RUNNING', 'to': 'RUNNING', 'reason': 'created'});
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
  late BudgetState budget;
  late final LinkedHashSet<String> _active;
  bool _interrupted = false;
  int _idleTurns = 0;
  bool _budgetGraceUsed = false;
  bool _locked = false;

  void _seedWorkingState(String key, Object? value) {
    switch (key) {
      case 'goal':
        workingState.goal = value?.toString() ?? '';
      case 'acceptance_criteria':
        workingState.acceptanceCriteria
          ..clear()
          ..addAll(((value as List?) ?? []).cast<String>());
      case 'constraints':
        workingState.constraints
          ..clear()
          ..addAll(((value as List?) ?? []).cast<String>());
      case 'confirmed_facts':
        workingState.confirmedFacts
          ..clear()
          ..addAll(((value as List?) ?? []).cast<String>());
      case 'open_questions':
        workingState.openQuestions = ((value as List?) ?? []).cast<String>();
      case 'next_actions':
        workingState.nextActions = ((value as List?) ?? []).cast<String>();
      case 'artifact_refs':
        workingState.artifactRefs
          ..clear()
          ..addAll(((value as List?) ?? []).cast<String>());
      default:
        workingState.extra[key] = value;
    }
  }

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

  Future<Object?> resume() async {
    return _guarded(() async {
      if (run.state != 'RUNNING') {
        throw RunStateError('Run ${run.id} is not resumable from state ${run.state}');
      }
      final turn = _newTurn();
      final batch = await runtime.resumePending(run, _toolContext(), policy, turn);
      _applyBatch(batch);
      _snapshot();
      if (batch.halted) return run.pendingApproval;
      return await _loop();
    });
  }

  // -- direct invocation ---------------------------------------------------

  Future<Object?> invoke(String capabilityName, [Map<String, Object?>? arguments]) async {
    return _guarded(() async {
      final turn = _newTurn();
      final call = ToolCall(name: capabilityName, arguments: arguments ?? {});
      final batch = await runtime.execute([call], turn, _toolContext(), run, policy);
      _applyBatch(batch, record: false);
      _snapshot();
      if (batch.halted) return run.pendingApproval;
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
      config: Config.fromMap(config.toMap()),
      registry: registry,
      embedder: search.embedder,
      spawnLlmFactory: spawnLlmFactory,
      policy: policy,
    );
    newSession.workingState = WorkingState.fromDict(workingState.toDict());
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
    return (newSession, _irreversibleEffects());
  }

  List<String> _irreversibleEffects() {
    final notices = <String>[];
    for (final event in ledger.iterRun(run.id)) {
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
    );
    session.run = Run.fromSnapshotState(runId, ledger, snapshot.state);
    session.sessionId = (snapshot.state['session_id'] as String?) ?? session.sessionId;
    session.workingState =
        WorkingState.fromDict((snapshot.state['working_state'] as Map?)?.cast<String, Object?>() ?? {});
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

      final turn = _newTurn();
      final apiTools = _apiTools(turn);
      turn.dedupeCandidateCards = config.projection.dedupeCandidateCardsAgainstSchemas;
      final reserved =
          config.projection.reservedOutputTokens + config.projection.providerOverheadTokens;
      final messages = projection.render(turn, apiTools: apiTools, reservedTokens: reserved);
      ledger.append(run.id, 'projection_compiled', {
        'tokens': estimateTokens(messages),
        'messages': messages.length,
        'candidates': [for (final s in turn.candidates) s.tool.name],
      });

      final decision = extractFinish(await llm.complete(messages, apiTools.isNotEmpty ? apiTools : null));
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
      _noteUsage(decision, messages);
      ledger.append(run.id, 'model_response', {
        'text': decision.text.length > 2000 ? decision.text.substring(0, 2000) : decision.text,
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
      final batch = await runtime.execute(resolvedCalls, turn, _toolContext(), run, policy);
      _applyBatch(batch);
      _snapshot();
      if (batch.halted) return run.pendingApproval;
    }
  }

  void _applyBatch(ExecuteBatchResult batch, {bool record = true}) {
    for (final result in batch.results) {
      if (record) {
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

  TurnContext _newTurn() {
    final turn = TurnContext(
      config: config,
      registry: registry,
      ledger: ledger,
      runId: run.id,
      workingState: workingState,
      session: this,
      store: store,
      step: budget.steps,
    );
    turn.candidates.addAll(_layer2Candidates());
    return turn;
  }

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
        final content = (msgDict['content'] ?? '').toString();
        if (content.isNotEmpty) return content;
      }
    }
    return '';
  }

  String _lastAssistantText() => _lastText(kAssistant);

  List<Map<String, Object?>> _apiTools(TurnContext turn) {
    final names = <String>{};
    for (final capability in registry.pinned()) {
      names.add(capability.name);
    }
    for (final scored in turn.candidates) {
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
    final pinnedNames = registry.pinned().map((c) => c.name).toSet();
    while (_active.length > _activeToolCap) {
      String? toRemove;
      for (final candidate in _active) {
        if (!pinnedNames.contains(candidate)) {
          toRemove = candidate;
          break;
        }
      }
      if (toRemove == null) break;
      _active.remove(toRemove);
    }
  }

  void activateTools(List<String> names) {
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
    final irreversible = _irreversibleEffectsUpTo(toTurn);
    final allEvents = ledger.iterRun(run.id).toList();
    final renderable = allEvents.where((e) => renderableTypes.contains(e.type)).toList();

    var userTurnsSeen = 0;
    var cutIndex = renderable.length;
    for (var i = 0; i < renderable.length; i++) {
      if (renderable[i].type == 'user_input') {
        if (userTurnsSeen == toTurn) {
          cutIndex = i;
          break;
        }
        userTurnsSeen++;
      }
    }
    final keptRenderable = renderable.sublist(0, cutIndex);

    var restoredWs = WorkingState();
    var userCount = 0;
    var lookingForCheckpoint = false;
    for (final event in allEvents) {
      if (event.type == 'user_input') {
        if (userCount == toTurn) lookingForCheckpoint = true;
        userCount++;
      } else if (event.type == 'checkpoint' && lookingForCheckpoint) {
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
    _active.addAll(registry.pinned().map((c) => c.name));
    runtime.seenSpecs.clear();
    runtime.seenSpecs.addAll(registry.pinned().map((c) => c.name));

    return irreversible;
  }

  List<String> _irreversibleEffectsUpTo(int toTurn) {
    final notices = <String>[];
    var userCount = 0;
    for (final event in ledger.iterRun(run.id)) {
      if (event.type == 'user_input') {
        if (userCount >= toTurn) break;
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

  void _noteUsage(Decision decision, List<Message> messages) {
    if (decision.usage != null) {
      budget.noteUsage(decision.usage!.promptTokens, decision.usage!.completionTokens, config);
    } else {
      budget.noteUsage(estimateTokens(messages), estimateTokens(decision.text), config);
    }
  }

  ToolContext _toolContext() => ToolContext(
        session: this,
        registry: registry,
        store: store,
        workingState: workingState,
        config: config,
        search: search,
        ledger: ledger,
        run: run,
      );
}
