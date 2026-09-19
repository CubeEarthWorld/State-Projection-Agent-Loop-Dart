/// Token estimation utilities.
///
/// Budgets are enforced against a conservative estimate, never an exact
/// tokenizer count. The estimator is pluggable via [setEstimator] so a real
/// tokenizer can be swapped in when precision matters.
///
/// Heuristic: CJK characters count as ~1 token each, everything else as ~1
/// token per 4 characters. This overestimates slightly for English and is
/// close for Japanese, which keeps budget enforcement on the safe side.
library;


import 'messages.dart';
import 'serialization.dart';

const List<List<int>> _cjkRanges = [
  [0x1100, 0x11FF], // Hangul Jamo
  [0x2E80, 0x2FDF], // CJK radicals
  [0x3000, 0x303F], // CJK punctuation
  [0x3040, 0x30FF], // Hiragana / Katakana
  [0x3130, 0x318F], // Hangul compatibility Jamo
  [0x3400, 0x4DBF], // CJK ext A
  [0x4E00, 0x9FFF], // CJK unified
  [0xAC00, 0xD7AF], // Hangul syllables
  [0xF900, 0xFAFF], // CJK compat ideographs
  [0xFF00, 0xFFEF], // fullwidth forms
];

bool _isCjk(int codeUnit) {
  for (final range in _cjkRanges) {
    if (codeUnit >= range[0] && codeUnit <= range[1]) return true;
  }
  return false;
}

int estimateTextTokens(String text) {
  if (text.isEmpty) return 0;
  var cjk = 0;
  for (final rune in text.runes) {
    if (_isCjk(rune)) cjk++;
  }
  final other = text.runes.length - cjk;
  return cjk + (other / 4).ceil();
}

typedef TokenEstimator = int Function(String text);

TokenEstimator _estimator = estimateTextTokens;

/// Replace the global token estimator (e.g. with a real tokenizer).
void setEstimator(TokenEstimator fn) {
  _estimator = fn;
}


/// Estimate tokens for text, message-like objects, lists, or maps.
/// What one image part costs: a provider's typical per-image charge.
/// Counting the base64 text instead would overshoot by two orders of
/// magnitude.
const int imageTokens = 1000;

int estimateTokens(Object? obj) {
  if (obj == null) return 0;
  if (obj is String) return _estimator(obj);
  if (obj is List) {
    return obj.fold<int>(0, (sum, x) => sum + estimateTokens(x));
  }
  if (obj is Message) {
    var total = 4 + estimateTokens(obj.content);
    for (final tc in obj.toolCalls) {
      total += 6 + _estimator(tc.name) + _estimator(dumps(tc.arguments));
    }
    return total;
  }
  if (obj is Map) {
    if (obj['type'] == 'image_url' || obj['type'] == 'image') return imageTokens;
    return _estimator(dumps(obj));
  }
  return _estimator(obj.toString());
}

/// The longest prefix of [text] that fits [maxTokens].
String truncateToTokens(String text, int maxTokens) {
  if (estimateTokens(text) <= maxTokens) return text;
  var lo = 0;
  var hi = text.length;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (estimateTokens(text.substring(0, mid)) <= maxTokens) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return text.substring(0, lo);
}
