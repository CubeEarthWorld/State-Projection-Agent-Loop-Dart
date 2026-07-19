/// The agent loop: project → decide → validate → authorize → execute →
/// record → continue/wait/complete.
///
/// [Session] is the conversation container; [Run] (`session.run`) is the
/// unit of resumable execution it drives. Everything the model sees each
/// turn is re-projected from the Event Ledger's derived state (working
/// state + conversation), never accumulated ad hoc.
///
/// Two correctness properties enforced here that a naive loop gets wrong:
///
/// * Completion (`Decision.finish`) is validated *before* any
///   side-effecting call in the same decision executes; a decision that
///   mixes the two is rejected outright, never partially honored.
/// * At most one in-flight turn per session. A second concurrent [send]/
///   [runJob] call raises [ConcurrencyError] immediately instead of
///   interleaving state.
///
/// Unlike the Python original (which exposes sync `send`/`asend` pairs
/// wrapping `asyncio.run`), this port has one async API surface — Dart has
/// no equivalent of blocking on an event loop from within one.
library;

import 'dart:collection';
import 'dart:io';

import 'artifacts.dart';
import 'builtin/meta.dart' show ensureMetaTools;
import 'capability.dart';
import 'compaction.dart';
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

/// Raised when a second turn is attempted on a session with one already in
/// flight. Sessions are single-writer by design; run concurrent
/// conversations as separate Sessions.
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

