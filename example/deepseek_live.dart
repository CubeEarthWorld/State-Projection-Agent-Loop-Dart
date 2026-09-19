// Live end-to-end check against an OpenAI-compatible chat API (DeepSeek by
// default). NOT part of the package: `state_projection_loop` is LLM-agnostic
// and ships no provider client. This file is the Dart counterpart of the
// Python repository's `examples/llm_adapters.py` + live tests.
//
//     DEEPSEEK_API_KEY=sk-... dart run example/deepseek_live.dart
//
// Optional: LLM_MODEL (default deepseek-flash), LLM_BASE_URL
// (default https://api.deepseek.com). Every scenario asserts on ledger
// facts (which commands ran, which run state was reached), never on the
// model's prose, so the check is stable across model versions.
import 'dart:convert';
import 'dart:io';

import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:state_projection_loop/native.dart';

/// Any OpenAI-compatible chat-completion endpoint, using only dart:io.
/// Neutral tool specs -> OpenAI's `{'type': 'function', ...}` envelope.
///
/// The runtime hands every adapter the same neutral
/// `{name, description, parameters}`; wrapping it for one provider is that
/// provider's adapter's job. Anthropic, Gemini and the rest each need their
/// own few lines instead of unwrapping someone else's.
List<Map<String, Object?>> toOpenAiTools(List<Map<String, Object?>> tools) =>
    [for (final tool in tools) {'type': 'function', 'function': tool}];


class OpenAICompatAdapter implements LLMAdapter {
  OpenAICompatAdapter({required this.model, required this.apiKey, required this.baseUrl});

  final String model;
  final String apiKey;
  final String baseUrl;
  final HttpClient _client = HttpClient()..connectionTimeout = const Duration(seconds: 30);

  Map<String, Object?> _toApi(Message m) {
    if (m.role == kAssistant && m.toolCalls.isNotEmpty) {
      return {
        'role': 'assistant',
        'content': m.text().isEmpty ? null : m.text(),
        'tool_calls': [
          for (final tc in m.toolCalls)
            {
              'id': tc.id,
              'type': 'function',
              'function': {'name': tc.name, 'arguments': jsonEncode(tc.arguments)},
            },
        ],
      };
    }
    if (m.role == kObservation) {
      return {'role': 'tool', 'tool_call_id': m.toolCallId ?? '', 'content': m.text()};
    }
    return {'role': m.role, 'content': m.content};
  }

