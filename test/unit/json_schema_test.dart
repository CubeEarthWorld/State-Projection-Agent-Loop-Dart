// The package's one JSON Schema validator. Hand-written cases: an oracle
// independent of the generated fixtures.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

void main() {
  group('Validator', () {
    // The dependency-free fallback (the only validator in this port).
    final schema = <String, Object?>{
      'type': 'object',
      'properties': {
        'q': {'type': 'string', 'minLength': 2},
        'n': {'type': 'integer', 'minimum': 1, 'maximum': 10},
        'mode': {
          'enum': ['a', 'b']
        },
        'items': {
          'type': 'array',
          'items': {'type': 'string'}
        },
        'opt': {
          'type': ['string', 'null']
        },
      },
      'required': ['q'],
      'additionalProperties': false,
    };

    test('accepts valid', () {
      expect(
        validateValue(schema, {'q': 'ok', 'n': 5, 'mode': 'a', 'items': ['x'], 'opt': null}),
        isNull,
      );
    });

    final rejectCases = <(Map<String, Object?>, String)>[
      ({}, 'required'),
      ({'q': 'ok', 'n': '5'}, 'expected type'),
      ({'q': 'ok', 'n': 0}, 'minimum'),
      ({'q': 'ok', 'n': 11}, 'maximum'),
      ({'q': 'x'}, 'minLength'),
      ({'q': 'ok', 'mode': 'c'}, 'not one of'),
      ({'q': 'ok', 'items': ['x', 1]}, 'expected type'),
      ({'q': 'ok', 'zzz': 1}, 'unexpected properties'),
      ({'q': 'ok', 'n': true}, 'expected type'),
    ];

    for (final (args, fragment) in rejectCases) {
      test('rejects invalid: $args', () {
        expect(validateValue(schema, args), contains(fragment));
      });
    }

    test('validateArgs agrees', () {
      expect(validateArgs(schema, {'q': 'ok'}), isNull);
      expect(validateArgs(schema, {'q': 1}), isNotNull);
      expect(validateArgs(schema, 'not a dict'), isNotNull);
    });

    test('applyDefaults', () {
      final defSchema = <String, Object?>{
        'type': 'object',
        'properties': {
          'k': {'type': 'integer', 'default': 7},
        },
      };
      expect(applyDefaults(defSchema, {}), equals({'k': 7}));
      expect(applyDefaults(defSchema, {'k': 1}), equals({'k': 1}));
    });
  });
}
