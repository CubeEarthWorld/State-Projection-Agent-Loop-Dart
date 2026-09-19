// Runtime: validation & self-repair, require_spec gate, ordering,
// retry-safety-gated retries and OUTCOME_UNKNOWN, output policy,
// budget arithmetic.
import 'dart:async';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

(Runtime, ToolContext, ToolContext, Run, PolicyEngine) makeRuntime(
  Registry registry, {
  Config? config,
  bool allowAll = true,
}) {
  final cfg = config ?? Config();
  final store = ArtifactStore('run_test');
  final runtime = Runtime(registry, cfg);
  final ledger = InMemoryLedger();
  final run = Run('run_test', 'ses_test', ledger);
  final policy = PolicyEngine(defaultDecision: allowAll ? 'allow' : 'require_approval');
  final turn = ToolContext(config: cfg, registry: registry, ledger: ledger, run: run, store: store);
  final ctx = ToolContext(registry: registry, store: store, config: cfg, ledger: ledger, run: run);
  return (runtime, turn, ctx, run, policy);
}

Future<ExecuteBatchResult> runBatch(Runtime runtime, List<ToolCall> calls, ToolContext turn,
        ToolContext ctx, Run run, PolicyEngine policy) =>
    runtime.execute(calls, ctx, run, policy);

Registry echoRegistry() {
  final reg = Registry();
  reg.register(
    capabilityDict('demo.echo',
        description: 'Echo the text back.',
        properties: {
          'text': {'type': 'string'},
        },
        required: ['text']),
    handler: (Map<String, Object?> args) => 'echo: ${args['text']}',
  );
  return reg;
}

