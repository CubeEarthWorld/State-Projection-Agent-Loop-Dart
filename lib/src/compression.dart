/// Deterministic content compression — pure functions, no LLM, no I/O.
///
/// Applied by the projection pipeline when rendering older events at reduced
/// fidelity. Every function here is total (never throws on any string input)
/// and idempotent where noted. The guarantee: compression never fabricates
/// content that was not in the original; it only removes or abbreviates.
library;

import 'dart:convert';

import 'hashing.dart';
import 'dart:math';


// `[^\n]` rather than `.`, which in Dart also excludes \r: without it none
// of these match CRLF output, which is most tool output captured on Windows.
// Python's `.` outside DOTALL excludes only \n, so `[^\n]` is the port of it.
final List<(RegExp, String)> _noisePatterns = [
  (RegExp(r'^diff --git [^\n]+\n', multiLine: true), ''),
  (RegExp(r'^index [0-9a-f]+\.\.[0-9a-f]+[^\n]*\n', multiLine: true), ''),
  (RegExp(r'^--- a/[^\n]+\n', multiLine: true), ''),
  (RegExp(r'^\+\+\+ b/[^\n]+\n', multiLine: true), ''),
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
/// FNV-1a-64, as 16 hex digits — the same value the Python package produces
/// for the same input, so keys stay comparable across the two.
///
/// Unpaired surrogates become `?`, because Python hashes
/// `text.encode("utf-8", errors="replace")` and that is what replace emits
/// when encoding. Dart's encoder would substitute U+FFFD instead and the
/// two ports would disagree on the dedupe key for the same string.
String contentHash(String text) => fnv1a64Hex(utf8.encode(_pairSurrogates(text)));

String _pairSurrogates(String text) {
  const high = 0xD800, lowEnd = 0xDFFF, lowStart = 0xDC00;
  final units = text.codeUnits;
  StringBuffer? out;
  for (var i = 0; i < units.length; i++) {
    final u = units[i];
    if (u < high || u > lowEnd) {
      out?.writeCharCode(u);
      continue;
    }
    // A high surrogate is well-formed only when a low one follows it.
    final paired = u < lowStart &&
        i + 1 < units.length &&
        units[i + 1] >= lowStart &&
        units[i + 1] <= lowEnd;
    if (paired) {
      out?..writeCharCode(u)..writeCharCode(units[i + 1]);
      i++;
      continue;
    }
    out ??= StringBuffer(String.fromCharCodes(units.take(i)));
    out.write('?');
  }
  return out?.toString() ?? text;
}

/// Python's `str.splitlines` break set: \n \v \f \r \x1c \x1d \x1e \x85
///     (plus \r\n as one break).
bool _isLineBreak(int c) =>
    (c >= 0x0A && c <= 0x0D) || (c >= 0x1C && c <= 0x1E) || c == 0x85 || c == 0x2028 || c == 0x2029;

/// Split into lines *keeping* the line terminators, so joining the pieces
/// reproduces the input byte for byte. Matches Python's
/// `str.splitlines(keepends=True)` in what it treats as a break.
List<String> splitLinesKeepEnds(String text) {
  final lines = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (!_isLineBreak(c)) continue;
    final end = (c == 0x0D && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0A) ? i + 2 : i + 1;
    lines.add(text.substring(start, end));
    i = end - 1;
    start = end;
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
  // The marker is itself a line, so head + tail + marker must still fit
  // `maxLines` — with the shipped defaults this clamp never binds.
  final tailN = max(0, min(max(1, (maxLines * _tailRatio).truncate()), maxLines - headN - 1));
  final omitted = lines.length - headN - tailN;
  if (omitted <= 0) return text;
  final head = lines.sublist(0, headN);
  final tail = tailN > 0 ? lines.sublist(lines.length - tailN) : <String>[];
  final result = '${head.join()}  [... $omitted lines omitted ...]\n${tail.join()}';
  // Truncating many short lines costs more characters than it saves; the
  // budget is in characters, so hand back the original when that happens.
  // Characters, not UTF-16 code units, so the cutoff matches Python's.
  return result.runes.length < text.runes.length ? result : text;
}

String compressText(String text, {int maxLines = 80}) {
  if (text.isEmpty) return text;
  var result = stripNoise(text);
  result = headTailTruncate(result, maxLines);
  if (result.trim().isEmpty && text.trim().isNotEmpty) {
    result = splitLinesKeepEnds(text).first;
  }
  return result;
}

const List<String> _commentPrefixes = ['#', '//', '/*', '*', '---'];

String firstMeaningfulLine(String text) {
  final lines = splitLinesKeepEnds(text);
  for (final line in lines) {
    final stripped = line.trim();
    if (stripped.isNotEmpty && !_commentPrefixes.any(stripped.startsWith)) {
      return stripped;
    }
  }
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

// What an error looks like in a tool result, whatever the language it is
// reported in: the structural traces first (exit codes, stack frames), then
// the word for it in the languages agents commonly work in. A result whose
// call *failed* is treated as an error without consulting this at all.
final RegExp _errorMarker = RegExp(
  r'\b(error|traceback|exception|failed|denied|fatal|panic|fehler|erreur|errore)\b'
  // A process that exited non-zero: the whole code, not its first digit, and
  // never a bare "status" (an HTTP "status: 200" is not a failure).
  r'|\b(?:exit(?: code| status)?|returncode)[=: ]+(?!0+\b)\d{1,3}\b'
  // A stack frame's file:line. The token before the colon must contain a
  // non-digit, so a clock time ("at 14:30") is not mistaken for a frame.
  r'|\bline \d+, in \b|\bat [^\n]*[^\s:\d][^\s:]*:\d+'
  r'|エラー|失敗|例外|错误|失败|异常|오류|실패|ошибка|исключение',
  caseSensitive: false,
);

/// The compressed form of an old tool result: cleared down to its first line
/// and size — the model already acted on it — unless the call failed or the
/// text reports an error, which stays readable (head and tail) because errors
/// are what a later step most often needs to look back at.
String maskObservation(String text, {int maxLines = 40, bool failed = false}) =>
    failed || _errorMarker.hasMatch(text) ? compressText(text, maxLines: maxLines) : summarizeText(text);

final RegExp _identifier = RegExp(r'[A-Za-z0-9_][\w./:-]*[\w/]');
final RegExp _digit = RegExp(r'[0-9]');
final RegExp _punctuation = RegExp(r'[./:_-]');

/// Identifier-like tokens of [entry] (paths, ids, numbers, names with digits
/// or punctuation) that never occur in [transcript]: the parts a summary
/// could only have invented.
bool _isAlnum(int? unit) {
  if (unit == null) return false;
  return (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A);
}

/// Whether [token] occurs in [haystack] on its own, rather than buried
/// inside a longer run of letters and digits.
///
/// A plain `contains` grounds an invented "order 942" on an unrelated
/// "commit 8942", which is exactly the fabrication the caller is trying to
/// catch. Punctuation still counts as a boundary, so "src/main.py" is
/// grounded by "a/src/main.py:42".
bool _grounded(String haystack, String token) {
  var start = haystack.indexOf(token);
  while (start >= 0) {
    final end = start + token.length;
    final before = start == 0 ? null : haystack.codeUnitAt(start - 1);
    final after = end < haystack.length ? haystack.codeUnitAt(end) : null;
    if (!_isAlnum(before) && !_isAlnum(after)) return true;
    start = haystack.indexOf(token, start + 1);
  }
  return false;
}

List<String> ungrounded(String entry, String transcript) {
  final haystack = transcript.toLowerCase();
  return [
    for (final match in _identifier.allMatches(entry))
      if (match[0]!.length >= 3 &&
          (_digit.hasMatch(match[0]!) || _punctuation.hasMatch(match[0]!)) &&
          !_grounded(haystack, match[0]!.toLowerCase()))
        match[0]!,
  ];
}

