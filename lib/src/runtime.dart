/// Deterministic runtime: validate → authorize → execute → record.
///
/// The LLM only decides *what* to do; validation, retries, timeouts,
/// ordering, policy authorization and output shaping are enforced here in
/// code.
///
/// Two correctness properties this module exists to guarantee, both
/// violated by naive "batch of tool calls" runtimes:
///
/// * **Order**: calls execute in the model's stated order by default. The
///   only concurrency allowed is a run of *adjacent* calls whose
///   capabilities declare no write/external effects — reads never race a
///   write, and a write never jumps ahead of an earlier read or write.
///   There is no cross-batch dependency solver; that complexity is
///   deliberately out of scope.
/// * **Idempotency**: a capability may only be auto-retried by this runtime
///   if its `retrySafety` is `pure` or `idempotent` — [CapabilityExecution]
///   refuses to even construct with `retries > 0` otherwise. A timeout is
///   recorded as outcome `unknown`, never silently treated as `failed`: we
///   cannot tell whether a handler's underlying effect completed after the
///   awaiting task gave up on it, and collapsing that distinction is
///   exactly what lets non-idempotent operations double-fire.
///
/// JSON Schema validation always uses the built-in mini validator (see
/// `json_schema.dart`) — this port has no `jsonschema`-equivalent optional
/// dependency to prefer.
library;

import 'dart:async';

import 'artifacts.dart' show ArtifactStore, serializeValue;
import 'capability.dart';
import 'compression.dart' show contentHash;
import 'config.dart';
import 'json_schema.dart';
import 'llm.dart' show finishName;
import 'messages.dart';
import 'policy.dart';
import 'registry.dart';
import 'run.dart';
import 'serialization.dart';
import 'tokens.dart';

export 'json_schema.dart' show validateArgs, applyDefaults;

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

const List<String> outcomes = ['ok', 'failed', 'unknown', 'denied', 'waiting_approval', 'waiting_user'];

/// Outcomes whose result arrives later (approval, answer): nothing is
/// recorded for the call until then, so the decision stays out of the
/// projection as a whole — see `pairToolCalls`.
const Set<String> waitingOutcomes = {'waiting_approval', 'waiting_user'};

class ToolResult {
  ToolResult({
    required this.call,
    required this.ok,
    this.value,
    this.error,
    this.observation = '',
    this.artifactId,
    this.outcome = 'ok', // one of `outcomes`
    this.commandId,
  });

  final ToolCall call;
  final bool ok;
  final Object? value;
  final String? error;
  final String observation;
  final String? artifactId;
  final String outcome;
  final String? commandId;
}

/// Result of one call to [Runtime.execute].
///
/// [halted] is true when a call in the batch required approval: the run
/// has already been transitioned to `WAITING_FOR_APPROVAL` and its
/// `pendingCalls` holds everything from that point on (inclusive) for
/// [Runtime.resumePending] to continue once approved. Calls after a halt
/// point are never even validated — order is preserved by construction.
class ExecuteBatchResult {
  ExecuteBatchResult({List<ToolResult>? results, this.halted = false})
      : results = results ?? <ToolResult>[];

  final List<ToolResult> results;
  final bool halted;
}

// ---------------------------------------------------------------------------
// Budget
// ---------------------------------------------------------------------------

double _now() => DateTime.now().millisecondsSinceEpoch / 1000.0;

class BudgetState {
  BudgetState({
    this.steps = 0,
    this.promptTokens = 0,
    this.completionTokens = 0,
    this.cost = 0.0,
    double? started,
  }) : started = started ?? _now();

  int steps;
  int promptTokens;
  int completionTokens;
  double cost;
  final double started;

  void noteUsage(int prompt, int completion, Config cfg) {
    promptTokens += prompt;
    completionTokens += completion;
    final b = cfg.budget;
    cost += prompt / 1000 * b.costPer1kInput + completion / 1000 * b.costPer1kOutput;
  }

  /// Account one model turn: the adapter's reported usage when it has one,
  /// otherwise an estimate from what was sent and what came back.
  void noteDecision(
      Decision decision, List<Message> messages, List<Map<String, Object?>> apiTools, Config cfg) {
    if (decision.usage != null) {
      noteUsage(decision.usage!.promptTokens, decision.usage!.completionTokens, cfg);
      return;
    }
    var completion = estimateTokens(decision.text);
    for (final call in decision.calls) {
      completion += 6 + estimateTokens(call.name) + estimateTokens(call.rawArguments ?? call.arguments);
    }
    // Adapters normalize finish(result) out of calls before returning.
    if (decision.finish) {
      completion += 6 + estimateTokens(finishName) + estimateTokens({'result': decision.result});
    }
    noteUsage(estimateTokens(messages) + estimateTokens(apiTools), completion, cfg);
  }

