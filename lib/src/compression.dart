/// Deterministic content compression — pure functions, no LLM, no I/O.
///
/// Applied by the projection pipeline when rendering older events at reduced
/// fidelity. Every function here is total (never throws on any string input)
/// and idempotent where noted. The guarantee: compression never fabricates
/// content that was not in the original; it only removes or abbreviates.
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

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

/// Content-addressed key for detecting repeated observations.
///
/// SHA-256, truncated to 16 hex digits — the same value the Python package
/// produces for the same input, so keys stay comparable across the two.
String contentHash(String text) =>
    sha256.convert(utf8.encode(text)).toString().substring(0, 16);

/// Split into lines *keeping* the line terminators, so joining the pieces
/// reproduces the input byte for byte. Matches Python's
/// `str.splitlines(keepends=True)` in what it treats as a break: \r\n, \n
/// and a lone \r.
List<String> splitLinesKeepEnds(String text) {
  final lines = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x0A) {
      lines.add(text.substring(start, i + 1));
      start = i + 1;
    } else if (c == 0x0D) {
      final end = (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) ? i + 2 : i + 1;
      lines.add(text.substring(start, end));
      i = end - 1;
      start = end;
    }
  }
  if (start < text.length) lines.add(text.substring(start));
  return lines;
}

String stripNoise(String text) {
  for (final (pattern, repl) in _noisePatterns) {
    text = text.replaceAll(pattern, repl);
  }
  return text;
}

String headTailTruncate(String text, int maxLines) {
  final lines = splitLinesKeepEnds(text);
  if (lines.length <= maxLines) return text;
  final headN = max(1, (maxLines * _headRatio).truncate());
  final tailN = max(1, (maxLines * _tailRatio).truncate());
  final omitted = lines.length - headN - tailN;
  if (omitted <= 0) return text;
  final head = lines.sublist(0, headN);
  final tail = tailN > 0 ? lines.sublist(lines.length - tailN) : <String>[];
  return '${head.join()}  [... $omitted lines omitted ...]\n${tail.join()}';
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
  // Characters, not UTF-16 code units: the count is shown to the model and
  // must mean the same thing in both languages, and slicing by code unit
  // would also split a surrogate pair.
  final charCount = text.runes.length;
  if (lineCount <= 1 && charCount <= 120) return text.trim();
  const maxFirst = 120;
  final firstRunes = first.runes.toList();
  final truncatedFirst = firstRunes.length > maxFirst
      ? '${String.fromCharCodes(firstRunes.take(maxFirst))}…'
      : first;
  return '$truncatedFirst  [$lineCount lines, $charCount chars]';
}

