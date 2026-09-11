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
}