  String? exceeded(Config cfg) {
    final b = cfg.budget;
    if (b.maxSteps != null && steps >= b.maxSteps!) {
      return 'max_steps (${b.maxSteps}) reached';
    }
    final total = promptTokens + completionTokens;
    if (b.maxTokens != null && total >= b.maxTokens!) {
      return 'max_tokens (${b.maxTokens}) reached (used ~$total)';
    }
    if (b.maxCost != null && cost >= b.maxCost!) {
      return 'max_cost (${b.maxCost}) reached (spent ~${cost.toStringAsFixed(4)})';
    }
    if (b.maxSeconds != null && _now() - started >= b.maxSeconds!) {
      return 'max_seconds (${b.maxSeconds}) reached';
    }
    return null;
  }
}

// ---------------------------------------------------------------------------
// Runtime
// ---------------------------------------------------------------------------

class Runtime {
  // No artifact store of its own: it uses ctx.store, the session's current
  // one. A resumed run installs a fresh store for its new run id, and a
  // second copy captured here would silently keep writing artifacts the
  // session (and therefore meta.artifact.peek) could no longer read.
  Runtime(this.registry, this.config);

  final Registry registry;
  final Config config;

  // Capabilities whose full spec has already been projected into the
  // conversation. Used by the require_spec gate; pinned capabilities are
  // exempt because their spec is always in the kernel section.
  final Set<String> seenSpecs = {};
  final Map<String, int> _consecutiveValidationFailures = {};
  // Loop guard memory: (capability, arguments hash, result tag) of the last
  // `limits.repeatWindow` executed calls in this run.
  final List<(String, String, String)> _recent = [];

  /// Forget what this runtime learned from the conversation so far. Called on
  /// rewind: the specs shown and the failures counted are in the discarded
  /// history, so a capability must not start the new timeline already one
  /// strike from "giving up".
  void reset() {
    seenSpecs.clear();
    _consecutiveValidationFailures.clear();
    _recent.clear();
  }

  // -- loop guard -----------------------------------------------------------

  static String _argsHash(Map<String, Object?> args) => contentHash(dumps(args));

  /// Refuse a call the model keeps repeating with identical arguments when
  /// every repeat failed, or (for anything but a pure read) every repeat
  /// returned the same result. Polling a pure read for a change is legitimate
  /// and stays allowed.
  ToolResult? _loopGuard(ToolCall call, Capability capability, Map<String, Object?> args) {
    final max = config.limits.maxRepeats;
    if (max <= 0) return null;
    final argsHash = _argsHash(args);
    final tags = [for (final r in _recent) if (r.$1 == capability.name && r.$2 == argsHash) r.$3];
    if (tags.length < max) return null;
    String? why;
    if (tags.where((t) => t.startsWith('err:')).length >= max) {
      why = 'failed identically ${tags.length} times';
    } else if (!(isReadOnly(capability) && capability.execution.retrySafety == 'pure')) {
      final counts = <String, int>{};
      for (final t in tags) {
        counts[t] = (counts[t] ?? 0) + 1;
      }
      if (counts.values.any((n) => n >= max)) why = 'returned the same result ${tags.length} times';
    }
    if (why == null) return null;
    return ToolResult(
      call: call,
      ok: false,
      outcome: 'failed',
      error: 'loop_guard',
      observation: 'Loop guard: "${capability.name}" with these exact arguments $why. '
          'It was not executed again; change the arguments or the approach.',
    );
  }

  void _remember(Capability capability, Map<String, Object?> args, ToolResult result) {
    if (waitingOutcomes.contains(result.outcome)) return;
    final tag = result.ok
        ? contentHash(serializeValue(result.value))
        : 'err:${contentHash((result.error ?? '').replaceAll(RegExp(r'\d'), ''))}';
    _recent.add((capability.name, _argsHash(args), tag));
    while (_recent.length > config.limits.repeatWindow) {
      _recent.removeAt(0);
    }
  }

  Future<ToolResult> _run(Capability capability, Map<String, Object?> args, ToolContext ctx,
      Run run, ToolCall call, {Command? command}) async {
    final result = await _executeOne(capability, args, ctx, run, call, command: command);
    _remember(capability, args, result);
    return result;
  }

