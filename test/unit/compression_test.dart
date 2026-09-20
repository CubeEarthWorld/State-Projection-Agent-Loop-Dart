// Deterministic compression: noise stripping, head/tail truncation, the
// full compressText pipeline, one-line summaries, and content hashing.
//
// Ported from the Python package's tests/unit/test_compression.py. This
// module was the least tested and the most divergent of the two ports —
// contentHash and headTailTruncate had both drifted — so the behavioural
// tests live here and the exact expected values live in spec/fixtures.
import 'package:state_projection_loop/src/compression.dart';
import 'package:test/test.dart';

void main() {
  group('stripNoise', () {
    test('removes git diff headers', () {
      const text = 'diff --git a/foo.py b/foo.py\n'
          'index abc123..def456 100644\n'
          '--- a/foo.py\n'
          '+++ b/foo.py\n'
          '@@ -1,3 +1,4 @@\n'
          '+new line\n';
      final result = stripNoise(text);
      expect(result, isNot(contains('diff --git')));
      expect(result, isNot(contains('index abc')));
      expect(result, isNot(contains('--- a/')));
      expect(result, isNot(contains('+++ b/')));
      expect(result, isNot(contains('@@')));
      expect(result, contains('+new line'));
    });

    test('removes ansi escape codes', () {
      const text = '\x1b[32mgreen\x1b[0m normal \x1b[1;34mblue\x1b[0m';
      final result = stripNoise(text);
      expect(result, isNot(contains('\x1b')));
      expect(result, contains('green'));
      expect(result, contains('normal'));
      expect(result, contains('blue'));
    });

    test('collapses consecutive blank lines', () {
      final result = stripNoise('line1\n\n\n\n\nline2\n');
      expect(result, isNot(contains('\n\n\n')));
      expect(result, contains('line1'));
      expect(result, contains('line2'));
    });

    test('removes node_modules and friends', () {
      const text = 'src/main.py\n'
          'node_modules/foo/bar.js\n'
          '.venv/lib/site.py\n'
          '__pycache__/mod.cpython-313.pyc\n'
          'src/util.py\n';
      final result = stripNoise(text);
      expect(result, isNot(contains('node_modules')));
      expect(result, isNot(contains('.venv')));
      expect(result, isNot(contains('__pycache__')));
      expect(result, contains('src/main.py'));
      expect(result, contains('src/util.py'));
    });

    test('removes progress and download lines', () {
      const text = 'Progress: 50%\r'
          '[1/10] Downloading package foo\n'
          '[2/10] Installing bar\n'
          'actual content\n';
      final result = stripNoise(text);
      expect(result, isNot(contains('Progress:')));
      expect(result, isNot(contains('Downloading')));
      expect(result, isNot(contains('Installing')));
      expect(result, contains('actual content'));
    });

    test('empty input', () => expect(stripNoise(''), equals('')));

    test('text with no noise is unchanged', () {
      const text = 'def hello():\n    return 42\n';
      expect(stripNoise(text), equals(text));
    });
  });

  group('headTailTruncate', () {
    test('short text unchanged', () {
      const text = 'line1\nline2\nline3\n';
      expect(headTailTruncate(text, 10), equals(text));
    });

    test('exact limit unchanged', () {
      final text = [for (var i = 0; i < 10; i++) 'line$i\n'].join();
      expect(headTailTruncate(text, 10), equals(text));
    });

    test('preserves head and tail', () {
      final text = [for (var i = 0; i < 100; i++) 'line$i\n'].join();
      final result = headTailTruncate(text, 20);
      expect(result, contains('line0\n'));
      expect(result, contains('line1\n'));
      expect(result, contains('line99\n'));
      expect(result, contains('line98\n'));
      expect(result, contains('omitted'));
    });

    test('never empty for non-empty input', () {
      final text = [for (var i = 0; i < 200; i++) 'line$i'].join('\n');
      expect(headTailTruncate(text, 5).trim(), isNotEmpty);
    });

    test('single line', () => expect(headTailTruncate('hello\n', 1), equals('hello\n')));

    test('a trailing newline does not add a line', () {
      // splitlines(keepends=True) semantics: "a\nb\n" is two lines, not three.
      const text = 'a\nb\n';
      expect(splitLinesKeepEnds(text).length, equals(2));
      expect(splitLinesKeepEnds(text).join(), equals(text));
    });

    test('CRLF survives a round trip', () {
      const text = 'a\r\nb\r\n';
      expect(splitLinesKeepEnds(text).join(), equals(text));
    });
  });

  group('compressText', () {
    test('short text is idempotent', () {
      const text = 'def foo():\n    return 1\n';
      final once = compressText(text);
      expect(compressText(once), equals(once));
    });

    test('empty input', () => expect(compressText(''), equals('')));

    test('long output truncated', () {
      final text = [for (var i = 0; i < 200; i++) 'output line $i'].join('\n');
      final result = compressText(text, maxLines: 20);
      expect(result.split('\n').length, lessThanOrEqualTo(25));
    });

    test('noise stripped before truncation', () {
      const noise = 'diff --git a/x b/x\nindex 123..456 100644\n';
      final content = [for (var i = 0; i < 100; i++) 'real line $i'].join('\n');
      final result = compressText(noise + content, maxLines: 20);
      expect(result, isNot(contains('diff --git')));
      expect(result, contains('real line 0'));
    });

    test('a tighter line budget produces less', () {
      final text = [for (var i = 0; i < 100; i++) 'build output $i'].join('\n');
      expect(compressText(text, maxLines: 40).length,
          lessThanOrEqualTo(compressText(text, maxLines: 80).length));
    });

    test('preserves the first line', () {
      final text = 'ERROR: something failed\n'
          '${[for (var i = 0; i < 100; i++) '  at line $i'].join('\n')}';
      expect(compressText(text, maxLines: 40), contains('ERROR: something failed'));
    });
  });

  group('summarizeText', () {
    test('single short line unchanged',
        () => expect(summarizeText('All tests passed.'), equals('All tests passed.')));

    test('multiline produces a single line', () {
      final text = [for (var i = 0; i < 50; i++) 'line $i'].join('\n');
      final result = summarizeText(text);
      expect(result, isNot(contains('\n')));
      expect(result, contains('50 lines'));
    });

    test('empty input', () => expect(summarizeText(''), equals('')));

    test('skips comment lines', () {
      const text = '# comment\n// another comment\ndef real_code():\n    pass\n';
      expect(summarizeText(text), contains('real_code'));
    });

    test('long first line truncated', () {
      final text = '${'x' * 200}\nline2\nline3\n';
      final result = summarizeText(text);
      expect(result.length, lessThan(200));
      expect(result, contains('…'));
    });

    test('counts characters, not UTF-16 code units', () {
      // Five emoji are five characters; counting code units would say ten.
      final text = '🎌🎌🎌🎌🎌\nsecond line';
      expect(summarizeText(text), contains('17 chars')); // 22 if counted in UTF-16 code units
    });
  });

  group('firstMeaningfulLine', () {
    test('skips comments', () {
      expect(firstMeaningfulLine('# header\n/* block */\nactual content\n'),
          equals('actual content'));
    });

    test('empty text', () => expect(firstMeaningfulLine(''), equals('')));

    test('all comments returns the first', () {
      expect(firstMeaningfulLine('# only comments\n# more comments\n'),
          equals('# only comments'));
    });
  });

  group('contentHash', () {
    test('stable', () => expect(contentHash('hello world'), equals(contentHash('hello world'))));

    test('distinct inputs differ',
        () => expect(contentHash('hello'), isNot(equals(contentHash('world')))));

    test('length is 16', () => expect(contentHash('test').length, equals(16)));

    test('empty string', () => expect(contentHash('').length, equals(16)));
  });

  // One case per fixed bug; the Python package carries the same set.
  group('regressions', () {
    final noise = [for (var i = 0; i < 30; i++) 'line $i'].join('\n');

    test('an unpaired surrogate hashes the same in both ports', () {
      // Python hashes text.encode("utf-8", errors="replace"), which emits
      // "?"; Dart's encoder would substitute U+FFFD and the two ports would
      // disagree on the dedupe key for the same string.
      expect(contentHash('\uD800'), equals(contentHash('?')));
      expect(contentHash('a\uD800b'), equals(contentHash('a?b')));
      expect(contentHash('\uDC00'), equals(contentHash('?')));
      // A well-formed astral character is untouched by that substitution.
      expect(contentHash('\u{1F38C}'), isNot(equals(contentHash('?'))));
      // These are the values the Python port produces.
      expect(contentHash('\uD800'), equals('af63b24c8601a52e'));
      expect(contentHash('a\uD800b\u{1F38C}c'), equals('b759eebbb39004af'));
    });

    test('an HTTP status is not an error', () {
      // "status: 2" of "status: 200" used to match the exit-code pattern, so
      // a tool reporting an HTTP status was never compressed again.
      expect(maskObservation('HTTP status: 200 OK\n$noise'),
          equals('HTTP status: 200 OK  [31 lines, 249 chars]'));
    });

    test('a clock time is not a stack frame', () {
      expect(maskObservation('Meeting at 14:30 with Bob\n$noise'),
          startsWith('Meeting at 14:30 with Bob  ['));
    });

    test('a real failure still takes the error path', () {
      for (final report in ['exit code 1', 'exit status: 2', 'returncode=127', '  at foo.js:12']) {
        expect(maskObservation('$report\n$noise', maxLines: 10), contains('line 29'), reason: report);
      }
      expect(maskObservation('exit code 0\n$noise'), startsWith('exit code 0  ['));
    });

    test('truncation never lengthens the text', () {
      final text = '${[for (var i = 0; i < 41; i++) 'a'].join('\n')}\n'; // 41 one-char lines
      expect(headTailTruncate(text, 40), equals(text));
    });

    test('output never has more lines than the limit', () {
      final text = [for (var i = 0; i < 20; i++) '${'y' * 40}\n'].join();
      expect(splitLinesKeepEnds(headTailTruncate(text, 2)).length, lessThanOrEqualTo(2));
    });

    test('noise stripping handles CRLF', () {
      expect(stripNoise('diff --git a/f b/f\r\nindex 111..222 100644\r\nrest\r\n'), equals('rest\r\n'));
    });

    test('the fallback first line keeps its terminator', () {
      expect(compressText('diff --git a/x b/x\n'), equals('diff --git a/x b/x\n'));
    });

    test('a lone carriage return separates lines', () {
      expect(firstMeaningfulLine('#x\ry'), equals('y'));
    });

    test('every Python line break splits', () {
      final text = [for (var i = 0; i < 20; i++) 'x' * 20].join('\v');
      expect(headTailTruncate(text, 4),
          equals('${'x' * 20}\v${'x' * 20}\v  [... 17 lines omitted ...]\n${'x' * 20}'));
    });
  });
}
