/// Platform-independence check for the shared hash.
///
/// This file imports `hashing.dart` directly and nothing else, so it runs
/// under `dart test -p chrome` as well as on the VM. That matters: compiled
/// to JavaScript a Dart `int` is a double and bitwise operators truncate to
/// signed 32 bits, so a bitwise implementation passes on the VM and returns
/// different digests on web. Run both:
///
///     dart test test/unit/hashing_test.dart
///     dart test -p chrome test/unit/hashing_test.dart
///
/// Expected values come from `src/state_projection_loop/hashing.py`; they
/// are also the published FNV-1a test vectors.
library;

import 'dart:convert';

import 'package:state_projection_loop/src/hashing.dart';
import 'package:test/test.dart';

void main() {
  group('fnv1a64Hex', () {
    const vectors = <String, String>{
      '': 'cbf29ce484222325', // the offset basis, unchanged by no input
      'a': 'af63dc4c8601ec8c',
      'hello': 'a430d84680aabd0b',
      'L0\nL1\n': '77a4642e5c602958',
      '日本語🎌テスト': '2ec7e12cceb37226',
    };

    vectors.forEach((input, expected) {
      test('${jsonEncode(input)} hashes to $expected', () {
        expect(fnv1a64Hex(utf8.encode(input)), expected);
      });
    });

    test('always 16 lowercase hex digits, never sign-prefixed', () {
      for (var i = 0; i < 400; i++) {
        final digest = fnv1a64Hex(utf8.encode('sample-$i'));
        expect(digest, matches(RegExp(r'^[0-9a-f]{16}$')), reason: digest);
      }
    });

    test('high half is exercised, not left at the offset basis', () {
      // The prime's high word is 0x100; dropping it still produces correct
      // low 32 bits, so only the high half catches that class of bug.
      final highHalves = {
        for (var i = 0; i < 50; i++) fnv1a64Hex(utf8.encode('x$i')).substring(0, 8)
      };
      expect(highHalves.length, greaterThan(40));
    });
  });

  group('fnv1a32', () {
    test('matches the published vectors', () {
      expect(fnv1a32(utf8.encode('')), 0x811C9DC5);
      expect(fnv1a32(utf8.encode('a')), 0xE40C292C);
      expect(fnv1a32(utf8.encode('foobar')), 0xBF9CF968);
    });

    test('stays a non-negative 32-bit value', () {
      for (var i = 0; i < 400; i++) {
        final h = fnv1a32(utf8.encode('sample-$i'));
        expect(h, greaterThanOrEqualTo(0));
        expect(h, lessThan(0x100000000));
      }
    });
  });
}
