// The cross-language contract.
//
// These fixtures are read by both packages' test suites. A change here that
// is not mirrored in the other language is exactly the kind of silent drift
// that produced two different content hashes, two different glob dialects
// and two different truncation rules — each of which only showed up in
// production. They are generated from the Python implementation; see
// spec/README.md.
import 'dart:convert';
import 'dart:io';

import 'package:state_projection_loop/src/capability.dart';
import 'package:state_projection_loop/src/compression.dart';
import 'package:state_projection_loop/src/policy.dart';
import 'package:state_projection_loop/src/serialization.dart';
import 'package:state_projection_loop/src/tokens.dart';
import 'package:test/test.dart';

Map<String, Object?> load(String name) => (jsonDecode(
      File('spec/fixtures/$name.json').readAsStringSync(),
    ) as Map).cast<String, Object?>();

List<Map<String, Object?>> cases(String name, String key) =>
    [for (final c in load(name)[key] as List) (c as Map).cast<String, Object?>()];

void main() {
  group('compression fixtures', () {
    for (final c in cases('compression', 'content_hash')) {
      test('contentHash ${jsonEncode(c['text'])}', () {
        expect(contentHash(c['text'] as String), equals(c['expected']));
      });
    }
    for (final c in cases('compression', 'strip_noise')) {
      test('stripNoise ${jsonEncode(c['text'])}', () {
        expect(stripNoise(c['text'] as String), equals(c['expected']));
      });
    }
    for (final c in cases('compression', 'summarize_text')) {
      test('summarizeText ${jsonEncode(c['text'])}', () {
        expect(summarizeText(c['text'] as String), equals(c['expected']));
      });
    }
    for (final c in cases('compression', 'head_tail_truncate')) {
      test('headTailTruncate ${jsonEncode(c['text'])} @${c['max_lines']}', () {
        expect(headTailTruncate(c['text'] as String, (c['max_lines'] as num).toInt()),
            equals(c['expected']));
      });
    }
  });

  group('policy glob fixtures', () {
    for (final c in cases('policy_glob', 'glob_match')) {
      test('globMatch ${jsonEncode(c['value'])} ~ ${jsonEncode(c['pattern'])}', () {
        expect(globMatch(c['value'] as String, c['pattern'] as String), equals(c['expected']));
      });
    }
  });

  group('capability fixtures', () {
    for (final c in cases('capability', 'synthesize_signature')) {
      test('synthesizeSignature ${c['name']}', () {
        expect(
          synthesizeSignature(
              c['name'] as String, (c['parameters'] as Map).cast<String, Object?>()),
          equals(c['expected']),
        );
      });
    }
    for (final c in cases('capability', 'api_name')) {
      test('toApiName ${c['name']}', () {
        expect(toApiName(c['name'] as String), equals(c['expected']));
      });
    }
  });

  group('serialization fixtures', () {
    for (final c in cases('serialization', 'dumps')) {
      test('dumps ${jsonEncode(c['value'])}', () {
        expect(dumps(c['value']), equals(c['expected']));
      });
    }
    for (final c in cases('serialization', 'estimate_tokens')) {
      test('estimateTokens ${jsonEncode(c['value'])}', () {
        expect(estimateTokens(c['value']), equals(c['expected']));
      });
    }
  });
}
