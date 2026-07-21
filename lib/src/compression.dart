/// Deterministic content compression — pure functions, no LLM, no I/O.
///
/// Applied by the projection pipeline when rendering older events at reduced
/// fidelity. Every function here is total (never throws on any string input)
/// and idempotent where noted. The guarantee: compression never fabricates
/// content that was not in the original; it only removes or abbreviates.
library;

import 'dart:convert';
import 'dart:math';

final List<(RegExp, String)> _noisePatterns = [
  (RegExp(r'^diff --git .+\n', multiLine: true), ''),
  (RegExp(r'^index [0-9a-f]+\.\.[0-9a-f]+.*\n', multiLine: true), ''),
  (RegExp(r'^--- a/.+\n', multiLine: true), ''),
  (RegExp(r'^\+\+\+ b/.+\n', multiLine: true), ''),
  (RegExp(r'^@@ [^@]+ @@[^\n]*\n', multiLine: true), ''),
  (RegExp(r'^(node_modules|\.venv|__pycache__|\.git/|\.dart_tool/)[^\n]*\n', multiLine: true), ''),
  (RegExp(r'^\s*$\n(\s*$\n)+', multiLine: true), '\n'),
  (RegExp(r'\x1b\[[0-9;]*[a-zA-Z]'), ''),
  (RegExp(r'^Progress:.*\r?', multiLine: true), ''),
  (RegExp(r'^\[?\d+/\d+\]?\s*(Downloading|Installing|Collecting|Using cached)[^\n]*\n', multiLine: true), ''),
];

const double _headRatio = 0.6;
const double _tailRatio = 0.25;

String contentHash(String text) {
  final bytes = utf8.encode(text);
  var hash = 0x811c9dc5;
  for (final b in bytes) {
    hash ^= b;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(8, '0') +
      (hash ^ bytes.length).toRadixString(16).padLeft(8, '0');
}

String stripNoise(String text) {
  for (final (pattern, repl) in _noisePatterns) {
    text = text.replaceAll(pattern, repl);
  }
  return text;
}

String headTailTruncate(String text, int maxLines) {
  final lines = text.split('\n');
  if (lines.length <= maxLines) return text;
  final headN = max(1, (maxLines * _headRatio).round());
  final tailN = max(1, (maxLines * _tailRatio).round());
  final omitted = lines.length - headN - tailN;
  if (omitted <= 0) return text;
  final head = lines.sublist(0, headN);
  final tail = tailN > 0 ? lines.sublist(lines.length - tailN) : <String>[];
  return [...head, '  [... $omitted lines omitted ...]', ...tail].join('\n');
}

String compressText(String text, {int maxLines = 80}) {
  if (text.isEmpty) return text;
  var result = stripNoise(text);
  result = headTailTruncate(result, maxLines);
  if (result.trim().isEmpty && text.trim().isNotEmpty) {
    result = text.split('\n').first;
  }
  return result;
}

String firstMeaningfulLine(String text) {
  for (final line in text.split('\n')) {
    final stripped = line.trim();
    if (stripped.isNotEmpty &&
        !stripped.startsWith('#') &&
        !stripped.startsWith('//') &&
        !stripped.startsWith('/*') &&
        !stripped.startsWith('*') &&
        !stripped.startsWith('---')) {
      return stripped;
    }
  }
  final lines = text.split('\n');
  return lines.isNotEmpty ? lines.first.trim() : '';
}

String summarizeText(String text) {
  if (text.isEmpty) return text;
  final first = firstMeaningfulLine(text);
  final lineCount = '\n'.allMatches(text).length + 1;
  final charCount = text.length;
  if (lineCount <= 1 && charCount <= 120) return text.trim();
  const maxFirst = 120;
  final truncatedFirst =
      first.length > maxFirst ? '${first.substring(0, maxFirst)}…' : first;
  return '$truncatedFirst  [$lineCount lines, $charCount chars]';
}

String compressObservation(String text, {int maxLines = 40}) {
  return compressText(text, maxLines: maxLines);
}

String dedupeKey(String content) => contentHash(content);
