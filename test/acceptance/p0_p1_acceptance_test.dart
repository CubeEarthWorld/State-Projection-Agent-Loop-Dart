// Acceptance tests for the Codex-review-driven redesign (P0-1..P0-6,
// P1-1..P1-3). Each test group corresponds to one item of the redesign's
// "minimum acceptance test" checklist:
//
// 01. execution order      -- write -> read executes in that order
// 02. completion state     -- finish() combined with side-effecting calls is rejected
// 03. idempotency          -- a non-idempotent timeout is OUTCOME_UNKNOWN, never auto-retried
// 04. concurrency          -- concurrent input to one session never interleaves state
// 05. artifact references  -- a literal string is never misread as a reference
// 06. budget               -- total send size including tool schemas stays inside the window
// 07. approval             -- WAITING_FOR_APPROVAL survives a simulated process restart
// 08. policy               -- a higher layer's deny cannot be relaxed by a lower one
// 09. reproducibility      -- Run state is fully recoverable from Events + Snapshot
// 10. rewind               -- branching never deletes or mutates past events
// 11. external effects     -- rewinding surfaces effects it cannot undo
// 12. logging              -- each command's proposal -> validation -> authorization ->
//                             start -> completion/unknown is traceable in the ledger
import 'dart:async';
import 'dart:io';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