  // -- public ---------------------------------------------------------------

  /// Validate, authorize and run a batch of calls, in order.
  ///
  /// A contiguous run of calls whose capabilities declare no write/external
  /// effects may execute concurrently; anything else runs one at a time,
  /// strictly in the order the model asked for it.
  Future<ExecuteBatchResult> execute(
    List<ToolCall> calls,
    ToolContext ctx,
    Run run,
    PolicyEngine policy,
  ) async {
    final results = <ToolResult>[];
    final buffer = <(ToolCall, Capability, Map<String, Object?>)>[];

    Future<void> flush() async {
      if (buffer.isEmpty) return;
      if (buffer.length == 1) {
        final (call, cap, args) = buffer[0];
        results.add(await _run(cap, args, ctx, run, call));
      } else {
        final batch = await Future.wait([
          for (final (call, cap, args) in buffer) _run(cap, args, ctx, run, call),
        ]);
        results.addAll(batch);
      }
      buffer.clear();
    }

    for (var idx = 0; idx < calls.length; idx++) {
      final call = calls[idx];
      final pre = _preCheck(call);
      if (pre is ToolResult) {
        await flush();
        results.add(pre);
        continue;
      }
      final (capability, args) = pre as (Capability, Map<String, Object?>);
      final tripped = _loopGuard(call, capability, args);
      if (tripped != null) {
        await flush();
        results.add(tripped);
        continue;
      }
      final decision = policy.evaluate(capability, args);
      if (decision.decision == 'deny') {
        await flush();
        results.add(ToolResult(
          call: call,
          ok: false,
          outcome: 'denied',
          error: decision.reason,
          observation: 'Denied by policy (${decision.layer}): ${decision.reason}',
        ));
        continue;
      }
      if (decision.decision == 'require_approval') {
        await flush();
        final command =
            run.newCommand(capability.qualifiedName, args, capability.execution.retrySafety);
        run.pendingCalls = calls.sublist(idx);
        run.requestApproval(
          command,
          capability.effects,
          decision.reason,
          policyRevision: policy.revision,
          expiresInS: config.limits.approvalExpiresS,
        );
        results.add(ToolResult(
          call: call,
          ok: false,
          outcome: 'waiting_approval',
          error: 'approval_required',
          observation: 'Approval required: ${decision.reason}',
          commandId: command.id,
        ));
        return ExecuteBatchResult(results: results, halted: true);
      }
      if (Runtime.isReadOnly(capability)) {
        buffer.add((call, capability, args));
      } else {
        await flush();
        results.add(await _run(capability, args, ctx, run, call));
        if (results.last.outcome == 'waiting_user') {
          run.pendingCalls = calls.sublist(idx + 1);
          return ExecuteBatchResult(results: results, halted: true);
        }
      }
    }
    await flush();
    return ExecuteBatchResult(results: results, halted: false);
  }

  /// Continue a run's `pendingCalls` after its approval was resolved or its
  /// question answered.
  ///
  /// After an approval the first pending call already has a [Command] (created when approval
  /// was requested) and is executed directly, reusing its `commandId` — no
  /// re-validation, no re-authorization, so an approved command cannot
  /// silently get a different idempotency key on retry. The remaining calls
  /// go back through the normal [execute] path.
  Future<ExecuteBatchResult> resumePending(
    Run run,
    ToolContext ctx,
    PolicyEngine policy,
  ) async {
    final pending = run.pendingCalls;
    if (pending.isEmpty) return ExecuteBatchResult(results: [], halted: false);
    final firstCall = pending[0];
    final resolved = run.lastResolvedApproval;
    run.lastResolvedApproval = null; // consumed here; must not leak into a later pause
    final approved = (resolved != null && resolved.resolution == 'approved')
        ? run.commands[resolved.commandId]
        : null;
    if (resolved != null && resolved.resolution == 'denied') {
      final deniedCommand = run.commands[resolved.commandId];
      final deniedName = deniedCommand?.capabilityName ?? firstCall.name;
      final rest = pending.skip(1).toList();
      run.pendingCalls = [];
      // Every parked call needs its own result: the denial cancels the rest
      // of the decision too, and a call left without one would take the whole
      // decision out of the projection.
      return ExecuteBatchResult(
        results: [
          ToolResult(
            call: firstCall,
            ok: false,
            outcome: 'denied',
            error: 'approval_denied',
            observation: 'Approval denied: $deniedName was not executed.',
            commandId: deniedCommand?.id,
          ),
          for (final call in rest)
            ToolResult(
              call: call,
              ok: false,
              outcome: 'denied',
              error: 'approval_denied',
              observation: 'Not executed: the approval for $deniedName was denied.',
            ),
        ],
        halted: false,
      );
    }
    run.pendingCalls = [];
    if (approved == null) {
      // Parked behind a question, not an approval: nothing here was checked
      // yet, so every call takes the normal path.
      return execute(pending, ctx, run, policy);
    }
    final capability = registry.get(approved.capabilityName);
    final results = <ToolResult>[];
    if (capability == null) {
      results.add(ToolResult(
        call: firstCall,
        ok: false,
        outcome: 'failed',
        error: 'unknown_capability',
        observation: 'Error: capability "${firstCall.name}" no longer registered.',
      ));
    } else {
      results.add(await _run(capability, approved.arguments, ctx, run, firstCall, command: approved));
      if (results.last.outcome == 'waiting_user') {
        run.pendingCalls = pending.sublist(1);
        return ExecuteBatchResult(results: results, halted: true);
      }
    }
    final rest = await execute(pending.sublist(1), ctx, run, policy);
    return ExecuteBatchResult(results: [...results, ...rest.results], halted: rest.halted);
  }