/// Sentinel: the loop should keep going.
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
    this.summarizer,
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
    runtime.seenSpecs.addAll(pinned.map((c) => c.name)); // kernel carries their specs
    compactor = Compactor(this.config, summarizer: _resolveSummarizer());

    workingState = WorkingState();
    for (final entry in (seed ?? {}).entries) {
      _seedWorkingState(entry.key, entry.value);
    }

    conversation = [];
    budget = BudgetState();

    _active = LinkedHashSet<String>.from(pinned.map((c) => c.name));
    this.ledger.append(
        run.id, 'run_state_changed', {'from': 'RUNNING', 'to': 'RUNNING', 'reason': 'created'});
  }

  final LLMAdapter llm;
  final LLMAdapter? summarizer;
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
  late final Compactor compactor;
  late WorkingState workingState;
  late List<Message> conversation;
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
    // Out-of-the-box posture: effect-free calls (state/meta tools) and
    // workspace reads run automatically; everything else — including any
    // custom capability with a write/external effect — requires an
    // explicit grant or approval. Callers building a real deployment are
    // expected to pass their own PolicyEngine.
    final engine = PolicyEngine(defaultDecision: 'require_approval');
    engine.applyPreset('auto_safe');
    return engine;
  }

  LLMAdapter? _resolveSummarizer() {
    if (summarizer != null) return summarizer;
    if (config.compaction.model == 'none') return null;
    return llm;
  }

  // -- public API -------------------------------------------------------------

  /// Chat mode: one user message in, the final text reply (or a pending
  /// [ApprovalRequest]) out.
  Future<Object?> send(String text) async {
    return _guarded(() async {
      conversation.add(Message(role: kUser, content: text));
      ledger.append(run.id, 'user_input', {'text': text});
      return await _loop();
    });
  }

  /// Job mode: run until finish(result), budget exhaustion, interrupt, or
  /// an approval pause.
  Future<Object?> runJob(String task) async {
    return _guarded(() async {
      conversation.add(Message(role: kUser, content: task));
      ledger.append(run.id, 'user_input', {'text': task});
      return await _loop();
    });
  }

  /// Request the loop to stop at the next iteration boundary.
  void interrupt() {
    _interrupted = true;
  }

  void addSection(Section section, {String before = 'candidates'}) {
    projection.insertBefore(before, section);
  }

  // -- approval lifecycle -------------------------------------------------

  /// Approve or deny the run's pending approval. Does not resume execution
  /// — call [resume] afterward.
  ApprovalRequest resolveApproval(String decision) {
    return run.resolveApproval(decision, currentPolicyRevision: policy.revision);
  }

  /// Continue a run paused at `WAITING_FOR_APPROVAL` (now resolved) or
  /// freshly reconstructed via [Session.resumeFromLedger].
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

  // -- direct invocation (bypasses the model, still goes through the same
  //    validate/authorize/execute/record pipeline) -------------------------

  Future<Object?> invoke(String capabilityName, [Map<String, Object?>? arguments]) async {
    return _guarded(() async {
      final turn = _newTurn();
      final call = ToolCall(name: capabilityName, arguments: arguments ?? {});
      final batch = await runtime.execute([call], turn, _toolContext(), run, policy);
      _applyBatch(batch, recordConversation: false);
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

  // -- branching (non-destructive rewind) ----------------------------------

  /// Create a new Session sharing history up to [atMessage] (default:
  /// current end). The parent's ledger is never modified or truncated —
  /// this only ever adds a new run whose own ledger starts with a
  /// `branch_created` event pointing at the parent.
  ///
  /// Returns `(newSession, irreversibleEffects)` where the second element
  /// lists external effects already committed by the parent run that this
  /// branch cannot undo (e.g. a sent email, a git push).
  (Session, List<String>) branch({int? atMessage}) {
    final cut = atMessage ?? conversation.length;
    final newSession = Session(
      llm,
      kernel: _kernelText,
      config: Config.fromMap(config.toMap()),
      registry: registry,
      embedder: search.embedder,
      summarizer: summarizer,
      spawnLlmFactory: spawnLlmFactory,
      policy: policy,
    );
    newSession.conversation = List.of(conversation.take(cut));
    newSession.workingState = WorkingState.fromDict(workingState.toDict());
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
      final capabilityName = command.capabilityName.substring(
          0, command.capabilityName.contains('@') ? command.capabilityName.lastIndexOf('@') : command.capabilityName.length);
      final capability = registry.get(capabilityName);
      if (capability != null && capability.effects.any((e) => e.kind == 'external')) {
        notices.add(
            '${capability.qualifiedName} (command ${command.id}) already ran and cannot be undone');
      }
    }
    return notices;
  }

  // -- process-restart resume ------------------------------------------------

  /// Reconstruct a Session from its last snapshot in a NEW process.
  ///
  /// This is what makes a `WAITING_FOR_APPROVAL` run survive a process
  /// restart: the caller (a new process, possibly hours later) loads the
  /// ledger directory, finds the snapshot, and gets back a Session ready
  /// for [resolveApproval] + [resume].
  static Session resumeFromLedger(
    LLMAdapter llm,
    String runId, {
    Config? config,
    Registry? registry,
    PolicyEngine? policy,
    EmbeddingBackend? embedder,
    LLMAdapter? summarizer,
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
      summarizer: summarizer,
      spawnLlmFactory: spawnLlmFactory,
      ledger: ledger,
    );
    session.run = Run.fromSnapshotState(runId, ledger, snapshot.state);
    session.sessionId = (snapshot.state['session_id'] as String?) ?? session.sessionId;
    session.workingState =
        WorkingState.fromDict((snapshot.state['working_state'] as Map?)?.cast<String, Object?>() ?? {});
    session.conversation = [
      for (final d in (snapshot.state['conversation'] as List? ?? []))
        Message.fromDict((d as Map).cast<String, Object?>()),
    ];
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
      'conversation': [for (final m in conversation) m.toDict()],
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

      await _maybeCompact();

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
        'calls': [for (final c in resolvedCalls) {'name': c.name, 'arguments': c.arguments}],
      });

      conversation.add(Message(role: kAssistant, content: decision.text, toolCalls: resolvedCalls));

      if (decision.finish && resolvedCalls.isNotEmpty) {
        // Reject outright, execute nothing.
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
        // Chat mode: finish() is just an alternate way to answer this turn
        // — the run itself stays RUNNING so the conversation can continue
        // with the next send().
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

  void _applyBatch(ExecuteBatchResult batch, {bool recordConversation = true}) {
    for (final result in batch.results) {
      if (recordConversation) {
        _observe(result.call.id, result.call.name, result.observation);
      }
      if (result.ok) {
        _activate(result.call.name);
      }
    }
  }

  // -- loop helpers -----------------------------------------------------------

  /// On overrun, grant exactly one grace turn to wrap up, then stop
  /// deterministically. Returns `(true, value)` when the loop must stop
  /// and return `value`; `(false, null)` to keep going.
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

  Future<void> _maybeCompact() async {
    final window = config.projection.windowTokens;
    if (!compactor.shouldCompact(conversation, window)) return;
    final (folded, remaining) = await compactor.fold(conversation, workingState);
    if (folded) {
      conversation = remaining;
      ledger.append(run.id, 'state_folded', {'working_state': workingState.toDict()});
    }
  }

  TurnContext _newTurn() {
    final turn = TurnContext(
      config: config,
      registry: registry,
      conversation: conversation,
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
    for (final message in conversation.reversed) {
      if (message.role == role && message.text().isNotEmpty) return message.text();
    }
    return '';
  }

  String _lastAssistantText() => _lastText(kAssistant);

  /// Native tool schemas for this turn: pinned + candidates + recently
  /// activated. Bounded, so tool schemas never approach O(N).
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
      // finish() is not a registered Capability — it's the formal
      // completion signal handled directly by the loop — but native
      // tool-calling providers still need its schema to offer it.
      schemas.add(finishSchema);
    }
    return schemas;
  }

  void _activate(String name) {
    _active.remove(name);
    _active.add(name); // re-insert at the end (LinkedHashSet preserves insertion order)
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

  /// Public because resident meta tools (e.g. `find_tools`) call back into
  /// the session to mark newly-discovered tools active. Python reaches
  /// this via `ctx.session._activate_tools`; Dart's per-library privacy
  /// means the equivalent must be public since `builtin/meta.dart` is a
  /// separate library.
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

  /// Append a tool observation — structurally distinct role.
  void _observe(String callId, String name, String text) {
    conversation.add(Message(role: kObservation, content: text, toolCallId: callId, name: name));
  }

  void _notice(String text) {
    conversation.add(Message(role: kSystem, content: text));
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
