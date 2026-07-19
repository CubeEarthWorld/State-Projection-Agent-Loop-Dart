/// LLM adapter interface and test helpers.
///
/// An adapter turns a rendered projection (list of [Message]s) plus optional
/// native tool schemas into a [Decision]. [ScriptedLLM] drives deterministic
/// tests.
///
/// For providers without native function calling, [parseTextToolCalls]
/// implements a fenced-JSON text protocol:
///
/// ```
/// ```tool_call
/// {"name": "web_search", "arguments": {"query": "..."}}
/// ```
/// ```
///
/// Completion is a formal property of a [Decision] (`finish`/`result`), not
/// a capability the runtime executes like any other. A model signals
/// completion by calling the reserved `finish(result)` function — every
/// adapter routes that call through [extractFinish] at the end of
/// `complete()` so the rest of the system only ever has to check
/// `decision.finish`.
library;

import 'dart:async';
import 'dart:convert';

import 'messages.dart';

const String finishName = 'finish';

final Map<String, Object?> finishSchema = {
  'type': 'function',
  'function': {
    'name': finishName,
    'description':
        'Finish the job and return the final result. Call this ALONE — never combined with '
            'other tool calls in the same decision; a decision that does both is rejected.',
    'parameters': {
      'type': 'object',
      'properties': {
        'result': {
          'description': 'The final result: string, object, or artifact reference.',
        },
      },
      'required': ['result'],
    },
  },
};

abstract interface class LLMAdapter {
  Future<Decision> complete(List<Message> messages, [List<Map<String, Object?>>? tools]);
}

/// Pull a `finish(result)` call (if present) out of `decision.calls` and
/// into `decision.finish`/`decision.result`.
///
/// Any *other* calls made in the same decision are deliberately left in the
/// returned decision's `calls` rather than dropped, so the session's
/// validator can reject the mixed decision explicitly and tell the model
/// why, instead of silently discarding side effects it asked for.
Decision extractFinish(Decision decision) {
  final remaining = <ToolCall>[];
  var finished = false;
  Object? result;
  for (final call in decision.calls) {
    if (call.name == finishName) {
      finished = true;
      result = call.arguments['result'];
    } else {
      remaining.add(call);
    }
  }
  if (!finished) return decision;
  return Decision(
    text: decision.text,
    calls: remaining,
    thought: decision.thought,
    usage: decision.usage,
    raw: decision.raw,
    finish: true,
    result: result,
  );
}

final RegExp _fence = RegExp(r'```tool_call\s*\n(.*?)```', dotAll: true);
final RegExp _nameFallback = RegExp(r'"(?:name|tool)"\s*:\s*"([^"]+)"');

/// Extract fenced tool_call JSON blocks from plain text output.
(String, List<ToolCall>) parseTextToolCalls(String text) {
  final calls = <ToolCall>[];
  final cleaned = text.replaceAllMapped(_fence, (match) {
    final body = match.group(1)!.trim();
    Object? data;
    try {
      data = jsonDecode(body);
    } catch (_) {
      final m = _nameFallback.firstMatch(body);
      if (m != null) {
        calls.add(ToolCall(name: m.group(1)!, arguments: {}, rawArguments: body));
      }
      return '';
    }
    if (data is! Map) return '';
    final name = data['name'] ?? data['tool'];
    if (name == null) return '';
    final args = data['arguments'] ?? data['args'] ?? {};
    if (args is! Map) {
      calls.add(ToolCall(name: name as String, arguments: {}, rawArguments: jsonEncode(args)));
    } else {
      calls.add(ToolCall(name: name as String, arguments: args.cast<String, Object?>()));
    }
    return '';
  }).trim();
  return (cleaned, calls);
}

/// A step may be a plain string (text-only decision), a [Decision], or a
/// callback `(messages, tools) -> String | Decision` for dynamic
/// assertions.
sealed class Step {
  const Step();
}

class TextStep extends Step {
  const TextStep(this.text);
  final String text;
}

class DecisionStep extends Step {
  const DecisionStep(this.decision);
  final Decision decision;
}

typedef StepCallback = FutureOr<Object> Function(
    List<Message> messages, List<Map<String, Object?>>? tools);

class CallbackStep extends Step {
  const CallbackStep(this.callback);
  final StepCallback callback;
}

/// Deterministic adapter for tests: replays a fixed list of steps.
///
/// Every request (messages + tools) is recorded in [requests].
class ScriptedLLM implements LLMAdapter {
  ScriptedLLM(List<Step> steps, {this.strict = true}) : _steps = List.of(steps);

  final List<Step> _steps;
  var _i = 0;
  final bool strict;
  final List<Map<String, Object?>> requests = [];

  static Decision call(String name, {String text = '', Map<String, Object?>? arguments}) =>
      extractFinish(
        Decision(text: text, calls: [ToolCall(name: name, arguments: arguments ?? {})]),
      );

  static Decision calls(List<(String, Map<String, Object?>)> specs, {String text = ''}) =>
      extractFinish(
        Decision(
          text: text,
          calls: [for (final (n, a) in specs) ToolCall(name: n, arguments: a)],
        ),
      );

  static Decision finish(Object? result, {String text = ''}) =>
      Decision(text: text, finish: true, result: result);

  @override
  Future<Decision> complete(List<Message> messages, [List<Map<String, Object?>>? tools]) async {
    requests.add({'messages': List.of(messages), 'tools': List.of(tools ?? [])});
    if (_i >= _steps.length) {
      if (strict) {
        throw StateError(
            'ScriptedLLM exhausted after ${_steps.length} steps; the loop asked for another decision');
      }
      return Decision(text: '(script exhausted)');
    }
    final step = _steps[_i];
    _i += 1;
    if (step is TextStep) return Decision(text: step.text);
    if (step is DecisionStep) return extractFinish(step.decision);
    if (step is CallbackStep) {
      final result = await step.callback(messages, tools);
      if (result is String) return Decision(text: result);
      if (result is Decision) return extractFinish(result);
      throw StateError('ScriptedLLM callback must return a String or Decision');
    }
    throw StateError('Unknown Step type');
  }
}
