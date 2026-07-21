// Config defaults (spec §13) and token estimation.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

void main() {
  group('ConfigDefaults', () {
    test('spec defaults', () {
      final cfg = Config();
      expect(cfg.mode, equals('chat'));
      expect(cfg.projection.windowTokens, equals(30000));
      expect(
        cfg.projection.sections,
        equals(['kernel', 'toc', 'history', 'working_state', 'candidates']),
      );
      expect(cfg.discovery.vector, equals('auto'));
      expect(cfg.discovery.k, equals(8));
      expect(cfg.discovery.toc, isTrue);
      expect(
        cfg.discovery.querySources,
        equals(['last_user_message', 'last_model_thought', 'goal_if_exists']),
      );
      expect(cfg.compression.fullWindow, equals(6));
      expect(cfg.compression.compressedWindow, equals(24));
      expect(cfg.compression.summaryWindow, equals(60));
      expect(cfg.budget.maxSteps, equals(50));
      expect(cfg.budget.maxTokens, isNull);
      expect(cfg.artifacts.inlineThresholdTokens, equals(800));
      expect(cfg.limits.maxValidationRetries, equals(2));
      expect(cfg.limits.approvalExpiresS, equals(3600.0));
      expect(cfg.persistence.ledgerDirectory, isNull);
    });

    test('fromMap nested override', () {
      final cfg = Config.fromMap({
        'mode': 'job',
        'projection': {'window_tokens': 8000},
        'discovery': {'vector': 'off', 'k': 4},
        'budget': {'max_steps': 10},
      });
      expect(cfg.mode, equals('job'));
      expect(cfg.projection.windowTokens, equals(8000));
      expect(cfg.projection.sections[0], equals('kernel')); // untouched defaults survive
      expect(cfg.discovery.vector, equals('off'));
      expect(cfg.discovery.k, equals(4));
      expect(cfg.budget.maxSteps, equals(10));
    });

    test('fromMap unknown key raises', () {
      expect(
        () => Config.fromMap({'projektion': {}}),
        throwsA(isA<ArgumentError>().having(
            (e) => e.toString(), 'message', contains('Unknown config key'))),
      );
      expect(
        () => Config.fromMap({
          'discovery': {'vektor': 'on'},
        }),
        throwsA(isA<ArgumentError>().having(
            (e) => e.toString(), 'message', contains('Unknown config key'))),
      );
    });
  });

  group('TokenEstimation', () {
    test('empty', () {
      expect(estimateTextTokens(''), equals(0));
      expect(estimateTokens(null), equals(0));
    });

    test('ascii roughly quarter', () {
      final text = 'a' * 400;
      expect(estimateTextTokens(text), equals(100));
    });

    test('cjk counts per char', () {
      expect(estimateTextTokens('こんにちは'), equals(5));
      expect(estimateTextTokens('宝物庫の鍵'), equals(5));
    });

    test('mixed', () {
      // 4 CJK chars + 8 ascii chars -> 4 + 2
      expect(estimateTextTokens('日本語だabcdefgh'), equals(6));
    });

    test('message overhead and calls', () {
      final m = Message(role: 'user', content: 'hello world!');
      final base = estimateTokens(m);
      expect(base, greaterThanOrEqualTo(4 + 3));

      final m2 = Message(
        role: 'assistant',
        content: '',
        toolCalls: [ToolCall(name: 't', arguments: {'a': 1})],
      );
      expect(estimateTokens(m2), greaterThan(estimateTokens(Message(role: 'assistant', content: ''))));
    });

    test('list of messages', () {
      final msgs = [
        Message(role: 'user', content: 'abcd'),
        Message(role: 'assistant', content: 'efgh'),
      ];
      expect(estimateTokens(msgs), equals(estimateTokens(msgs[0]) + estimateTokens(msgs[1])));
    });
  });
}
