// Session loop: chat & job modes, candidates injection, meta capabilities,
// finish validation (P0-3), concurrency guard (P0-4), policy gating, budget
// grace, interruption, compaction wiring.
//
// SKIPPED: Python's TestAsyncGuard.test_sync_api_inside_event_loop_raises
// has no Dart equivalent — this port exposes a single async API surface
// (send/runJob/resume/invoke), never a sync wrapper around an event loop,
// so there is no "sync call inside a running loop" failure mode to test.
import 'dart:async';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

Registry echoRegistry() {
  final reg = Registry();
  reg.register(
    capabilityDict('demo.echo',
        description: 'Echo the text back.',
        properties: {
          'text': {'type': 'string'},
        },
        required: ['text'],
        embeddingText: 'echo repeat say オウム返し'),
    handler: (Map<String, Object?> args) => echoHandlerText(args['text'] as String? ?? ''),
  );
  return reg;
}

PolicyEngine allowAllPolicy() => PolicyEngine(defaultDecision: 'allow');

void main() {
  group('ChatMode', () {
    test('default config plain chat', () async {
      final session = Session(ScriptedLLM([const TextStep('こんにちは!ご用件をどうぞ。')]));
      final reply = await session.send('こんにちは');
      expect(reply, equals('こんにちは!ご用件をどうぞ。'));
      final roles = session.conversation.map((m) => m.role).toList();
      expect(roles, equals(['user', 'assistant']));
    });

    test('multi turn', () async {
      final session = Session(ScriptedLLM([const TextStep('reply 1'), const TextStep('reply 2')]));
      expect(await session.send('one'), equals('reply 1'));
      expect(await session.send('two'), equals('reply 2'));
      expect(session.conversation.length, equals(4));
      expect(session.run.state, equals('RUNNING')); // chat mode never auto-completes the run
    });

    test('tool call then answer', () async {
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'hello'})),
        const TextStep('The tool said: echo: hello'),
      ]);
      final session = Session(llm, registry: echoRegistry(), policy: allowAllPolicy());
      final reply = await session.send('please echo hello');
      expect(reply, equals('The tool said: echo: hello'));
      final obs = session.conversation.where((m) => m.role == 'tool').toList();
      expect(obs.length, equals(1));
      expect(obs[0].content, equals('echo: hello'));
      expect(obs[0].name, equals('demo.echo'));
      expect(obs[0].toolCallId, isNotNull);
      expect(obs[0].toolCallId, isNotEmpty);
    });

    test('meta capabilities always present', () async {
      final session = Session(ScriptedLLM([const TextStep('ok')]));
      expect(session.registry.contains('meta.tool.find'), isTrue);
      expect(session.registry.contains('meta.artifact.peek'), isTrue);
      expect(session.registry.contains('meta.history.search'), isTrue);
    });

    test('kernel carries pinned meta specs', () async {
      final llm = ScriptedLLM([CallbackStep((messages, tools) => 'ok')]);
      final session = Session(llm, kernel: 'You are a helper.');
      await session.send('hi');
      final kernel = (llm.requests[0]['messages'] as List<Message>)[0];
      expect(kernel.role, equals('system'));
      expect(kernel.content.toString(), contains('You are a helper.'));
      expect(kernel.content.toString(), contains('### meta.tool.find@1'));
      expect(kernel.content.toString(), contains('### meta.artifact.peek@1'));
    });

    test('candidates injected from user message', () async {
      Object check(List<Message> messages, List<Map<String, Object?>>? tools) {
        final joined = messages.map((m) => m.content.toString()).join('\n');
        // Native schemas are sent, so the candidate card dedupes down to
        // just the signature (P0-5) instead of repeating the full card.
        expect(joined, contains('[Tool candidates'));
        expect(joined, contains('demo.echo('));
        final toolNames = (tools ?? []).map((t) => (t['function'] as Map)['name']).toList();
        // native schema names are provider-safe encoded (dots -> "__")
        expect(toolNames, contains('demo__echo'));
        expect(toolNames, contains('meta__tool__find'));
        return 'saw candidates';
      }

      final session = Session(ScriptedLLM([CallbackStep(check)]), registry: echoRegistry());
      expect(await session.send('echo repeat this'), equals('saw candidates'));
    });

    test('find_tools activates results', () async {
      final reg = echoRegistry();

      Object step2(List<Message> messages, List<Map<String, Object?>>? tools) {
        final names = (tools ?? []).map((t) => (t['function'] as Map)['name']).toList();
        expect(names, contains('demo__echo')); // activated by find even without candidates
        return ScriptedLLM.call('demo.echo', arguments: {'text': 'via find_tools'});
      }

      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('meta.tool.find', arguments: {'query': 'オウム返し echo'})),
        CallbackStep(step2),
        const TextStep('done'),
      ]);
      final cfg = Config.fromMap({
        'discovery': {'query_sources': <String>[]},
      }); // kill layer 2
      final session = Session(llm, registry: reg, config: cfg, policy: allowAllPolicy());
      expect(await session.send('noise'), equals('done'));
      final findObs =
          session.conversation.firstWhere((m) => m.role == 'tool' && m.name == 'meta.tool.find');
      expect(findObs.content.toString(), contains('demo.echo'));
    });
  });

  group('JobMode', () {
    Config jobConfig({int maxSteps = 50}) => Config.fromMap({
          'mode': 'job',
          'budget': {'max_steps': maxSteps},
        });

    test('finish ends job with result', () async {
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'working'})),
        DecisionStep(ScriptedLLM.finish({'status': 'ok', 'count': 3})),
      ]);
      final session =
          Session(llm, registry: echoRegistry(), config: jobConfig(), policy: allowAllPolicy());
      final result = await session.runJob('do the thing');
      expect(result, equals({'status': 'ok', 'count': 3}));
      expect(session.run.state, equals('COMPLETED'));
    });

    test('finish combined with calls is rejected', () async {
      final mixed = Decision(
        text: '',
        calls: [ToolCall(name: 'demo.echo', arguments: {'text': 'x'})],
        finish: true,
        result: 'premature',
      );
      final llm = ScriptedLLM([
        DecisionStep(mixed),
        DecisionStep(ScriptedLLM.finish('actually done')),
      ]);
      final session =
          Session(llm, registry: echoRegistry(), config: jobConfig(), policy: allowAllPolicy());
      final result = await session.runJob('do the thing');
      expect(result, equals('actually done'));
      final rejected = session.conversation
          .where((m) => m.role == 'tool' && m.content.toString().contains('Rejected'))
          .toList();
      expect(rejected, isNotEmpty); // the mixed decision produced a rejection observation, not an execution
    });

    test('text only turn gets nudged', () async {
      final llm = ScriptedLLM([
        const TextStep('just thinking out loud'),
        DecisionStep(ScriptedLLM.finish('finished')),
      ]);
      final session = Session(llm, config: jobConfig());
      expect(await session.runJob('task'), equals('finished'));
      final notices = session.conversation
          .where((m) => m.role == 'system' && m.content.toString().contains('finish(result)'))
          .toList();
      expect(notices, isNotEmpty);
    });

    test('budget grace turn then stop', () async {
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'a'})),
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'b'})),
        const TextStep('final wrap-up summary'),
      ]);
      final session = Session(llm,
          registry: echoRegistry(), config: jobConfig(maxSteps: 2), policy: allowAllPolicy());
      final result = await session.runJob('loop forever');
      expect(result, equals('final wrap-up summary'));
      expect(
        session.conversation
            .any((m) => m.role == 'system' && m.content.toString().contains('Budget exceeded')),
        isTrue,
      );
    });

    test('idle limit returns text', () async {
      final cfg = Config.fromMap({
        'mode': 'job',
        'limits': {'max_idle_turns': 1},
      });
      final llm = ScriptedLLM([
        const TextStep('thinking...'),
        const TextStep('still thinking, giving my answer'),
      ]);
      final session = Session(llm, config: cfg);
      expect(await session.runJob('task'), equals('still thinking, giving my answer'));
    });
  });

  group('Interruption', () {
    test('interrupt stops loop', () async {
      final llm = ScriptedLLM([const TextStep('never reached')]);
      final session = Session(llm);
      session.interrupt();
      expect(await session.send('hi'), equals('[interrupted]'));
      expect(llm.requests, isEmpty); // stopped before calling the model
    });
  });

  group('PolicyGating', () {
    test('deny blocks execution without running handler', () async {
      final executed = <bool>[];
      Object? dangerous(Map<String, Object?> args) {
        executed.add(true);
        return 'boom';
      }

      final reg = Registry();
      reg.register(capabilityDict('demo.rm_rf', effects: [('external', '*')]), handler: dangerous);

      final policy = PolicyEngine(defaultDecision: 'deny');
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.rm_rf')),
        const TextStep('I could not run it.'),
      ]);
      final session = Session(llm, registry: reg, policy: policy);
      final reply = await session.send('delete everything');
      expect(reply, equals('I could not run it.'));
      expect(executed, isEmpty);
      final blocked = session.conversation.where((m) => m.role == 'tool').toList();
      expect(blocked, isNotEmpty);
      expect(blocked[0].content.toString(), contains('Denied by policy'));
    });

    test('require_approval pauses the run', () async {
      final reg = Registry();
      reg.register(capabilityDict('demo.rm_rf', effects: [('external', '*')]),
          handler: (Map<String, Object?> args) => 'boom');
      final policy = PolicyEngine(defaultDecision: 'require_approval');
      final llm = ScriptedLLM([DecisionStep(ScriptedLLM.call('demo.rm_rf'))]);
      final session = Session(llm, registry: reg, policy: policy);
      final result = await session.send('delete everything');
      expect(session.run.state, equals('WAITING_FOR_APPROVAL'));
      expect(result, isA<ApprovalRequest>());
      expect((result as ApprovalRequest).reason, isNotEmpty);
    });
  });

  group('ConcurrencyGuard', () {
    test('second concurrent call raises', () async {
      // The model decision step happens synchronously up to the first
      // await, so the only way a second send() can race the first is
      // while a tool call is genuinely in flight (an async handler
      // awaiting something). Use that as the yield point.
      final started = Completer<void>();
      final release = Completer<void>();

      Future<String> slowTool(Map<String, Object?> args) async {
        started.complete();
        await release.future;
        return 'done';
      }

      final reg = Registry();
      reg.register(capabilityDict('demo.slow'), handler: slowTool);
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.slow')),
        const TextStep('finished'),
      ]);
      final session = Session(llm, registry: reg, policy: allowAllPolicy());

      final task = session.send('go');
      await started.future;
      await expectLater(session.send('again'), throwsA(isA<ConcurrencyError>()));
      release.complete();
      expect(await task, equals('finished'));
    });
  });

  group('CompactionWiring', () {
    test('session folds overflow into working state', () async {
      final summarizer = ScriptedLLM(
        [
          for (var i = 0; i < 10; i++)
            const TextStep(
                '{"new_facts": ["topic A was discussed"], "new_decisions": [], "next_actions": []}'),
        ],
        strict: false,
      );
      final cfg = Config.fromMap({
        'projection': {'window_tokens': 700},
      });
      final llm = ScriptedLLM([
        for (var i = 0; i < 6; i++) TextStep('reply $i: ${'filler words here ' * 40}'),
      ]);
      final session = Session(llm, config: cfg, summarizer: summarizer);
      for (var i = 0; i < 6; i++) {
        await session.send('question $i');
      }
      expect(session.workingState.confirmedFacts, isNotEmpty,
          reason: 'overflow should have been folded into working_state');
      expect(summarizer.requests, isNotEmpty, reason: 'the summarizer LLM should have been called');
      final prompt = (summarizer.requests[0]['messages'] as List<Message>)[0].content.toString();
      expect(prompt, contains('JSON'));
    });

    test('compaction model none uses deterministic fold', () async {
      final cfg = Config.fromMap({
        'projection': {'window_tokens': 700},
        'compaction': {'model': 'none'},
      });
      final llm = ScriptedLLM([
        for (var i = 0; i < 6; i++) TextStep('reply $i: ${'filler words here ' * 40}'),
      ]);
      final session = Session(llm, config: cfg);
      for (var i = 0; i < 6; i++) {
        await session.send('question $i');
      }
      expect(session.workingState.confirmedFacts, isNotEmpty);
      expect(
        session.workingState.confirmedFacts
            .any((f) => f.contains('verbatim') || f.contains('question 0')),
        isTrue,
      );
    });
  });

  group('BudgetTokens', () {
    test('estimated usage accumulates without provider usage', () async {
      final session = Session(ScriptedLLM([const TextStep('short reply')]));
      await session.send('hello');
      expect(session.budget.steps, equals(1));
      expect(session.budget.promptTokens, greaterThan(0));
      expect(session.budget.completionTokens, greaterThan(0));
    });
  });

  group('AsyncApi', () {
    test('async api', () async {
      final session = Session(ScriptedLLM([const TextStep('async reply')]));
      expect(await session.send('hi'), equals('async reply'));
    });
  });
}
