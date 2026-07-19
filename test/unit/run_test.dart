// Run state machine: transitions, terminal-state guard, approval
// lifecycle including the "premise changed" staleness check, snapshot
// round-trip.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

Run makeRun() {
  final ledger = InMemoryLedger();
  return Run('run_1', 'ses_1', ledger);
}

void main() {
  group('Transitions', () {
    test('default state is running', () {
      final run = makeRun();
      expect(run.state, equals('RUNNING'));
    });

    test('complete is terminal', () {
      final run = makeRun();
      run.complete('done');
      expect(run.state, equals('COMPLETED'));
      expect(() => run.newCommand('demo.thing', {}, 'pure'), throwsA(isA<RunStateError>()));
    });

    test('cannot leave terminal state', () {
      final run = makeRun();
      run.fail('boom');
      expect(() => run.transition('RUNNING'), throwsA(isA<RunStateError>()));
    });
  });

  group('Commands', () {
    test('newCommand records started event', () {
      final run = makeRun();
      final cmd = run.newCommand('demo.thing', {'x': 1}, 'pure');
      final events = run.ledger.iterRun(run.id).toList();
      expect(events.last.type, equals('command_started'));
      expect(events.last.data['command_id'], equals(cmd.id));
    });

    test('recordOutcome ok', () {
      final run = makeRun();
      final cmd = run.newCommand('demo.thing', {}, 'pure');
      run.recordOutcome(cmd, 'ok', resultRef: 'art_1');
      expect(cmd.outcome, equals('ok'));
      expect(cmd.resultRef, equals('art_1'));
    });

    test('recordOutcome unknown never auto marked failed', () {
      final run = makeRun();
      final cmd = run.newCommand('demo.thing', {}, 'never_retry');
      run.recordOutcome(cmd, 'unknown', error: 'timed out');
      expect(cmd.outcome, equals('unknown')); // distinct from "failed"
    });
  });

  group('Approval', () {
    test('requestApproval transitions and records', () {
      final run = makeRun();
      final cmd = run.newCommand('fs.file.write', {'path': 'a'}, 'never_retry');
      final req = run.requestApproval(
          cmd, [Effect(kind: 'write', resource: 'workspace:*')], 'needs review',
          policyRevision: 1);
      expect(run.state, equals('WAITING_FOR_APPROVAL'));
      expect(run.pendingApproval, same(req));
    });

    test('resolveApproval returns to running', () {
      final run = makeRun();
      final cmd = run.newCommand('fs.file.write', {}, 'never_retry');
      run.requestApproval(cmd, [], 'x', policyRevision: 1);
      final req = run.resolveApproval('approved', currentPolicyRevision: 1);
      expect(req.resolution, equals('approved'));
      expect(run.state, equals('RUNNING'));
      expect(run.pendingApproval, isNull);
      expect(run.lastResolvedApproval, same(req));
    });

    test('resolve with stale policy revision raises', () {
      final run = makeRun();
      final cmd = run.newCommand('fs.file.write', {}, 'never_retry');
      run.requestApproval(cmd, [], 'x', policyRevision: 1);
      expect(
        () => run.resolveApproval('approved', currentPolicyRevision: 2),
        throwsA(isA<RunStateError>()
            .having((e) => e.toString(), 'message', contains('Policy changed'))),
      );
    });

    test('resolve without pending raises', () {
      final run = makeRun();
      expect(
        () => run.resolveApproval('approved', currentPolicyRevision: 0),
        throwsA(isA<RunStateError>()
            .having((e) => e.toString(), 'message', contains('no pending approval'))),
      );
    });

    test('expired approval raises and marks expired', () {
      final run = makeRun();
      final cmd = run.newCommand('fs.file.write', {}, 'never_retry');
      final req = run.requestApproval(cmd, [], 'x', policyRevision: 1, expiresInS: -1);
      expect(
        () => run.resolveApproval('approved', currentPolicyRevision: 1),
        throwsA(isA<RunStateError>()
            .having((e) => e.toString(), 'message', contains('expired'))),
      );
      expect(req.resolution, equals('expired'));
    });
  });

  group('SnapshotRoundTrip', () {
    test('round trip preserves pending state', () {
      final run = makeRun();
      final cmd = run.newCommand('fs.file.write', {'path': 'a'}, 'never_retry');
      run.pendingCalls = [ToolCall(name: 'fs.file.write', arguments: {'path': 'a'}, id: cmd.id)];
      run.requestApproval(
          cmd, [Effect(kind: 'write', resource: 'workspace:*')], 'x',
          policyRevision: 2);

      final state = run.toSnapshotState();
      final restored = Run.fromSnapshotState(run.id, run.ledger, state);

      expect(restored.state, equals('WAITING_FOR_APPROVAL'));
      expect(restored.pendingApproval!.commandId, equals(cmd.id));
      expect(restored.pendingApproval!.policyRevision, equals(2));
      expect(restored.pendingCalls.map((c) => c.name).toList(), equals(['fs.file.write']));
      expect(restored.commands[cmd.id]!.capabilityName, equals('fs.file.write'));
    });
  });
}
