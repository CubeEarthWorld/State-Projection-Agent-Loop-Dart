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

import 'artifacts.dart' show ArtifactStore, serializeValue, truncateToTokens;
import 'capability.dart';
import 'config.dart';
import 'json_schema.dart';
import 'messages.dart';
import 'policy.dart';
import 'projection.dart' show TurnContext;
import 'registry.dart';
import 'run.dart';
import 'tokens.dart';

export 'json_schema.dart' show validateArgs, applyDefaults;

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------

const List<String> outcomes = ['ok', 'failed', 'unknown', 'denied', 'waiting_approval'];

class ToolResult {
  ToolResult({
    required this.call,
    required this.ok,
    this.value,
    this.error,
    this.observation = '',
    this.artifactId,
    this.elapsedS = 0.0,
    this.outcome = 'ok', // one of `outcomes`
    this.commandId,
  });

  final ToolCall call;
  final bool ok;
  final Object? value;
  final String? error;
  final String observation;
  final String? artifactId;
  final double elapsedS;
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

  String? exceeded(Config cfg) {
    final b = cfg.budget;
    if (steps >= b.maxSteps) {
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
  Runtime(this.registry, this.store, this.config);

  final Registry registry;
  final ArtifactStore store;
  final Config config;

  // Capabilities whose full spec has already been projected into the
  // conversation (pinned specs live in the kernel → pre-seeded by the
  // session). Used by the require_spec gate.
  final Set<String> seenSpecs = {};
  final Map<String, int> _consecutiveValidationFailures = {};

  // -- public ---------------------------------------------------------------

  /// Validate, authorize and run a batch of calls, in order.
  ///
  /// A contiguous run of calls whose capabilities declare no write/external
  /// effects may execute concurrently; anything else runs one at a time,
  /// strictly in the order the model asked for it.
  Future<ExecuteBatchResult> execute(
    List<ToolCall> calls,
    TurnContext turn,
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
        results.add(await _executeOne(cap, args, ctx, run, call));
      } else {
        final batch = await Future.wait([
          for (final (call, cap, args) in buffer) _executeOne(cap, args, ctx, run, call),
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
      if (_isReadOnly(capability)) {
        buffer.add((call, capability, args));
      } else {
        await flush();
        results.add(await _executeOne(capability, args, ctx, run, call));
      }
    }
    await flush();
    return ExecuteBatchResult(results: results, halted: false);
  }

  /// Continue a run's `pendingCalls` after its approval was resolved.
  ///
  /// The first pending call already has a [Command] (created when approval
  /// was requested) and is executed directly, reusing its `commandId` — no
  /// re-validation, no re-authorization, so an approved command cannot
  /// silently get a different idempotency key on retry. The remaining calls
  /// go back through the normal [execute] path.
  Future<ExecuteBatchResult> resumePending(
    Run run,
    ToolContext ctx,
    PolicyEngine policy,
    TurnContext turn,
  ) async {
    final pending = run.pendingCalls;
    if (pending.isEmpty) return ExecuteBatchResult(results: [], halted: false);
    final firstCall = pending[0];
    final resolved = run.lastResolvedApproval;
    final approved = (resolved != null && resolved.resolution == 'approved')
        ? run.commands[resolved.commandId]
        : null;
    if (resolved != null && resolved.resolution == 'denied') {
      final deniedCommand = run.commands[resolved.commandId];
      final observation =
          'Approval denied: ${deniedCommand?.capabilityName ?? firstCall.name} was not executed.';
      run.pendingCalls = [];
      return ExecuteBatchResult(
        results: [
          ToolResult(
            call: firstCall,
            ok: false,
            outcome: 'denied',
            error: 'approval_denied',
            observation: observation,
            commandId: deniedCommand?.id,
          ),
        ],
        halted: false,
      );
    }
    final capability =
        approved != null ? registry.get(approved.capabilityName) : registry.get(firstCall.name);
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
      final args = approved != null ? approved.arguments : firstCall.arguments;
      results.add(
          await _executeOne(capability, args, ctx, run, firstCall, command: approved));
    }
    run.pendingCalls = [];
    final rest = await execute(pending.sublist(1), turn, ctx, run, policy);
    results.addAll(rest.results);
    return ExecuteBatchResult(results: results, halted: rest.halted);
  }

  // -- pre-checks: unknown capability / require_spec / validation ---------

  /// Returns a [ToolResult] on early rejection, or `(Capability, args)`.
  Object _preCheck(ToolCall call) {
    final capability = registry.get(call.name);
    if (capability == null) {
      final toc = registry.tocText();
      return ToolResult(
        call: call,
        ok: false,
        outcome: 'failed',
        error: 'unknown_capability',
        observation: 'Error: capability "${call.name}" is not registered. '
            'Tool index: ${toc.isNotEmpty ? toc : '(empty)'}. '
            'Use find_tools(query) to locate the right one.',
      );
    }

    if (capability.discovery.requireSpec && !seenSpecs.contains(capability.name)) {
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

  static bool _isReadOnly(Capability capability) {
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
    final callCtx = ctx.copyWith(commandId: command.id);

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
        ? (store.resolveArgs(args) as Map).cast<String, Object?>()
        : args;
    final attempts = capability.execution.retries + 1 < 1 ? 1 : capability.execution.retries + 1;
    final start = _now();
    var lastError = '';
    var lastOutcome = 'failed';
    for (var attempt = 0; attempt < attempts; attempt++) {
      command.attempts += 1;
      try {
        final value = await _invoke(handler, capability, resolved, callCtx)
            .timeout(Duration(milliseconds: (capability.execution.timeoutS * 1000).round()));
        final elapsed = _now() - start;
        final (observation, artifactId) = _observationFor(capability, value);
        run.recordOutcome(command, 'ok', resultRef: artifactId);
        return ToolResult(
          call: call,
          ok: true,
          value: value,
          outcome: 'ok',
          commandId: command.id,
          observation: observation,
          artifactId: artifactId,
          elapsedS: elapsed,
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
    final elapsed = _now() - start;
    run.recordOutcome(command, lastOutcome, error: lastError);
    final isUnknown = lastOutcome == 'unknown';
    return ToolResult(
      call: call,
      ok: false,
      error: lastError,
      outcome: lastOutcome,
      elapsedS: elapsed,
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

  (String, String?) _observationFor(Capability capability, Object? value) {
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
    return (
      '$refText\nUse peek(artifact={"\$artifact": "${record.id}"}, query=..., range=...) to inspect further.',
      record.id,
    );
  }
}
