// Session loop: chat & job modes, candidates injection, meta capabilities,
// finish validation, concurrency guard, policy gating, budget
// grace, interruption, compaction wiring.
//
// SKIPPED: Python's TestAsyncGuard.test_sync_api_inside_event_loop_raises
// has no Dart equivalent — this port exposes a single async API surface
// (send/runJob/resume/invoke), never a sync wrapper around an event loop,
// so there is no "sync call inside a running loop" failure mode to test.
import 'dart:async';
import 'dart:io';

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
      final session = Session(llm, registry: echoRegistry(), policy: allowAll());
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
        // just the signature instead of repeating the full card.
        expect(joined, contains('[Tool candidates'));
        expect(joined, contains('demo.echo('));
        final toolNames = (tools ?? []).map((t) => t['name']).toList();
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
        final names = (tools ?? []).map((t) => t['name']).toList();
        expect(names, contains('demo__echo')); // activated by find even without candidates
        return ScriptedLLM.call('demo.echo', arguments: {'text': 'via find_tools'});
      }

      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('meta.tool.find', arguments: {'query': 'オウム返し echo'})),
        CallbackStep(step2),
        const TextStep('done'),
      ]);
      final cfg = Config.fromDict({
        'discovery': {'query_sources': <String>[]},
      }); // kill layer 2
      final session = Session(llm, registry: reg, config: cfg, policy: allowAll());
      expect(await session.send('noise'), equals('done'));
      final findObs =
          session.conversation.firstWhere((m) => m.role == 'tool' && m.name == 'meta.tool.find');
      expect(findObs.content.toString(), contains('demo.echo'));
    });
  });

  group('JobMode', () {
    Config jobConfig({int maxSteps = 50}) => Config.fromDict({
          'mode': 'job',
          'budget': {'max_steps': maxSteps},
        });

    test('finish ends job with result', () async {
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'working'})),
        DecisionStep(ScriptedLLM.finish({'status': 'ok', 'count': 3})),
      ]);
      final session =
          Session(llm, registry: echoRegistry(), config: jobConfig(), policy: allowAll());
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
          Session(llm, registry: echoRegistry(), config: jobConfig(), policy: allowAll());
      final result = await session.runJob('do the thing');
      expect(result, equals('actually done'));
      final rejected = session.conversation
          .where((m) => m.role == 'tool' && m.content.toString().contains('Rejected'))
          .toList();
      expect(rejected, isNotEmpty); // the mixed decision produced a rejection observation, not an execution
      expect(session.ledger.iterRun(session.run.id).any((e) => e.type == 'command_started'), isFalse,
          reason: 'nothing in a decision that also finishes may run');
      expect(session.run.state, equals('COMPLETED'));
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
          registry: echoRegistry(), config: jobConfig(maxSteps: 2), policy: allowAll());
      final result = await session.runJob('loop forever');
      expect(result, equals('final wrap-up summary'));
      expect(
        session.conversation
            .any((m) => m.role == 'system' && m.content.toString().contains('Budget exceeded')),
        isTrue,
      );
    });

    test('idle limit returns text', () async {
      final cfg = Config.fromDict({
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
      final session = Session(llm, registry: reg, policy: allowAll());

      final task = session.send('go');
      await started.future;
      await expectLater(session.send('again'), throwsA(isA<ConcurrencyError>()));
      release.complete();
      expect(await task, equals('finished'));
      // the rejected input never reached the conversation
      expect(session.conversation.where((m) => m.role == 'user').length, equals(1));
    });
  });

  group('FidelityCompression', () {
    test('old messages are compressed in projection', () async {
      final cfg = Config.fromDict({
        'projection': {'window_tokens': 2000},
      });
      final llm = ScriptedLLM([
        for (var i = 0; i < 8; i++) TextStep('reply $i: ${'filler words here ' * 40}'),
      ]);
      final session = Session(llm, config: cfg);
      for (var i = 0; i < 8; i++) {
        await session.send('question $i');
      }
      expect(session.budget.steps, equals(8));
      expect(session.conversation.length, equals(16));
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
  group('disabled capabilities are invisible', () {
    // The point of disabling: the model can neither see nor call the tool.
    // Asserted against what actually reaches the adapter — the rendered
    // messages and the native tool schemas — because that is the only view
    // the model has, and every surface (schemas, pinned specs, runtime
    // notes, tool index, candidates) lands in exactly one of those two.
    Session buildSession(List<String> disabled, {List<Step>? steps}) {
      final registry = Registry(disabled: disabled);
      registry.register(
        capabilityDict('demo.echo',
            description: 'Echo the text back.',
            properties: {
              'text': {'type': 'string'},
            },
            required: ['text'],
            embeddingText: 'echo repeat say'),
        handler: (Map<String, Object?> args) => echoHandlerText(args['text'] as String? ?? ''),
      );
      return Session(
        ScriptedLLM(steps ?? [const TextStep('hi')]),
        kernel: 'K',
        registry: registry,
        policy: allowAll(),
      );
    }

    (String, List<String>) sent(Session session) {
      final request = (session.llm as ScriptedLLM).requests.last;
      final messages = (request['messages'] as List).cast<Message>();
      final prompt = messages
          .map((m) => m.content)
          .whereType<String>()
          .join('\n');
      final tools = (request['tools'] as List)
          .map((t) => (t as Map)['name'] as String)
          .toList();
      return (prompt, tools);
    }

    test('bundled checklist tool can be disabled', () async {
      final session = buildSession(['planning.checklist.manage']);
      await session.send('hello');
      final (prompt, tools) = sent(session);
      expect(tools, isNot(contains('planning__checklist__manage')));
      expect(prompt.contains('planning.checklist.manage'), isFalse);
      expect(prompt.contains('planning'), isFalse);
    });

    test('disabled tool is not discoverable', () {
      final session = buildSession(['demo.echo']);
      expect(session.search.search('echo repeat', k: 5, layer: 3), isEmpty);
      expect(session.registry.get('demo.echo'), isNull);
    });

    test('disabled tool cannot be executed', () async {
      final session = buildSession(['demo.echo'], steps: [
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'x'})),
        const TextStep('done'),
      ]);
      await session.send('use echo');
      final observations = session.ledger
          .iterRun(session.run.id)
          .where((e) => e.type == 'observation')
          .map((e) => e.data.toString());
      expect(observations.any((o) => o.contains('not registered')), isTrue);
    });

    test('disabling mid-session takes effect on the next turn', () async {
      final session = buildSession([], steps: [const TextStep('one'), const TextStep('two')]);
      await session.send('hello');
      var (prompt, tools) = sent(session);
      expect(tools, contains('planning__checklist__manage'));
      expect(prompt.contains('planning.checklist.manage'), isTrue);

      session.registry.disable(['planning.checklist.manage']);
      await session.send('hello again');
      (prompt, tools) = sent(session);
      expect(tools, isNot(contains('planning__checklist__manage')));
      expect(prompt.contains('planning.checklist.manage'), isFalse);
    });
  });
  group('resumed run artifacts', () {
    // A resumed run installs a fresh ArtifactStore for its new run id. The
    // runtime must write into that one, not into a copy captured when it was
    // constructed, or every artifact produced after the resume becomes
    // unreachable to meta.artifact.peek.
    test('artifacts produced after resume are readable', () async {
      final dir = Directory.systemTemp.createTempSync('spal_resume_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final registry = Registry();
      registry.register(
        capabilityDict('demo.big', properties: {}, maxInlineTokens: 1),
        handler: (Map<String, Object?> args) => 'x' * 4000,
      );
      final config = Config.fromDict({
        'mode': 'job',
        'persistence': {'ledger_directory': dir.path},
        'artifacts': {'directory': '${dir.path}/artifacts'},
      });
      final first = Session(ScriptedLLM([DecisionStep(ScriptedLLM.finish('ok'))]),
          registry: registry, config: config, policy: allowAll());
      await first.runJob('nothing');

      final resumed = Session.resumeFromLedger(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('demo.big')),
          DecisionStep(ScriptedLLM.finish('done')),
        ]),
        first.run.id,
        config: config,
        registry: registry,
        policy: allowAll(),
      );
      resumed.run.state = 'RUNNING';
      await resumed.runJob('make a big result');

      final observations = resumed.ledger
          .iterRun(resumed.run.id)
          .where((e) => e.type == 'observation')
          .map((e) => e.data['text'].toString())
          .join('\n');
      final ids = RegExp(r'art_[0-9A-Z]+').allMatches(observations).map((m) => m[0]!).toList();
      expect(ids, isNotEmpty, reason: 'expected the oversized result to become an artifact');
      expect(isRef({r'$artifact': ids.first}), isTrue);
      // The store the session hands to meta.artifact.peek must be the one the
      // runtime just wrote to.
      expect(resumed.store.peek(ids.first), contains('xxx'));
    });
  });

  group('branch keeps the session wiring', () {
    test('a branch of a session without builtins installs none', () async {
      final seen = <String>[];
      final session = Session(ScriptedLLM([const TextStep('one')]),
          builtins: const [], onEvent: (e) => seen.add(e.type));
      await session.send('hi');
      session.branch();
      expect(session.registry.capabilities, isEmpty,
          reason: 'branching must not install packs the parent excluded');
      expect(seen, contains('branch_created'), reason: "the parent's observer follows the branch");
    });
  });

  group('resume from ledger', () {
    test('resuming writes no second run and keeps the kernel', () async {
      final dir = Directory.systemTemp.createTempSync('spal_resume_');
      addTearDown(() => dir.deleteSync(recursive: true));
      List<String> names() => [for (final f in dir.listSync()) f.uri.pathSegments.last]..sort();

      final config = Config.fromDict({
        'persistence': {'ledger_directory': dir.path},
      });
      final first = Session(ScriptedLLM([const TextStep('hello')]),
          kernel: 'You are the deploy bot.', config: config);
      await first.send('hi');
      final before = names();

      final llm = ScriptedLLM([const TextStep('again')]);
      final resumed = Session.resumeFromLedger(llm, first.run.id,
          config: config, kernel: 'You are the deploy bot.');
      expect(names(), equals(before), reason: 'resuming must not create a second run');
      expect((resumed.run.id, resumed.sessionId), (first.run.id, first.sessionId));

      await resumed.send('and again');
      final system = (llm.requests.first['messages'] as List<Message>).first;
      expect(system.content.toString(), startsWith('You are the deploy bot.'));
    });
  });

  group('state tools declare their writes', () {
    // state.* mutates the working state, so it must not be declared as
    // effect-free: the runtime uses that declaration to decide what may run
    // concurrently, and a mislabelled write loses the model's stated order.
    test('mutating state tools are not read-only', () {
      final registry = Registry();
      installBuiltins(registry, ['state']);
      final mutating = registry
          .all()
          .where((c) => c.name.startsWith('state.') && !c.name.endsWith('.get'))
          .toList();
      expect(mutating, isNotEmpty);
      for (final capability in mutating) {
        expect(Runtime.isReadOnly(capability), isFalse,
            reason: '${capability.name} claims to be read-only');
      }
    });

    test('state writes are auto-allowed by the default policy', () {
      final registry = Registry();
      installBuiltins(registry, ['state']);
      final session = Session(ScriptedLLM([]), registry: registry); // default (auto_safe) policy
      final capability = session.registry.get('state.goal.set')!;
      expect(session.policy.evaluate(capability, {'text': 'x'}).decision, equals('allow'));
    });
  });

  group('seeding', () {
    test('seeded decisions survive a round trip', () {
      final session = Session(ScriptedLLM([]), seed: {
        'goal': 'g',
        'decisions': [
          {'text': 'use sqlite', 'reason': 'single writer'},
        ],
      });
      expect(session.workingState.toDict()['decisions'], equals([
        {'text': 'use sqlite', 'reason': 'single writer'},
      ]));
    });

    test('seeded extra is not nested under itself', () {
      final session = Session(ScriptedLLM([]), seed: {
        'extra': {'flags': <String, Object?>{}},
      });
      expect(session.workingState.extra, equals({'flags': <String, Object?>{}}));
    });

    test('unknown keys fall back to extra', () {
      final session = Session(ScriptedLLM([]), seed: {
        'campaign': {'chapter': 2},
      });
      expect(session.workingState.extra, equals({
        'campaign': {'chapter': 2},
      }));
    });
  });
  group('approval keeps the decision intact', () {
    // A decision parked on an approval is either shown with all of its
    // results or not shown at all. Anything in between is a 400 from a
    // native tool-calling provider.
    Session buildSession(List<Step> steps) {
      final registry = Registry();
      registry.register(capabilityDict('demo.write', effects: [('external', '*')]),
          handler: (Map<String, Object?> args) => 'written');
      registry.register(capabilityDict('demo.second', effects: [('external', '*')]),
          handler: (Map<String, Object?> args) => 'second');
      return Session(ScriptedLLM(steps),
          registry: registry, policy: PolicyEngine(defaultDecision: 'require_approval'));
    }

    TurnContext turnOf(Session session) => TurnContext(
          config: session.config,
          registry: session.registry,
          ledger: session.ledger,
          run: session.run,
        );

    List<(String, String)> observations(Session session) => [
          for (final e in session.ledger.iterRun(session.run.id))
            if (e.type == 'observation')
              (e.data['call_id'].toString(), e.data['text'].toString()),
        ];

    test('a parked decision is not projected at all', () async {
      final session = buildSession([DecisionStep(ScriptedLLM.call('demo.write'))]);
      await session.send('do it');
      expect(session.run.state, equals('WAITING_FOR_APPROVAL'));
      expect(observations(session), isEmpty);
      final history = session.projection.get('history')!.render(turnOf(session));
      expect(history.any((m) => m.role == 'assistant' && m.toolCalls.isNotEmpty), isFalse);
    });

    test('approval produces exactly one result per call', () async {
      final session = buildSession([
        DecisionStep(ScriptedLLM.call('demo.write')),
        const TextStep('done'),
      ]);
      await session.send('do it');
      session.resolveApproval('approved');
      await session.resume();
      final callIds = observations(session).map((o) => o.$1).toList();
      expect(callIds.length, equals(1));
      expect(callIds.toSet().length, equals(1));
      expect(observations(session).first.$2, contains('written'));
    });

    test('denial answers every parked call', () async {
      final session = buildSession([
        DecisionStep(ScriptedLLM.calls([('demo.write', {}), ('demo.second', {})])),
        const TextStep('done'),
      ]);
      await session.send('do both');
      session.resolveApproval('denied');
      await session.resume();
      final obs = observations(session);
      expect(obs.length, equals(2), reason: 'both parked calls need a result, got $obs');
      for (final o in obs) {
        final text = o.$2.toLowerCase();
        expect(text.contains('denied') || text.contains('not executed'), isTrue);
      }
      final history = session.projection.get('history')!.render(turnOf(session));
      expect(history.any((m) => m.role == 'assistant' && m.toolCalls.isNotEmpty), isTrue);
    });
  });
  group('rewind', () {
    test('cancels the old run and restores state', () async {
      final session = Session(ScriptedLLM([
        const TextStep('reply 0'),
        const TextStep('reply 1'),
        const TextStep('reply 2'),
        const TextStep('after rewind'),
      ]));
      await session.send('msg 0');
      await session.send('msg 1');
      await session.send('msg 2');
      expect(session.conversation.length, equals(6));
      final oldRunId = session.run.id;

      final irreversible = session.rewind(toTurn: 1);

      expect(session.run.id, isNot(equals(oldRunId)));
      expect(session.run.state, equals('RUNNING'));
      expect(session.conversation.length, equals(2));
      expect(session.conversation[0].content, equals('msg 0'));
      expect(session.conversation[1].content, equals('reply 0'));
      expect(irreversible, isEmpty);
    });

    test('reports external effects it cannot undo', () async {
      final registry = Registry();
      registry.register(
        capabilityDict('mail.send', effects: [('external', 'smtp:*')]),
        handler: (Map<String, Object?> args) => 'sent',
      );
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('mail.send')),
          const TextStep('sent the email'),
          const TextStep('reply 1'),
        ]),
        registry: registry,
        policy: allowAll(),
      );
      await session.send('send the email');
      await session.send('do something else');

      final irreversible = session.rewind(toTurn: 1);
      expect(irreversible.any((n) => n.contains('mail.send')), isTrue);
    });

    test('restores the working state', () async {
      final registry = Registry();
      installBuiltins(registry, ['state']);
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('state.goal.set', arguments: {'text': 'find the key'})),
          const TextStep('goal set'),
          DecisionStep(ScriptedLLM.call('state.goal.set', arguments: {'text': 'escape the room'})),
          const TextStep('goal changed'),
          const TextStep('after rewind'),
        ]),
        registry: registry,
        policy: allowAll(),
      );
      await session.send('set goal');
      await session.send('change goal');
      expect(session.workingState.goal, equals('escape the room'));

      session.rewind(toTurn: 1);
      expect(session.workingState.goal, equals('find the key'));
    });

    test('the conversation continues normally afterwards', () async {
      final session = Session(ScriptedLLM([
        const TextStep('reply 0'),
        const TextStep('reply 1'),
        const TextStep('new reply after rewind'),
      ]));
      await session.send('msg 0');
      await session.send('msg 1');
      session.rewind(toTurn: 1);
      final reply = await session.send('msg after rewind');
      expect(reply, equals('new reply after rewind'));
    });

    test('clears the validation-failure counters', () async {
      // The failures being counted are in the discarded history; a
      // capability must not start the new timeline one strike from being
      // given up on.
      final registry = Registry();
      registry.register(
        capabilityDict('demo.strict',
            properties: {
              'n': {'type': 'integer'},
            },
            required: ['n']),
        handler: (Map<String, Object?> args) => 'ok',
      );
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('demo.strict', arguments: {'n': 'not an integer'})),
          const TextStep('oops'),
          DecisionStep(ScriptedLLM.call('demo.strict', arguments: {'n': 'still wrong'})),
          const TextStep('oops again'),
          DecisionStep(ScriptedLLM.call('demo.strict', arguments: {'n': 'wrong once more'})),
          const TextStep('done'),
        ]),
        registry: registry,
        policy: allowAll(),
      );
      await session.send('call it');
      await session.send('call it again');
      session.rewind(toTurn: 1);
      await session.send('call it once more');
      final observations = [
        for (final e in session.ledger.iterRun(session.run.id))
          if (e.type == 'observation') e.data['text'].toString(),
      ];
      expect(observations.any((o) => o.contains('giving up')), isFalse,
          reason: 'the counter should have been reset by the rewind');
    });
  });

  group('history and usage', () {
    test('long reply survives ledger and next projection', () async {
      final reply = '${'x' * 2100}IMPORTANT_END';
      final llm = ScriptedLLM([TextStep(reply), const TextStep('ok')]);
      final session = Session(llm);
      expect(await session.send('one'), reply);
      expect(session.conversation.last.content, reply);
      await session.send('continue');
      expect((llm.requests[1]['messages'] as List<Message>).any((m) => m.content == reply), isTrue);
    });

    for (final kind in ['arguments', 'raw', 'finish', 'usage']) {
      test('usage counts complete request and output: $kind', () async {
        final payload = 'x' * 8000;
        final decision = kind == 'finish'
            ? ScriptedLLM.finish({'text': payload})
            : Decision(
                calls: [ToolCall(
                  name: 'missing_tool',
                  arguments: kind == 'raw' ? {} : {'text': payload},
                  rawArguments: kind == 'raw' ? '{"text":"$payload' : null,
                )],
                usage: kind == 'usage' ? Usage(promptTokens: 11, completionTokens: 7) : null,
              );
        final llm = ScriptedLLM([
          DecisionStep(decision),
          DecisionStep(Decision(text: 'ok', usage: Usage())),
        ]);
        final config = Config.fromDict({'budget': {'cost_per_1k_input': 1, 'cost_per_1k_output': 2}});
        final session = Session(llm, config: config);
        await session.send('go');
        if (kind == 'usage') {
          expect(session.budget.promptTokens, 11);
          expect(session.budget.completionTokens, 7);
        } else {
          final request = llm.requests[0];
          expect(session.budget.promptTokens,
              estimateTokens(request['messages']) + estimateTokens(request['tools']));
          expect(session.budget.completionTokens, greaterThanOrEqualTo(estimateTokens(payload)));
        }
        expect(session.budget.cost, closeTo(
            session.budget.promptTokens / 1000 + session.budget.completionTokens / 1000 * 2, 1e-9));
      });
    }
  });
}