  @override
  Future<Decision> complete(List<Message> messages,
      [List<Map<String, Object?>>? tools, void Function(String text)? onDelta]) async {
    final body = <String, Object?>{
      'model': model,
      'messages': [for (final m in messages) _toApi(m)],
      'temperature': 0.2,
      if (tools != null && tools.isNotEmpty) 'tools': toOpenAiTools(tools),
      if (tools != null && tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final request = await _client.postUrl(Uri.parse('$baseUrl/chat/completions'));
    request.headers.contentType = ContentType.json; // utf-8 charset
    request.headers.set('authorization', 'Bearer $apiKey');
    request.add(utf8.encode(jsonEncode(body)));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw StateError('HTTP ${response.statusCode}: $text');
    }
    final json = jsonDecode(text) as Map<String, Object?>;
    final choice = ((json['choices'] as List).first as Map)['message'] as Map;
    final calls = <ToolCall>[];
    for (final tc in (choice['tool_calls'] as List? ?? [])) {
      final fn = (tc as Map)['function'] as Map;
      final raw = (fn['arguments'] as String?) ?? '{}';
      Object? args;
      try {
        args = jsonDecode(raw);
      } catch (_) {
        args = null;
      }
      calls.add(args is Map
          ? ToolCall(name: fn['name'] as String, arguments: args.cast<String, Object?>(), id: tc['id'] as String)
          : ToolCall(name: fn['name'] as String, arguments: {}, id: tc['id'] as String, rawArguments: raw));
    }
    var content = (choice['content'] as String?) ?? '';
    if (calls.isEmpty && content.contains('```tool_call')) {
      final (cleaned, parsed) = parseTextToolCalls(content);
      content = cleaned;
      calls.addAll(parsed);
    }
    final usage = json['usage'] as Map?;
    return extractFinish(Decision(
      text: content,
      calls: calls,
      usage: usage == null
          ? null
          : Usage(
              promptTokens: (usage['prompt_tokens'] as num?)?.toInt() ?? 0,
              completionTokens: (usage['completion_tokens'] as num?)?.toInt() ?? 0,
            ),
      raw: json,
    ));
  }
}

int _failures = 0;

void check(bool condition, String what) {
  stdout.writeln('  ${condition ? 'PASS' : 'FAIL'}  $what');
  if (!condition) _failures++;
}

List<String> completedCommands(Session s) => [
      for (final e in s.ledger.iterRun(s.run.id))
        if (e.type == 'command_completed') s.run.commands[e.data['command_id']]!.capabilityName,
    ];

Map<String, Object?> stockDef = {
  'name': 'inventory.stock.get',
  'category': 'inventory',
  'spec': {
    'description': 'Return the current stock count of a warehouse.',
    'parameters': {
      'type': 'object',
      'properties': {'warehouse': {'type': 'string', 'description': 'warehouse name, e.g. Tokyo'}},
      'required': ['warehouse'],
    },
  },
  'discovery': {'embedding_text': '在庫 いくつ 残り stock inventory warehouse'},
  'execution': {'timeout_s': 5, 'retry_safety': 'pure'},
  'effects': [{'kind': 'none'}],
};

Future<void> main() async {
  final apiKey = Platform.environment['LLM_API_KEY'] ?? Platform.environment['DEEPSEEK_API_KEY'];
  if (apiKey == null || apiKey.isEmpty) {
    stderr.writeln('set LLM_API_KEY (or DEEPSEEK_API_KEY)');
    exit(2);
  }
  final llm = OpenAICompatAdapter(
    model: Platform.environment['LLM_MODEL'] ?? 'deepseek-flash',
    apiKey: apiKey,
    baseUrl: Platform.environment['LLM_BASE_URL'] ?? 'https://api.deepseek.com',
  );
  var totalPrompt = 0, totalCompletion = 0;
  void account(Session s) {
    totalPrompt += s.budget.promptTokens;
    totalCompletion += s.budget.completionTokens;
  }

  // 1. Chat mode: a registered tool is called natively and the answer uses it.
  stdout.writeln('[1] chat + native tool call');
  {
    final reg = Registry();
    reg.register(stockDef, handler: (args) => {'warehouse': args['warehouse'], 'stock': 42});
    final s = Session(llm, registry: reg, policy: PolicyEngine(defaultDecision: 'allow'),
        kernel: 'You are an inventory assistant. Always answer stock questions with the inventory.stock.get tool.');
    final answer = await s.send('東京倉庫の在庫はいくつ?');
    check(completedCommands(s).any((n) => n.startsWith('inventory.stock.get')), 'inventory.stock.get executed');
    check(answer.toString().contains('42'), 'answer mentions 42 (got: ${answer.toString().replaceAll('\n', ' ')})');
    check(s.budget.promptTokens > 0, 'provider usage recorded (${s.budget.promptTokens} prompt tokens)');
    account(s);
  }

  // 2. Job mode: bundled checklist pack + finish(result).
  stdout.writeln('[2] job mode: checklist pack then finish');
  {
    final cfg = Config.fromDict({'mode': 'job', 'budget': {'max_steps': 8}});
    final s = Session(llm, config: cfg, policy: PolicyEngine(defaultDecision: 'allow'),
        kernel: 'You manage plans. Use planning.checklist.manage to create the checklist exactly as asked, '
            'then call finish(result) with the string "done".');
    final result = await s.runJob('Create a checklist named "release" with two items: "write notes" and "tag build". Then finish.');
    check(s.run.state == 'COMPLETED', 'run COMPLETED (state=${s.run.state})');
    final lists = s.checklists.execute('list', {'mode': 'full'}) as List;
    check(lists.length == 1 && ((lists.first as Map)['items'] as List).length == 2,
        'one checklist with two items stored (got ${lists.length} list(s))');
    check(result.toString().toLowerCase().contains('done'), 'finish(result) returned (got: $result)');
    account(s);
  }

  // 3. Layer-3 discovery: a tool hidden from auto-candidates must be found via meta.tool.find.
  stdout.writeln('[3] discovery through meta.tool.find');
  {
    final reg = Registry();
    reg.register({
      'name': 'weather.city.get',
      'category': 'weather',
      'spec': {
        'description': 'Current weather for a city.',
        'parameters': {'type': 'object', 'properties': {'city': {'type': 'string'}}, 'required': ['city']},
      },
      'discovery': {'no_embed': true, 'embedding_text': 'weather forecast temperature city 天気'},
      'execution': {'timeout_s': 5, 'retry_safety': 'pure'},
      'effects': [{'kind': 'none'}],
    }, handler: (args) => {'city': args['city'], 'weather': 'sunny', 'temp_c': 23});
    for (var i = 0; i < 30; i++) {
      reg.register({
        'name': 'misc.filler.tool_$i',
        'category': 'misc/filler',
        'spec': {'description': 'Filler tool number $i; does nothing useful.', 'parameters': {'type': 'object', 'properties': {}}},
        'execution': {'timeout_s': 5, 'retry_safety': 'pure'},
        'effects': [{'kind': 'none'}],
      }, handler: (args) => 'noop');
    }
    final cfg = Config.fromDict({'discovery': {'k': 0}});
    final s = Session(llm, registry: reg, config: cfg, policy: PolicyEngine(defaultDecision: 'allow'),
        kernel: 'Answer with tools. If the tool you need is not listed, search for it first.');
    final answer = await s.send('What is the weather in Osaka right now?');
    final ran = completedCommands(s);
    check(ran.any((n) => n.startsWith('meta.tool.find')), 'meta.tool.find used');
    check(ran.any((n) => n.startsWith('weather.city.get')), 'weather.city.get executed after discovery');
    check(answer.toString().toLowerCase().contains('sunny') || answer.toString().contains('23'),
        'answer uses the tool result (got: ${answer.toString().replaceAll('\n', ' ')})');
    account(s);
  }

  // 4. Approval: an external effect pauses the run; approving resumes it.
  stdout.writeln('[4] approval pause and resume');
  {
    final sent = <String>[];
    final reg = Registry();
    reg.register({
      'name': 'mail.message.send',
      'category': 'mail',
      'spec': {
        'description': 'Send an email.',
        'parameters': {
          'type': 'object',
          'properties': {'to': {'type': 'string'}, 'body': {'type': 'string'}},
          'required': ['to', 'body'],
        },
      },
      'discovery': {'pinned': true},
      'execution': {'timeout_s': 5, 'retry_safety': 'never_retry'},
      'effects': [{'kind': 'external', 'resource': 'network:mail'}],
    }, handler: (args) {
      sent.add(args['to'] as String);
      return 'sent';
    });
    final s = Session(llm, registry: reg, kernel: 'Send emails with mail.message.send when asked.');
    final first = await s.send('Send an email to bob@example.com saying "hi".');
    check(s.run.state == 'WAITING_FOR_APPROVAL' && first is ApprovalRequest,
        'run paused for approval (state=${s.run.state})');
    check(sent.isEmpty, 'nothing sent before approval');
    if (s.run.state == 'WAITING_FOR_APPROVAL') {
      s.resolveApproval('approved');
      await s.resume();
      check(sent.length == 1 && sent.first == 'bob@example.com', 'sent exactly once after approval ($sent)');
      check(s.run.state == 'RUNNING', 'run back to RUNNING');
    }
    account(s);
  }

  // 5. ask pack: the model asks the user, the run pauses, the answer flows back.
  stdout.writeln('[5] ask pack: pause for the user and resume');
  {
    final s = Session(llm, builtins: ['meta', 'ask'],
        kernel: 'Before answering, you MUST call meta.user.ask to learn the user\'s favourite colour. '
            'After the answer arrives, reply with exactly: "Your colour is <colour>."');
    final paused = await s.send('Tell me my favourite colour.');
    check(paused is PendingQuestion && s.run.state == 'WAITING_FOR_USER',
        'run paused with a question (state=${s.run.state}, q=${paused is PendingQuestion ? paused.text : paused})');
    if (s.run.state == 'WAITING_FOR_USER') {
      s.answer('teal');
      final reply = await s.resume();
      check(reply.toString().toLowerCase().contains('teal'), 'answer flowed back into the reply (got: $reply)');
      check(s.run.state == 'RUNNING', 'run RUNNING again');
    }
    account(s);
  }

  // 6. skills: a skill is discovered and loaded like any other tool.
  stdout.writeln('[6] skills via discovery');
  {
    final reg = Registry();
    reg.register(skillCapability('deploy', 'Deploy steps: run `make release`, then tag v-next.',
        summary: 'How to deploy the service'));
    final s = Session(llm, registry: reg, policy: PolicyEngine(defaultDecision: 'allow'),
        kernel: 'Follow the loaded skill instructions literally when asked how to do something.');
    final answer = await s.send('How do I deploy the service? Load the skill first.');
    check(completedCommands(s).any((n) => n.startsWith('skill.deploy.load')), 'skill loaded on demand');
    check(answer.toString().contains('make release'), 'answer uses the skill text (got: ${answer.toString().replaceAll('\n', ' ')})');
    account(s);
  }

  stdout.writeln('tokens: prompt=$totalPrompt completion=$totalCompletion');
  stdout.writeln(_failures == 0 ? 'ALL LIVE CHECKS PASSED' : '$_failures LIVE CHECK(S) FAILED');
  exit(_failures == 0 ? 0 : 1);
}
