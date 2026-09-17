import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

void main() {
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
}