  // -- pre-checks: unknown capability / require_spec / validation ---------

  /// Returns a [ToolResult] on early rejection, or `(Capability, args)`.
  Object _preCheck(ToolCall call) {
    final capability = registry.get(call.name);
    if (capability == null) {
      final toc = registry.tocText();
      // Never point at a search tool that is itself absent or disabled: a
      // capability the model cannot reach must not be advertised.
      final hint = registry.contains('meta.tool.find')
          ? ' Use meta.tool.find(query) to locate the right one.'
          : '';
      return ToolResult(
        call: call,
        ok: false,
        outcome: 'failed',
        error: 'unknown_capability',
        observation: 'Error: capability "${call.name}" is not registered. '
            'Tool index: ${toc.isNotEmpty ? toc : '(empty)'}.$hint',
      );
    }

    // A pinned capability's full spec is already in the kernel section, so
    // the gate is satisfied by construction — no pre-seeding needed.
    final needsSpec = capability.discovery.requireSpec && !capability.discovery.pinned;
    if (needsSpec && !seenSpecs.contains(capability.name)) {
      seenSpecs.add(capability.name);
      return ToolResult(
        call: call,
        ok: false,
        outcome: 'failed',
        error: 'require_spec',
        observation: 'Capability "${call.name}" requires its full spec to be reviewed before '
            'first use. The spec follows — verify your arguments against it and call again.\n'
            '${capability.specText()}',
      );
    }

    var args = call.arguments;
    String? error;
    if (call.rawArguments != null && args.isEmpty) {
      final preview = call.rawArguments!.length > 200
          ? call.rawArguments!.substring(0, 200)
          : call.rawArguments!;
      error = 'arguments were not valid JSON: "$preview"';
    } else {
      args = applyDefaults(capability.spec.parameters, args);
      error = validateArgs(capability.spec.parameters, args);
    }

    if (error != null) {
      final n = (_consecutiveValidationFailures[call.name] ?? 0) + 1;
      _consecutiveValidationFailures[call.name] = n;
      final limit = config.limits.maxValidationRetries;
      String observation;
      if (n > limit) {
        observation = 'Validation failed $n times in a row for "${call.name}"; giving up on '
            'this call (limit $limit). Last error: $error. Try a different tool or approach.';
      } else {
        seenSpecs.add(capability.name);
        observation = 'Validation error calling "${call.name}": $error\n'
            'The call was NOT executed. The full spec follows — fix the arguments and retry.\n'
            '${capability.specText()}';
      }
      return ToolResult(
        call: call,
        ok: false,
        outcome: 'failed',
        error: 'validation: $error',
        observation: observation,
      );
    }

    _consecutiveValidationFailures[call.name] = 0;
    return (capability, args);
  }

  static bool isReadOnly(Capability capability) {
    // Mirrors PolicyEngine.evaluate: undeclared effects are treated as the
    // most restrictive kind, so an author who forgot to declare effects
    // doesn't also get free parallel execution.
    final effects = capability.effects.isNotEmpty
        ? capability.effects
        : [Effect(kind: 'external', resource: 'undeclared:*')];
    return effects.every((e) => e.kind == 'none' || e.kind == 'read');
  }

  // -- execution ------------------------------------------------------------

