// Standard agent features: ask (pause for the user), loop guard, result
// schema, observers, compaction, skills, toolkits.
import 'dart:io';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:state_projection_loop/native.dart';
import 'package:test/test.dart';

import '../util.dart';


List<(String, String)> observations(Session s) => [
      for (final e in s.ledger.iterRun(s.run.id))
        if (e.type == 'observation') (e.data['name'].toString(), e.data['text'].toString()),
    ];

void main() {
  group('ask pack', () {
    test('pauses the run, survives a snapshot, resumes with the answer as the result', () async {
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('meta.user.ask', arguments: {'question': 'Which colour?'})),
          const TextStep('you said blue'),
        ]),
        builtins: ['meta', 'ask'],
        policy: allowAll(),
      );
      final paused = await session.send('pick a colour for me');
      expect(paused, isA<PendingQuestion>());
      expect(session.run.state, 'WAITING_FOR_USER');
      expect(observations(session), isEmpty, reason: 'nothing recorded until the user answers');

      final restored = Run.fromSnapshotState(session.run.id, session.ledger, session.run.toSnapshotState());
      expect(restored.pendingQuestion?.text, 'Which colour?');

      session.answer('blue');
      expect(session.run.state, 'RUNNING');
      expect(await session.resume(), 'you said blue');
      expect(observations(session).single, ('meta.user.ask', 'blue'));
      final types = session.ledger.iterRun(session.run.id).map((e) => e.type).toSet();
      expect(types, containsAll(['question_asked', 'question_answered']));
      expect(session.run.commands.values.single.outcome, 'ok');
    });

    test('calls parked behind a question still face the policy', () async {
      final sent = <bool>[];
      final registry = Registry();
      registry.register(capabilityDict('mail.message.send', effects: [('external', 'smtp:*')]),
          handler: (args) {
        sent.add(true);
        return 'sent';
      });
      final policy = PolicyEngine(defaultDecision: 'allow')
        ..addRule('admin', Rule(decision: 'deny', capabilityPattern: 'mail.*'));
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.calls([
            ('meta.user.ask', {'question': 'Send it?'}),
            ('mail.message.send', {}),
          ])),
          const TextStep('ok'),
        ]),
        registry: registry,
        builtins: ['ask'],
        policy: policy,
      );
      await session.send('mail the report');
      session.answer('yes');
      await session.resume();
      expect(sent, isEmpty, reason: 'answering a question must not wave the next call past the policy');
      expect(observations(session).firstWhere((o) => o.$1 == 'mail.message.send').$2,
          startsWith('Denied by policy (admin): '));
    });

    test('the default policy lets the model ask without approval', () {
      final session = Session(ScriptedLLM([]), builtins: ['ask']);
      final ask = session.registry.get('meta.user.ask')!;
      expect(session.policy.evaluate(ask, {'question': 'q'}).decision, 'allow');
    });
  });

  group('loop guard', () {
    Registry reg() {
      final r = Registry();
      r.register(capabilityDict('demo.fail', properties: {'x': {'type': 'integer'}}),
          handler: (args) => throw StateError('boom ${DateTime.now().millisecondsSinceEpoch}'));
      r.register(capabilityDict('demo.same', properties: {'x': {'type': 'integer'}}, effects: [('write', 'w:*')]),
          handler: (args) => 'same');
      r.register(capabilityDict('demo.poll', properties: {}, retrySafety: 'pure', effects: [('read', 'r:*')]),
          handler: (args) => 'pending');
      return r;
    }

    Future<Session> drive(String tool, int times) async {
      final session = Session(
        ScriptedLLM([
          for (var i = 0; i < times; i++) DecisionStep(ScriptedLLM.call(tool, arguments: {'x': 1})),
          const TextStep('done'),
        ]),
        registry: reg(),
        policy: allowAll(),
        builtins: [],
      );
      await session.send('go');
      return session;
    }

    test('an identically failing call is refused after max_repeats', () async {
      final session = await drive('demo.fail', 4);
      final texts = observations(session).map((o) => o.$2).toList();
      expect(texts.take(3).every((t) => t.contains('boom')), isTrue);
      expect(texts[3], contains('Loop guard'));
    });

    test('an identical non-read result is refused, a pure read may be polled', () async {
      final same = await drive('demo.same', 4);
      expect(observations(same).last.$2, contains('Loop guard'));
      final poll = await drive('demo.poll', 5);
      expect(observations(poll).every((o) => o.$2 == 'pending'), isTrue);
    });

    test('max_repeats 0 disables the guard', () async {
      final session = Session(
        ScriptedLLM([for (var i = 0; i < 5; i++) DecisionStep(ScriptedLLM.call('demo.same', arguments: {'x': 1})), const TextStep('done')]),
        registry: reg(),
        policy: allowAll(),
        builtins: [],
        config: Config.fromDict({'limits': {'max_repeats': 0}}),
      );
      await session.send('go');
      expect(observations(session).every((o) => o.$2 == 'same'), isTrue);
    });
  });

  group('result schema', () {
    test('a finish result that fails the schema is bounced back', () async {
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.finish('oops')),
          DecisionStep(ScriptedLLM.finish({'answer': 42})),
        ]),
        config: Config.fromDict({
          'mode': 'job',
          'result_schema': {'type': 'object', 'required': ['answer']},
        }),
        policy: allowAll(),
      );
      final result = await session.runJob('compute');
      expect(result, {'answer': 42});
      expect(session.run.state, 'COMPLETED');
      final notices = [for (final e in session.ledger.iterRun(session.run.id)) if (e.type == 'notice') e.data['text']];
      expect(notices.single, contains('finish(result) rejected'));
    });
  });

  group('observers', () {
    test('every ledger append reaches the observer, and a throwing observer is harmless', () async {
      final seen = <String>[];
      final session = Session(
        ScriptedLLM([const TextStep('hi')]),
        onEvent: (e) {
          seen.add(e.type);
          throw StateError('observer bug');
        },
        policy: allowAll(),
      );
      expect(await session.send('hello'), 'hi');
      expect(seen, containsAll(['run_state_changed', 'user_input', 'projection_compiled', 'model_response']));
    });
  });

  group('compaction', () {
    test('folds history older than the full window into the working state', () async {
      var foldPrompts = 0;
      final session = Session(
        ScriptedLLM([
          for (var i = 1; i <= 12; i++) TextStep('r$i'),
          CallbackStep((messages, tools) {
            expect(messages.first.content, foldInstructions);
            expect(tools, isNull);
            foldPrompts++;
            return '```json\n{"facts_add": ["user likes blue"], "next_actions": ["ship"]}\n```';
          }),
          const TextStep('r13'),
        ]),
        config: Config.fromDict({'compaction': {'trigger_ratio': 0.01}}),
        policy: allowAll(),
      );
      for (var i = 1; i <= 12; i++) {
        await session.send('m$i');
      }
      expect(foldPrompts, 0, reason: 'no fold until the verbatim point steps (four times fullWindow)');
      expect(await session.send('m13'), 'r13');
      expect(foldPrompts, 1);
      expect(session.workingState.confirmedFacts, ['user likes blue']);
      expect(session.workingState.nextActions, ['ship']);
      expect(session.workingState.foldedSequence, greaterThan(0));
      final folded = session.ledger.iterRun(session.run.id).where((e) => e.type == 'state_folded').single;
      expect((folded.data['before'] as Map)['confirmed_facts'], isEmpty);
    });

    test('trigger counts the reserved output the render budgets', () async {
      // window 2000, ratio 0.75: the render shrinks messages to fit under the
      // 976 left after the 1024 reserved output, so a ratio of the whole
      // window (1500) could never be reached and the fold was unreachable.
      final session = Session(
        ScriptedLLM([
          for (var i = 1; i <= 12; i++) TextStep('r$i'),
          CallbackStep((messages, tools) => '{"facts_add": ["seen"]}'),
          const TextStep('r13'),
        ]),
        config: Config.fromDict({
          'projection': {'window_tokens': 2000},
          'compaction': {'trigger_ratio': 0.75},
        }),
        policy: allowAll(),
      );
      for (var i = 1; i <= 13; i++) {
        await session.send('m$i ${'word ' * 120}');
      }
      expect(session.workingState.confirmedFacts, ['seen']);
    });

    test('an invalid delta is skipped and logged, never merged', () async {
      final session = Session(
        ScriptedLLM([
          for (var i = 1; i <= 12; i++) TextStep('r$i'),
          const TextStep('{"facts_add": "not a list"}'),
          const TextStep('r13'),
        ]),
        config: Config.fromDict({'compaction': {'trigger_ratio': 0.01}}),
        policy: allowAll(),
      );
      for (var i = 1; i <= 13; i++) {
        await session.send('m$i');
      }
      expect(session.workingState.confirmedFacts, isEmpty);
      final notices = [for (final e in session.ledger.iterRun(session.run.id)) if (e.type == 'notice') e.data['text'].toString()];
      expect(notices.single, contains('compaction skipped'));
    });
  });

  group('skills', () {
    test('a skill is a capability the model discovers and loads on demand', () async {
      final session = Session(ScriptedLLM([]), policy: allowAll());
      session.registry.register(skillCapability('deploy', 'Step 1: build. Step 2: tag.', summary: 'How to deploy'));
      expect(session.registry.categories()['skill'], (1, 0));
      expect(await session.invoke('skill.deploy.load'), 'Step 1: build. Step 2: tag.');
      expect(session.search.search('how do I deploy').first.tool.name, 'skill.deploy.load');
    });
  });

  group('toolkits', () {
    test('filesystem tools are confined to the root and shell runs there', () async {
      final dir = Directory.systemTemp.createTempSync('spal_toolkit');
      addTearDown(() => dir.deleteSync(recursive: true));
      final registry = Registry();
      installToolkits(registry, dir);
      final session = Session(ScriptedLLM([]), registry: registry, policy: allowAll(), builtins: []);
      expect(await session.invoke('filesystem.file.write', {'path': 'a/b.txt', 'content': 'hello'}), contains('wrote 5'));
      expect(await session.invoke('filesystem.file.read', {'path': 'a/b.txt'}), 'hello');
      expect(await session.invoke('filesystem.file.list', {}), ['a/b.txt']);
      await expectLater(session.invoke('filesystem.file.read', {'path': '../outside.txt'}), throwsStateError);
      final out = (await session.invoke('shell.command.run', {'command': 'echo hi'})).toString();
      expect(out, startsWith('exit=0'));
      expect(out, contains('hi'));
    });

    test('shell can be left out', () {
      final registry = Registry();
      installToolkits(registry, Directory.systemTemp, shell: false);
      expect(registry.contains('shell.command.run'), isFalse);
      expect(registry.contains('filesystem.file.read'), isTrue);
    });
  });
}
