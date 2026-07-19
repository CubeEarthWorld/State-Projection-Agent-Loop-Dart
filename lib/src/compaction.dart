/// Compaction — folding overflowed conversation into the working state
/// under fold contract v2.
///
/// Contract v1 asked the summarizer to write free prose and hope decision
/// reasons survived a later re-fold. Contract v2 instead asks for a small,
/// schema-shaped delta that is merged straight into [WorkingState]
/// ([WorkingState.mergeFold]): new facts and decisions are *appended*, not
/// re-summarized, so a decision's reason recorded three folds ago is still
/// there verbatim. The folded messages themselves are never discarded —
/// they remain in the Event Ledger and stay reachable via the
/// `search_history` capability after being dropped from the live
/// projection.
library;

import 'dart:convert';

import 'artifacts.dart' show truncateToTokens;
import 'config.dart';
import 'llm.dart';
import 'messages.dart';
import 'tokens.dart';
import 'working_state.dart';

const String contractV2 = '''You are the compaction summarizer of an agent loop. Fold the transcript below into a JSON delta that will be merged into a structured working-state record. Contract v2 — every rule is mandatory:
1. Output ONLY a single JSON object, no prose, no markdown fence.
2. Fields (all optional, omit what doesn't apply):
   "goal": string — only if the goal changed or was clarified,
   "new_facts": array of strings — confirmed facts/user constraints, kept verbatim where the user stated them,
   "new_decisions": array of {"text": string, "reason": string} — every decision the agent made and WHY, in first person,
   "new_open_questions": array of strings,
   "resolved_open_questions": array of strings — exact text of questions that are no longer open,
   "next_actions": array of strings — REPLACES the previous next_actions list; give the full current list,
   "artifact_refs": array of strings — any artifact ids mentioned that remain relevant.
3. Never copy large raw data bodies into a field; reference their artifact id instead.
4. Preserve chronological order within each array.
Output only the JSON object.''';

String renderTranscript(List<Message> messages) {
  final lines = <String>[];
  for (final m in messages) {
    if (m.role == kUser) {
      lines.add('[user] ${m.text()}');
    } else if (m.role == kAssistant) {
      final text = m.text();
      if (text.isNotEmpty) lines.add('[assistant] $text');
      for (final tc in m.toolCalls) {
        final args = jsonEncode(tc.arguments);
        lines.add('[assistant→call] ${tc.name}(${_truncate(args, 60)})');
      }
    } else if (m.role == kObservation) {
      lines.add('[observation:${m.name}] ${_truncate(m.text(), 150)}');
    } else if (m.role == kSystem) {
      lines.add('[runtime] ${m.text()}');
    }
  }
  return lines.join('\n');
}

String _truncate(String text, int maxTokens) => truncateToTokens(text, maxTokens);

/// LLM-free fallback (`compaction.model="none"`): mechanical, cannot
/// reconstruct reasons, so it says so explicitly in a fact entry.
Map<String, Object?> deterministicFold(List<Message> messages) {
  final facts = <String>[];
  for (final m in messages) {
    if (m.role == kUser) {
      facts.add('User said (verbatim): "${m.text()}"');
    } else if (m.role == kAssistant) {
      for (final tc in m.toolCalls) {
        facts.add('(mechanical fold) called ${tc.name}');
      }
    }
  }
  return {'new_facts': facts.take(50).toList()};
}

class Compactor {
  Compactor(this.config, {this.summarizer});

  final Config config;

  /// An [LLMAdapter] or null (deterministic fallback).
  final LLMAdapter? summarizer;

  bool shouldCompact(List<Message> conversation, int windowTokens) {
    final threshold = windowTokens * config.compaction.triggerRatio;
    return estimateTokens(conversation) > threshold;
  }

  /// Index splitting messages to fold (older half by tokens) from the rest.
  /// Never orphans tool observations and always leaves at least the last
  /// exchange unfolded.
  int splitPoint(List<Message> conversation) {
    final total = estimateTokens(conversation);
    final target = total ~/ 2;
    var acc = 0;
    var i = 0;
    while (i < conversation.length && acc < target) {
      acc += estimateTokens(conversation[i]);
      i += 1;
    }
    while (i < conversation.length && conversation[i].role == kObservation) {
      i += 1;
    }
    if (i >= conversation.length) {
      i = conversation.isEmpty ? 0 : conversation.length - 1;
      while (i > 0 && conversation[i].role == kObservation) {
        i -= 1;
      }
    }
    return i;
  }

  /// Fold the older half of [conversation] into [workingState] in place.
  /// Returns `(foldedAnything, remainingConversation)`.
  Future<(bool, List<Message>)> fold(
      List<Message> conversation, WorkingState workingState) async {
    final i = splitPoint(conversation);
    final folded = conversation.sublist(0, i);
    final remaining = conversation.sublist(i);
    if (folded.isEmpty) return (false, conversation);
    Map<String, Object?> delta;
    if (summarizer == null) {
      delta = deterministicFold(folded);
    } else {
      final prompt = [
        Message(role: kSystem, content: contractV2),
        Message(role: kUser, content: renderTranscript(folded)),
      ];
      final decision = await summarizer!.complete(prompt, null);
      delta = _parseDelta(decision.text);
    }
    workingState.mergeFold(delta);
    return (true, remaining);
  }
}

Map<String, Object?> _parseDelta(String rawText) {
  var text = rawText.trim();
  if (text.startsWith('```')) {
    text = text.replaceAll(RegExp(r'^`+'), '').replaceAll(RegExp(r'`+$'), '');
    if (text.startsWith('json')) {
      text = text.substring(4);
    }
  }
  try {
    final data = jsonDecode(text);
    return data is Map ? data.cast<String, Object?>() : {};
  } catch (_) {
    final preview = text.length > 200 ? text.substring(0, 200) : text;
    return {
      'new_facts': ['(fold parse failed) $preview'],
    };
  }
}