  Future<ToolResult> _executeOne(
    Capability capability,
    Map<String, Object?> args,
    ToolContext ctx,
    Run run,
    ToolCall call, {
    Command? command,
  }) async {
    command ??= run.newCommand(capability.qualifiedName, args, capability.execution.retrySafety);
    final callCtx = ctx.forCommand(command.id);

    final handler = capability.execution.handler;
    if (handler == null) {
      run.recordOutcome(command, 'failed', error: 'no_handler');
      return ToolResult(
        call: call,
        ok: false,
        outcome: 'failed',
        error: 'no_handler',
        commandId: command.id,
        observation: 'Error: capability "${capability.name}" has no executable handler registered.',
      );
    }
    final resolved = capability.execution.resolveHandles
        ? (ctx.store!.resolveArgs(args) as Map).cast<String, Object?>()
        : args;
    final attempts = capability.execution.retries + 1 < 1 ? 1 : capability.execution.retries + 1;
    var lastError = '';
    var lastOutcome = 'failed';
    for (var attempt = 0; attempt < attempts; attempt++) {
      command.attempts += 1;
      try {
        final value = await _invoke(handler, capability, resolved, callCtx)
            .timeout(Duration(milliseconds: (capability.execution.timeoutS * 1000).round()));
        if (value is Question) {
          // The command stays pending until Session.answer completes it.
          run.askQuestion(command, call.id, value);
          return ToolResult(
            call: call,
            ok: false,
            outcome: 'waiting_user',
            error: 'question_pending',
            observation: 'Question pending: ${value.text}',
            commandId: command.id,
          );
        }
        final (observation, artifactId) = _observationFor(capability, value, ctx.store!);
        run.recordOutcome(command, 'ok', resultRef: artifactId);
        return ToolResult(
          call: call,
          ok: true,
          value: value,
          outcome: 'ok',
          commandId: command.id,
          observation: observation,
          artifactId: artifactId,
        );
      } on TimeoutException {
        // We cannot confirm whether the underlying effect completed after
        // the awaiting task gave up — never collapse this into "failed". A
        // retry only proceeds below if the capability's retrySafety already
        // permits blind retries.
        lastError = 'timed out after ${capability.execution.timeoutS}s';
        lastOutcome = 'unknown';
      } catch (exc) {
        lastError = '${exc.runtimeType}: $exc';
        lastOutcome = 'failed';
      }
      if (attempt < attempts - 1) {
        final delayMs = (0.5 * (attempt + 1) * 1000).clamp(0, 2000).round();
        await Future.delayed(Duration(milliseconds: delayMs));
      }
    }
    run.recordOutcome(command, lastOutcome, error: lastError);
    final isUnknown = lastOutcome == 'unknown';
    return ToolResult(
      call: call,
      ok: false,
      error: lastError,
      outcome: lastOutcome,
      commandId: command.id,
      observation: '${isUnknown ? 'Timed out' : 'Error'} executing "${capability.name}" '
          '($attempts attempt(s)): $lastError. '
          '${isUnknown ? 'Outcome is UNKNOWN — do not blindly retry a non-idempotent action; check state first.' : 'The call failed; adjust and retry or use another tool.'}',
    );
  }

  static Future<Object?> _invoke(
    Function handler,
    Capability capability,
    Map<String, Object?> args,
    ToolContext ctx,
  ) async {
    if (capability.wantsCtx) {
      final fn = handler as CtxHandler;
      return await fn(ctx, args);
    }
    final fn = handler as PlainHandler;
    return await fn(args);
  }

  // -- output policy --------------------------------------------------------

  (String, String?) _observationFor(
      Capability capability, Object? value, ArtifactStore store) {
    final text = serializeValue(value);
    final policy = capability.execution.outputPolicy;
    final threshold = policy.maxInlineTokens ?? config.artifacts.inlineThresholdTokens;
    final tokens = estimateTokens(text);
    if (tokens <= threshold) {
      return (text.isNotEmpty ? text : '(empty result)', null);
    }
    if (policy.overflow == 'truncate') {
      return ('${truncateToTokens(text, threshold)}\n…[truncated by output_policy]', null);
    }
    final record = store.put(value, source: capability.name);
    final refText = store.refText(
      record,
      preview: policy.preview,
      previewTokens: config.artifacts.previewTokens,
    );
    final hint = registry.contains('meta.artifact.peek')
        ? '\nUse meta.artifact.peek(artifact={"\$artifact": "${record.id}"}, '
            'query=..., range=...) to inspect further.'
        : '';
    return ('$refText$hint', record.id);
  }
}
