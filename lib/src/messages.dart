/// Internal message and decision representation.
///
/// `content` may be a plain string or a list of part maps
/// (e.g. `[{"type": "text", "text": ...}, {"type": "image_url", ...}]`) so
/// multimodal input can pass through without core changes.
library;

import 'ids.dart';


/// Role constants. Tool results MUST use [observation] so untrusted data
/// stays structurally distinct from instructions (a mitigation,
/// not a full defense).
const String kSystem = 'system';
const String kUser = 'user';
const String kAssistant = 'assistant';
const String kObservation = 'tool';

/// A ULID, not a counter: a counter restarts with the process and would
/// reuse ids already in a resumed ledger, where calls pair with results by id.
String newCallId() => newId('call');

class ToolCall {
  ToolCall({
    required this.name,
    Map<String, Object?>? arguments,
    String? id,
    this.rawArguments,
  })  : arguments = arguments ?? <String, Object?>{},
        id = id ?? newCallId();

  final String name;

  final Map<String, Object?> arguments;

  final String id;

  /// Original argument string when the provider returned unparseable JSON;
  /// validation will fail and route through the self-repair path.
  final String? rawArguments;

  Map<String, Object?> toDict() => {
        'name': name,
        'arguments': arguments,
        'id': id,
        'raw_arguments': rawArguments,
      };

  factory ToolCall.fromDict(Map<String, Object?> d) => ToolCall(
        name: d['name'] as String,
        arguments: (d['arguments'] as Map?)?.cast<String, Object?>() ?? {},
        id: d['id'] as String?,
        rawArguments: d['raw_arguments'] as String?,
      );
}

class Message {
  Message({
    required this.role,
    this.content = '',
    List<ToolCall>? toolCalls,
    this.toolCallId,
    this.name,
  }) : toolCalls = toolCalls ?? <ToolCall>[];

  final String role;

  final Object? content;

  final List<ToolCall> toolCalls;

  final String? toolCallId;
  final String? name;

  String text() {
    if (content is String) return content as String;
    if (content is List) {
      final parts = <String>[];
      for (final p in content as List) {
        if (p is Map && p['type'] == 'text') {
          parts.add((p['text'] ?? '').toString());
        }
      }
      return parts.join('\n');
    }
    return content?.toString() ?? '';
  }

  Map<String, Object?> toDict() => {
        'role': role,
        'content': content,
        'tool_calls': toolCalls.map((tc) => tc.toDict()).toList(),
        'tool_call_id': toolCallId,
        'name': name,
      };

  factory Message.fromDict(Map<String, Object?> d) => Message(
        role: d['role'] as String,
        content: d['content'] ?? '',
        toolCalls: [
          for (final tc in (d['tool_calls'] as List? ?? []))
            ToolCall.fromDict((tc as Map).cast<String, Object?>()),
        ],
        toolCallId: d['tool_call_id'] as String?,
        name: d['name'] as String?,
      );

  Message copyWith({
    String? role,
    Object? content,
    List<ToolCall>? toolCalls,
    String? toolCallId,
    String? name,
  }) =>
      Message(
        role: role ?? this.role,
        content: content ?? this.content,
        toolCalls: toolCalls ?? this.toolCalls,
        toolCallId: toolCallId ?? this.toolCallId,
        name: name ?? this.name,
      );
}

class Usage {
  Usage({this.promptTokens = 0, this.completionTokens = 0});

  final int promptTokens;
  final int completionTokens;

  int get totalTokens => promptTokens + completionTokens;
}

/// One model output: plain text and/or a batch of tool calls.
///
/// [finish] is the formal completion signal: it is a property of the
/// *decision itself*, not a tool call routed through the runtime like any
/// other. A decision that sets [finish] together with a non-empty [calls]
/// is invalid and MUST be rejected by validation before anything executes
/// — declaring the job done and still queuing side effects in the same
/// breath is exactly the bug this separation prevents.
class Decision {
  Decision({
    this.text = '',
    List<ToolCall>? calls,
    this.thought = '',
    this.usage,
    this.raw,
    this.finish = false,
    this.result,
  }) : calls = calls ?? <ToolCall>[];

  final String text;
  final List<ToolCall> calls;
  final String thought;
  final Usage? usage;
  final Object? raw;
  final bool finish;
  final Object? result;

}