void main() {
  group('Validation', () {
    test('happy path', () async {
      final (runtime, turn, ctx, run, policy) = makeRuntime(echoRegistry());
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.echo', arguments: {'text': 'hi'})], turn, ctx, run, policy);
      final result = batch.results.single;
      expect(result.ok, isTrue);
      expect(result.observation, equals('echo: hi'));
      expect(result.outcome, equals('ok'));
    });

    test('type error attaches spec', () async {
      final (runtime, turn, ctx, run, policy) = makeRuntime(echoRegistry());
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.echo', arguments: {'text': 42})], turn, ctx, run, policy);
      final result = batch.results.single;
      expect(result.ok, isFalse);
      expect(result.observation, contains('Validation error'));
      expect(result.observation, contains('### demo.echo'));
      expect(result.observation, contains('NOT executed'));
    });

    test('missing required', () async {
      final (runtime, turn, ctx, run, policy) = makeRuntime(echoRegistry());
      final batch =
          await runBatch(runtime, [ToolCall(name: 'demo.echo', arguments: {})], turn, ctx, run, policy);
      expect(batch.results[0].ok, isFalse);
      expect(batch.results[0].observation, contains('required'));
    });

    test('malformed raw arguments', () async {
      final (runtime, turn, ctx, run, policy) = makeRuntime(echoRegistry());
      final call = ToolCall(name: 'demo.echo', arguments: {}, rawArguments: '{"text": broken');
      final batch = await runBatch(runtime, [call], turn, ctx, run, policy);
      expect(batch.results[0].ok, isFalse);
      expect(batch.results[0].observation, contains('not valid JSON'));
    });

    test('unknown capability mentions the search tool when present', () async {
      final registry = echoRegistry();
      installBuiltins(registry, ['meta']);
      final (runtime, turn, ctx, run, policy) = makeRuntime(registry);
      final batch =
          await runBatch(runtime, [ToolCall(name: 'nope.nope', arguments: {})], turn, ctx, run, policy);
      expect(batch.results[0].ok, isFalse);
      expect(batch.results[0].observation, contains('meta.tool.find'));
    });

    test('unknown capability never advertises an absent search tool', () async {
      final (runtime, turn, ctx, run, policy) = makeRuntime(echoRegistry());
      final batch =
          await runBatch(runtime, [ToolCall(name: 'nope.nope', arguments: {})], turn, ctx, run, policy);
      expect(batch.results[0].ok, isFalse);
      expect(batch.results[0].observation, isNot(contains('meta.tool.find')));
    });
  });

  group('RequireSpec', () {
    test('first call bounced second runs', () async {
      final reg = Registry();
      reg.register(
        capabilityDict('demo.danger',
            requireSpec: true,
            properties: {
              'target': {'type': 'string'},
            },
            required: ['target']),
        handler: (Map<String, Object?> args) => 'deleted ${args['target']}',
      );
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final call = ToolCall(name: 'demo.danger', arguments: {'target': 'tmp'});
      final first = (await runBatch(runtime, [call], turn, ctx, run, policy)).results[0];
      expect(first.ok, isFalse);
      expect(first.observation, contains('### demo.danger'));
      final second = (await runBatch(runtime, [call], turn, ctx, run, policy)).results[0];
      expect(second.ok, isTrue);
      expect(second.observation, equals('deleted tmp'));
    });
  });

  group('Ordering', () {
    // Calls execute in the model's stated order; only a contiguous
    // run of read-only capabilities may run concurrently.
    test('write then read preserves order', () async {
      final reg = Registry();
      final log = <String>[];

      reg.register(
        capabilityDict('fs.write',
            properties: {
              'value': {'type': 'string'},
            },
            required: ['value'],
            effects: [('write', 'workspace:*')]),
        handler: (Map<String, Object?> args) {
          log.add('write:${args['value']}');
          return 'written';
        },
      );
      reg.register(
        capabilityDict('fs.read', effects: [('read', 'workspace:*')]),
        handler: (Map<String, Object?> args) {
          log.add('read');
          return log.join('');
        },
      );
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final calls = [
        ToolCall(name: 'fs.write', arguments: {'value': 'x'}),
        ToolCall(name: 'fs.read', arguments: {}),
      ];
      final batch = await runBatch(runtime, calls, turn, ctx, run, policy);
      expect(log, equals(['write:x', 'read']));
      expect(batch.results.map((r) => r.call.name).toList(), equals(['fs.write', 'fs.read']));
    });

    test('adjacent read only calls run concurrently', () async {
      final reg = Registry();

      // Returns only once all three have started: run serially, the first
      // would wait forever and hit its timeout instead.
      var started = 0;
      Future<String> slow(Map<String, Object?> args) async {
        started += 1;
        while (started < 3) {
          await Future<void>.delayed(Duration.zero);
        }
        return 'done';
      }

      for (final name in ['demo.p1', 'demo.p2', 'demo.p3']) {
        reg.register(capabilityDict(name, effects: [('read', 'workspace:*')], timeoutS: 5), handler: slow);
      }
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final calls = [
        for (final n in ['demo.p1', 'demo.p2', 'demo.p3']) ToolCall(name: n, arguments: {}),
      ];
      final batch = await runBatch(runtime, calls, turn, ctx, run, policy);
      expect(batch.results.every((r) => r.ok), isTrue);
    });

    test('write breaks the parallel streak', () async {
      final reg = Registry();
      reg.register(capabilityDict('demo.read1', effects: [('read', 'workspace:*')]),
          handler: (Map<String, Object?> args) => 'r1');
      reg.register(capabilityDict('demo.write1', effects: [('write', 'workspace:*')]),
          handler: (Map<String, Object?> args) => 'w1');
      reg.register(capabilityDict('demo.read2', effects: [('read', 'workspace:*')]),
          handler: (Map<String, Object?> args) => 'r2');
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final calls = [
        for (final n in ['demo.read1', 'demo.write1', 'demo.read2']) ToolCall(name: n, arguments: {}),
      ];
      final batch = await runBatch(runtime, calls, turn, ctx, run, policy);
      expect(batch.results.map((r) => r.call.name).toList(),
          equals(['demo.read1', 'demo.write1', 'demo.read2']));
      expect(batch.results.map((r) => r.value).toList(), equals(['r1', 'w1', 'r2']));
    });
  });

  group('RetrySafety', () {
    // Retries are only permitted for pure/idempotent capabilities;
    // a timeout is OUTCOME_UNKNOWN, never silently "failed".
    test('timeout is outcome unknown not failed', () async {
      final reg = Registry();
      Future<String> sleeper(Map<String, Object?> args) async {
        await Future.delayed(const Duration(seconds: 1));
        return 'never';
      }

      reg.register(capabilityDict('demo.sleepy', timeoutS: 0.1), handler: sleeper);
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.sleepy', arguments: {})], turn, ctx, run, policy);
      final result = batch.results[0];
      expect(result.ok, isFalse);
      expect(result.outcome, equals('unknown'));
      expect(result.observation, contains('UNKNOWN'));
    });

    test('timeout on never_retry does not retry', () async {
      final reg = Registry();
      var attempts = 0;
      Future<String> sleeper(Map<String, Object?> args) async {
        attempts += 1;
        await Future.delayed(const Duration(seconds: 1));
        return 'never';
      }

      reg.register(
          capabilityDict('demo.sleepy', timeoutS: 0.05, retrySafety: 'never_retry', retries: 0),
          handler: sleeper);
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      await runBatch(runtime, [ToolCall(name: 'demo.sleepy', arguments: {})], turn, ctx, run, policy);
      expect(attempts, equals(1));
    });

    test('idempotent retry then success', () async {
      final reg = Registry();
      var attempts = 0;
      Object? flaky(Map<String, Object?> args) {
        attempts += 1;
        if (attempts == 1) {
          throw Exception('transient');
        }
        return 'recovered';
      }

      reg.register(capabilityDict('demo.flaky', retries: 1, retrySafety: 'idempotent'),
          handler: flaky);
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.flaky', arguments: {})], turn, ctx, run, policy);
      final result = batch.results[0];
      expect(result.ok, isTrue);
      expect(result.observation, equals('recovered'));
      expect(attempts, equals(2));
    });

    test('command id stable across retries', () async {
      final reg = Registry();
      final seenIds = <String>[];
      Object? flaky(ToolContext ctx, Map<String, Object?> args) {
        seenIds.add(ctx.commandId);
        if (seenIds.length == 1) {
          throw Exception('transient');
        }
        return 'ok';
      }

      reg.register(capabilityDict('demo.flaky', retries: 1, retrySafety: 'idempotent'),
          handler: flaky, wantsCtx: true);
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      await runBatch(runtime, [ToolCall(name: 'demo.flaky', arguments: {})], turn, ctx, run, policy);
      expect(seenIds.length, equals(2));
      expect(seenIds[0], equals(seenIds[1]));
    });

    test('exception becomes failed observation', () async {
      final reg = Registry();
      Object? boom(Map<String, Object?> args) => throw Exception('kaboom');
      reg.register(capabilityDict('demo.boom'), handler: boom);
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.boom', arguments: {})], turn, ctx, run, policy);
      final result = batch.results[0];
      expect(result.ok, isFalse);
      expect(result.outcome, equals('failed'));
      expect(result.observation, contains('kaboom'));
    });

    test('ctx injection', () async {
      final reg = Registry();
      Object? withCtx(ToolContext ctx, Map<String, Object?> args) {
        final ws = ctx.workingState;
        return 'state[${args['key']}]=${ws.extra[args['key']]}';
      }

      reg.register(
        capabilityDict('demo.st', properties: {
          'key': {'type': 'string'},
        }, required: [
          'key'
        ]),
        handler: withCtx,
        wantsCtx: true,
      );
      final (runtime, turn, ctxBase, run, policy) = makeRuntime(reg);
      final ctx = ToolContext(
        registry: ctxBase.registry,
        store: ctxBase.store,
        config: ctxBase.config,
        ledger: ctxBase.ledger,
        run: ctxBase.run,
        workingState: WorkingState(extra: {'hp': 10}),
      );
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.st', arguments: {'key': 'hp'})], turn, ctx, run, policy);
      expect(batch.results[0].value, equals('state[hp]=10'));
    });
  });

  group('PolicyGating', () {
    test('deny prevents execution', () async {
      final reg = Registry();
      var called = 0;
      Object? handler(Map<String, Object?> args) {
        called += 1;
        return 'ran';
      }

      reg.register(capabilityDict('demo.risky', effects: [('external', '*')]), handler: handler);
      final (runtime, turn, ctx, run, _) = makeRuntime(reg, allowAll: false);
      final policy = PolicyEngine(defaultDecision: 'deny');
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.risky', arguments: {})], turn, ctx, run, policy);
      expect(batch.results[0].ok, isFalse);
      expect(batch.results[0].outcome, equals('denied'));
      expect(called, equals(0));
    });

    test('require_approval halts batch and preserves pending', () async {
      final reg = Registry();
      reg.register(capabilityDict('demo.risky', effects: [('external', '*')]),
          handler: (Map<String, Object?> args) => 'ran');
      reg.register(capabilityDict('demo.after'), handler: (Map<String, Object?> args) => 'after');
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg, allowAll: false);
      final calls = [
        ToolCall(name: 'demo.risky', arguments: {}),
        ToolCall(name: 'demo.after', arguments: {}),
      ];
      final batch = await runBatch(runtime, calls, turn, ctx, run, policy);
      expect(batch.halted, isTrue);
      expect(run.state, equals('WAITING_FOR_APPROVAL'));
      expect(run.pendingCalls.map((c) => c.name).toList(), equals(['demo.risky', 'demo.after']));
    });
  });

  group('OutputPolicy', () {
    test('large result becomes artifact', () async {
      final reg = Registry();
      reg.register(capabilityDict('demo.big', maxInlineTokens: 50),
          handler: (Map<String, Object?> args) => 'data ' * 500);
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.big', arguments: {})], turn, ctx, run, policy);
      final result = batch.results[0];
      expect(result.ok, isTrue);
      expect(result.artifactId, isNotNull);
      expect(result.observation, contains(result.artifactId!));
      expect((ctx.store as ArtifactStore).get(result.artifactId!), equals('data ' * 500));
    });

    test('truncate policy', () async {
      final reg = Registry();
      reg.register(capabilityDict('demo.cut', maxInlineTokens: 50, overflow: 'truncate'),
          handler: (Map<String, Object?> args) => 'data ' * 500);
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final batch = await runBatch(
          runtime, [ToolCall(name: 'demo.cut', arguments: {})], turn, ctx, run, policy);
      final result = batch.results[0];
      expect(result.artifactId, isNull);
      expect(result.observation, contains('[truncated by output_policy]'));
    });

    test('artifact reference resolution', () async {
      final reg = Registry();
      reg.register(
        capabilityDict('demo.length', properties: {'data': <String, Object?>{}}, required: ['data']),
        handler: (Map<String, Object?> args) => 'len=${(args['data'] as List).length}',
      );
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final record = (ctx.store as ArtifactStore).put([1, 2, 3, 4]);
      final batch = await runBatch(
        runtime,
        [ToolCall(name: 'demo.length', arguments: {'data': ref(record.id)})],
        turn,
        ctx,
        run,
        policy,
      );
      expect(batch.results[0].value, equals('len=4'));
    });

    test('bare string matching artifact id not resolved', () async {
      final reg = Registry();
      reg.register(
        capabilityDict('demo.echo2', properties: {'data': <String, Object?>{}}, required: ['data']),
        handler: (Map<String, Object?> args) => args['data'],
      );
      final (runtime, turn, ctx, run, policy) = makeRuntime(reg);
      final record = (ctx.store as ArtifactStore).put([1, 2, 3]);
      final batch = await runBatch(
        runtime,
        [ToolCall(name: 'demo.echo2', arguments: {'data': record.id})],
        turn,
        ctx,
        run,
        policy,
      );
      expect(batch.results[0].value, equals(record.id)); // literal string passed through
    });
  });

  group('BudgetState', () {
    test('steps and tokens', () {
      final cfg = Config.fromDict({
        'budget': {'max_steps': 2, 'max_tokens': 100},
      });
      final b = BudgetState();
      expect(b.exceeded(cfg), isNull);
      b.steps = 2;
      expect(b.exceeded(cfg), contains('max_steps'));
      b.steps = 0;
      b.noteUsage(80, 30, cfg);
      expect(b.exceeded(cfg), contains('max_tokens'));
    });

    test('cost accounting', () {
      final cfg = Config.fromDict({
        'budget': {
          'max_steps': 99,
          'max_cost': 0.01,
          'cost_per_1k_input': 0.001,
          'cost_per_1k_output': 0.002,
        },
      });
      final b = BudgetState();
      b.noteUsage(5000, 2500, cfg); // 0.005 + 0.005 = 0.01
      expect(b.exceeded(cfg), contains('max_cost'));
    });

    test('max seconds', () {
      final cfg = Config.fromDict({
        'budget': {'max_steps': 99, 'max_seconds': 0.0},
      });
      expect(BudgetState().exceeded(cfg), contains('max_seconds'));
    });
  });
}