void main() {
  group('01_ExecutionOrder', () {
    test('write then read executes in stated order', () async {
      final log = <String>[];
      final reg = Registry();
      reg.register(
        capabilityDict('fs.write',
            properties: {
              'v': {'type': 'string'},
            },
            required: ['v'],
            effects: [('write', 'workspace:*')]),
        handler: (Map<String, Object?> args) {
          log.add('write:${args['v']}');
          return 'ok';
        },
      );
      reg.register(
        capabilityDict('fs.read', effects: [('read', 'workspace:*')]),
        handler: (Map<String, Object?> args) {
          log.add('read');
          return 'ok';
        },
      );

      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.calls([
          ('fs.write', {'v': 'x'}),
          ('fs.read', <String, Object?>{}),
        ])),
        DecisionStep(ScriptedLLM.finish('done')),
      ]);
      final session = Session(llm,
          registry: reg,
          config: Config.fromMap({'mode': 'job'}),
          policy: PolicyEngine(defaultDecision: 'allow'));
      await session.runJob('write then read');
      expect(log, equals(['write:x', 'read']), reason: 'write must complete before read starts');
    });
  });

  group('02_CompletionState', () {
    test('finish with side effecting calls is rejected and nothing runs', () async {
      final executed = <bool>[];
      final reg = Registry();
      reg.register(capabilityDict('fs.delete', effects: [('write', 'workspace:*')]),
          handler: (Map<String, Object?> args) {
        executed.add(true);
        return 'deleted';
      });

      final mixed = Decision(
        text: '',
        calls: [ToolCall(name: 'fs.delete', arguments: {})],
        finish: true,
        result: 'claiming done',
      );
      final llm = ScriptedLLM([
        DecisionStep(mixed),
        DecisionStep(ScriptedLLM.finish('actually done')),
      ]);
      final session = Session(llm,
          registry: reg,
          config: Config.fromMap({'mode': 'job'}),
          policy: PolicyEngine(defaultDecision: 'allow'));
      final result = await session.runJob('try to sneak a delete in with finish');

      expect(result, equals('actually done'));
      expect(executed, isEmpty, reason: 'the side-effecting call must never run alongside finish()');
      expect(session.run.state, equals('COMPLETED'));
    });
  });

  group('03_Idempotency', () {
    test('timeout on never_retry capability is unknown and not retried', () async {
      var attempts = 0;
      Future<String> chargeCard(Map<String, Object?> args) async {
        attempts += 1;
        await Future.delayed(const Duration(seconds: 1));
        return 'charged';
      }

      final reg = Registry();
      reg.register(
          capabilityDict('billing.charge',
              timeoutS: 0.05,
              retrySafety: 'never_retry',
              effects: [('external', 'payment_gateway:*')]),
          handler: chargeCard);
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('billing.charge')),
        DecisionStep(ScriptedLLM.finish('x')),
      ]);
      final session = Session(llm,
          registry: reg,
          config: Config.fromMap({'mode': 'job'}),
          policy: PolicyEngine(defaultDecision: 'allow'));
      await session.runJob('charge the card');

      expect(attempts, equals(1), reason: 'a never_retry capability must not be retried after a timeout');
      final obs = session.conversation
          .firstWhere((m) => m.role == 'tool' && m.content.toString().contains('UNKNOWN'));
      expect(obs.content.toString(), contains('UNKNOWN'));
    });
  });

  group('04_Concurrency', () {
    test('concurrent input never interleaves', () async {
      final started = Completer<void>();
      final release = Completer<void>();

      Future<String> slow(Map<String, Object?> args) async {
        started.complete();
        await release.future;
        return 'done';
      }

      final reg = Registry();
      reg.register(capabilityDict('demo.slow'), handler: slow);
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.slow')),
        const TextStep('finished'),
      ]);
      final session = Session(llm, registry: reg, policy: PolicyEngine(defaultDecision: 'allow'));

      final task = session.send('go');
      await started.future;
      await expectLater(session.send('interleave me'), throwsA(isA<ConcurrencyError>()));
      release.complete();
      expect(await task, equals('finished'));
      // exactly the one turn's worth of messages made it into the conversation
      expect(session.conversation.where((m) => m.role == 'user').length, equals(1));
    });
  });

  group('05_ArtifactReferences', () {
    test('literal string matching an artifact id is never resolved', () async {
      final reg = Registry();

      String makeBig(Map<String, Object?> args) => 'x' * 5000; // forced into the artifact store
      String echoArg(Map<String, Object?> args) => 'got:${args['data']}';

      reg.register(capabilityDict('demo.make_big', maxInlineTokens: 10), handler: makeBig);
      reg.register(
        capabilityDict('demo.echo_arg', properties: {'data': <String, Object?>{}}, required: ['data']),
        handler: echoArg,
      );

      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.make_big')),
        const TextStep('made it'),
      ]);
      final session = Session(llm, registry: reg, policy: PolicyEngine(defaultDecision: 'allow'));
      await session.send('make something big');
      final obsContent = session.conversation
          .firstWhere((m) => m.role == 'tool' && m.content.toString().startsWith('[art_'))
          .content
          .toString();
      final artifactId = obsContent.substring(obsContent.indexOf('[') + 1).split(' ').first;

      // A tool called with the LITERAL id string (not the structured ref)
      // must receive it as plain text, never the resolved payload.
      final resolved = session.store.resolveArgs({'data': artifactId});
      expect(resolved, equals({'data': artifactId}));
      // Only the structured form resolves.
      final resolvedRef = session.store.resolveArgs({'data': ref(artifactId)});
      expect(resolvedRef, equals({'data': 'x' * 5000}));
    });
  });

  group('06_Budget', () {
    test('total send size including schemas stays inside window', () async {
      final reg = Registry();
      for (var i = 0; i < 30; i++) {
        reg.register(capabilityDict('demo.tool_$i', properties: {
          'a': {'type': 'string', 'description': 'x' * 60},
          'b': {'type': 'string', 'description': 'y' * 60},
        }));
      }

      final captured = <String, Object?>{};
      Object snapshot(List<Message> messages, List<Map<String, Object?>>? tools) {
        captured['messages'] = messages;
        captured['tools'] = tools ?? <Map<String, Object?>>[];
        return 'ok';
      }

      final cfg = Config.fromMap({
        'projection': {'window_tokens': 2000, 'reserved_output_tokens': 200},
      });
      final session = Session(ScriptedLLM([CallbackStep(snapshot)]), registry: reg, config: cfg);
      await session.send('do something with tool_5 and tool_12');

      final messageTokens = estimateTokens(captured['messages']);
      final schemaTokens =
          session.projection.schemaTokens(captured['tools'] as List<Map<String, Object?>>);
      expect(messageTokens + schemaTokens + 200, lessThanOrEqualTo(2000));
    });
  });

  group('07_ApprovalSurvivesRestart', () {
    test('waiting for approval resumes after simulated restart', () async {
      final tmpDir = Directory.systemTemp.createTempSync('spal_acceptance_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });
      final written = <String, String>{};

      String writeFile(Map<String, Object?> args) {
        final path = args['path'] as String;
        final content = args['content'] as String;
        written[path] = content;
        return 'wrote ${content.length} bytes';
      }

      Registry makeRegistry() {
        final reg = Registry();
        reg.register(
          capabilityDict('fs.write',
              properties: {
                'path': {'type': 'string'},
                'content': {'type': 'string'},
              },
              required: ['path', 'content'],
              effects: [('write', 'workspace:*')],
              retrySafety: 'never_retry'),
          handler: writeFile,
        );
        return reg;
      }

      // A real deployment reconstructs its PolicyEngine from its own
      // config on every boot; here that means a fresh engine with the
      // same (empty) rule set, so its revision number lines up with what
      // was recorded at approval-request time.
      PolicyEngine makePolicy() => PolicyEngine(defaultDecision: 'require_approval');

      final cfg = Config.fromMap({
        'mode': 'job',
        'persistence': {'ledger_directory': tmpDir.path},
      });
      final llm1 = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('fs.write', arguments: {'path': 'a.txt', 'content': 'hello'})),
      ]);
      final session1 =
          Session(llm1, registry: makeRegistry(), config: cfg, policy: makePolicy());
      await session1.runJob('write a.txt');
      expect(session1.run.state, equals('WAITING_FOR_APPROVAL'));
      final runId = session1.run.id;
      expect(written, isEmpty); // never executed before approval

      // --- simulate a process restart: build a brand new Session purely
      // from what's on disk, with no reference to session1/run1 ---
      final llm2 = ScriptedLLM([DecisionStep(ScriptedLLM.finish('all done'))]);
      final restored = Session.resumeFromLedger(llm2, runId,
          config: cfg, registry: makeRegistry(), policy: makePolicy());
      expect(restored.run.state, equals('WAITING_FOR_APPROVAL'));
      expect(restored.run.pendingCalls.map((c) => c.name).toList(), equals(['fs.write']));

      restored.resolveApproval('approved');
      final result2 = await restored.resume();

      expect(result2, equals('all done'));
      expect(written, equals({'a.txt': 'hello'}));
      expect(restored.run.state, equals('COMPLETED'));
    });
  });

  group('08_PolicyLayering', () {
    test('higher layer deny cannot be relaxed by lower layer', () async {
      final reg = Registry();
      final executed = <bool>[];
      reg.register(capabilityDict('fs.write', effects: [('write', 'workspace:*')]),
          handler: (Map<String, Object?> args) {
        executed.add(true);
        return 'ok';
      });

      final policy = PolicyEngine(defaultDecision: 'allow');
      policy.addRule('admin', Rule(decision: 'deny', capabilityPattern: 'fs.*'));
      // A lower layer (session/workspace) tries to allow it anyway.
      policy.addRule('session', Rule(decision: 'allow', capabilityPattern: 'fs.*'));

      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('fs.write')),
        const TextStep('could not write'),
      ]);
      final session = Session(llm, registry: reg, policy: policy);
      final reply = await session.send('please write');
      expect(reply, equals('could not write'));
      expect(executed, isEmpty);
    });
  });

  group('09_Reproducibility', () {
    test('run state recoverable from events and snapshot', () async {
      final tmpDir = Directory.systemTemp.createTempSync('spal_acceptance_');
      addTearDown(() {
        if (tmpDir.existsSync()) tmpDir.deleteSync(recursive: true);
      });
      final reg = Registry();
      reg.register(
        capabilityDict('demo.echo', properties: {
          'text': {'type': 'string'},
        }, required: [
          'text'
        ]),
        handler: (Map<String, Object?> args) => 'echo:${args['text']}',
      );
      final cfg = Config.fromMap({
        'mode': 'job',
        'persistence': {'ledger_directory': tmpDir.path},
      });
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'hi'})),
        DecisionStep(ScriptedLLM.finish('done')),
      ]);
      final session =
          Session(llm, registry: reg, config: cfg, policy: PolicyEngine(defaultDecision: 'allow'));
      await session.runJob('echo hi then finish');
      final runId = session.run.id;

      final events = session.ledger.iterRun(runId).toList();
      final eventTypes = events.map((e) => e.type).toSet();
      expect(
        {
          'user_input',
          'projection_compiled',
          'model_response',
          'decision_validated',
          'command_started',
          'command_completed',
          'run_state_changed',
        }.every(eventTypes.contains),
        isTrue,
      );

      final snapshot = session.ledger.loadSnapshot(runId);
      expect(snapshot, isNotNull);
      expect(snapshot!.state['state'], equals('COMPLETED'));

      final restoredLlm = ScriptedLLM([], strict: false);
      final restored = Session.resumeFromLedger(restoredLlm, runId, config: cfg, registry: reg);
      expect(restored.run.state, equals('COMPLETED'));
      expect(restored.run.result, equals('done'));
      expect(
        restored.conversation.map((m) => m.role).toList(),
        equals(session.conversation.map((m) => m.role).toList()),
      );
    });
  });

  group('10_Rewind', () {
    test('branch never mutates or deletes parent events', () async {
      final reg = Registry();
      final session =
          Session(ScriptedLLM([const TextStep('one'), const TextStep('two'), const TextStep('three')]),
              registry: reg);
      await session.send('a');
      await session.send('b');
      await session.send('c');
      final parentEventsBefore = session.ledger.iterRun(session.run.id).toList();

      final (branch, unusedIrreversible) = session.branch(atMessage: 2);
      expect(unusedIrreversible, isA<List<String>>());

      final parentEventsAfter = session.ledger.iterRun(session.run.id).toList();
      expect(
        parentEventsBefore.map((e) => e.id).toList(),
        equals(parentEventsAfter.map((e) => e.id).toList()),
      );
      expect(branch.run.id, isNot(equals(session.run.id)));
      expect(branch.conversation.length, equals(2));
      expect(session.conversation.length, equals(6)); // parent untouched
    });
  });

  group('11_ExternalEffectsSurfaced', () {
    test('rewind reports effects it cannot undo', () async {
      final reg = Registry();
      reg.register(capabilityDict('mail.send', effects: [('external', 'smtp:*')]),
          handler: (Map<String, Object?> args) => 'sent');
      final llm = ScriptedLLM([
        DecisionStep(ScriptedLLM.call('mail.send')),
        const TextStep('sent the email'),
      ]);
      final session = Session(llm, registry: reg, policy: PolicyEngine(defaultDecision: 'allow'));
      await session.send('send the email');

      final (unusedBranch, irreversible) = session.branch();
      expect(unusedBranch, isA<Session>());
      expect(irreversible.any((note) => note.contains('mail.send')), isTrue);
    });
  });

  group('12_CommandTraceability', () {
    test('each command traceable start to finish', () async {
      final reg = Registry();
      reg.register(
        capabilityDict('demo.echo', properties: {
          'text': {'type': 'string'},
        }, required: [
          'text'
        ]),
        handler: (Map<String, Object?> args) => 'echo:${args['text']}',
      );
      final session = Session(
        ScriptedLLM([
          DecisionStep(ScriptedLLM.call('demo.echo', arguments: {'text': 'hi'})),
          const TextStep('done'),
        ]),
        registry: reg,
        policy: PolicyEngine(defaultDecision: 'allow'),
      );
      await session.send('echo hi');

      final events = session.ledger.iterRun(session.run.id).toList();
      final started = events.firstWhere((e) => e.type == 'command_started');
      final completed = events.firstWhere((e) => e.type == 'command_completed');
      expect(started.data['command_id'], equals(completed.data['command_id']));
      expect(started.data['capability'], equals('demo.echo@1')); // qualified (versioned) name
      // the full pipeline is visible in order: decision -> command -> outcome
      final typesInOrder = events.map((e) => e.type).toList();
      expect(typesInOrder.indexOf('decision_validated'), lessThan(typesInOrder.indexOf('command_started')));
      expect(typesInOrder.indexOf('command_started'), lessThan(typesInOrder.indexOf('command_completed')));
    });
  });
}
