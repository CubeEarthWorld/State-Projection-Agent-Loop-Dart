// Capability contracts: naming, retry-safety/retries coupling, effects,
// concurrency policy, map-based construction.
//
// SKIPPED: Python's TestDecorator (`@capability` decorator / bare-function
// introspection via `inspect.signature`) and `build_capability_from_function`
// have no Dart equivalent (see lib/src/capability.dart library doc) — those
// scenarios are ported below using `Capability.fromMap` with an explicit
// map + handler instead, which is the only construction path in this port.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

// Not re-exported by the public barrel; needed directly for name-validation
// and api-name-encoding tests.
import 'package:state_projection_loop/src/capability.dart'
    show validateCapabilityName, toApiName, fromApiName;

void main() {
  group('Naming', () {
    test('valid names', () {
      for (final name in [
        'a.b',
        'a.b.c',
        'a.b.c.d',
        'a.b.c.d.e',
        'filesystem.file.read',
      ]) {
        expect(() => validateCapabilityName(name), returnsNormally);
      }
    });

    test('invalid names', () {
      for (final name in ['singleword', 'A.b', 'a..b', 'a.b.c.d.e.f', 'a.B']) {
        expect(() => validateCapabilityName(name), throwsArgumentError);
      }
    });

    test('qualified name', () {
      final cap = Capability(name: 'demo.thing', version: 3);
      expect(cap.qualifiedName, equals('demo.thing@3'));
    });
  });

  group('RetrySafetyGate', () {
    test('retries requires safe retry_safety', () {
      expect(
        () => CapabilityExecution(retries: 2, retrySafety: 'never_retry'),
        throwsArgumentError,
      );
      expect(
        () => CapabilityExecution(retries: 1, retrySafety: 'check_then_retry'),
        throwsArgumentError,
      );
    });

    test('retries allowed for pure and idempotent', () {
      CapabilityExecution(retries: 2, retrySafety: 'pure');
      CapabilityExecution(retries: 2, retrySafety: 'idempotent');
    });
  });

  group('ConcurrencyPolicy', () {
    test('exclusive_resource requires resourceKey', () {
      expect(() => ConcurrencyPolicy(mode: 'exclusive_resource'), throwsArgumentError);
      ConcurrencyPolicy(mode: 'exclusive_resource', resourceKey: 'db:accounts');
    });

    test('invalid mode', () {
      expect(() => ConcurrencyPolicy(mode: 'whenever'), throwsArgumentError);
    });
  });

  group('IsPure', () {
    test('no effects declared is not pure', () {
      final cap = Capability(name: 'demo.thing');
      expect(cap.isPure, isFalse);
    });

    test('none effect is pure', () {
      final cap = Capability(name: 'demo.thing', effects: [Effect(kind: 'none')]);
      expect(cap.isPure, isTrue);
    });

    test('write effect is not pure', () {
      final cap = Capability(
        name: 'demo.thing',
        effects: [Effect(kind: 'write', resource: 'workspace:*')],
      );
      expect(cap.isPure, isFalse);
    });
  });

  group('MapConstruction (replaces decorator tests)', () {
    test('ctx handler excludes ctx from schema, keeps declared params', () {
      final cap = Capability.fromMap(
        {
          'name': 'demo.op',
          'spec': {
            'parameters': {
              'type': 'object',
              'properties': {
                'path': {'type': 'string'},
                'verbose': {'type': 'boolean', 'default': false},
              },
              'required': ['path'],
            },
          },
        },
        handler: (ToolContext ctx, Map<String, Object?> args) => args['path'],
        wantsCtx: true,
      );
      expect(cap.spec.parameters['properties'], isNot(contains('ctx')));
      final props = cap.spec.parameters['properties'] as Map;
      expect((props['verbose'] as Map)['default'], isFalse);
      expect(cap.wantsCtx, isTrue);
    });

    test('effects and execution options round-trip', () {
      final cap = Capability.fromMap(
        {
          'name': 'demo.write',
          'execution': {'retry_safety': 'idempotent', 'timeout_s': 5.0},
          'effects': [
            {'kind': 'write', 'resource': 'workspace:*'},
          ],
        },
        handler: (Map<String, Object?> args) => args['path'],
      );
      expect(cap.execution.retrySafety, equals('idempotent'));
      expect(cap.effects.length, equals(1));
      expect(cap.effects.first.kind, equals('write'));
      expect(cap.effects.first.resource, equals('workspace:*'));
      expect(cap.execution.timeoutS, equals(5.0));
    });
  });

  group('Projections', () {
    test('card and spec text', () {
      final cap = Capability.fromMap(
        {
          'name': 'demo.read',
          'card': {'summary': 'reads a thing'},
        },
        handler: (Map<String, Object?> args) => args['path'],
      );
      expect(cap.cardText(), contains('demo.read'));
      expect(cap.specText(), contains('demo.read@1'));
    });

    test('api schema shape', () {
      final cap = Capability.fromMap(
        {'name': 'demo.op'},
        handler: (Map<String, Object?> args) => args['x'],
      );
      final schema = cap.apiSchema();
      expect(schema['type'], equals('function'));
      // dots are encoded ("__") for provider-safe function names — most
      // native-function-calling providers (OpenAI included) reject "."
      final fn = schema['function'] as Map;
      expect(fn['name'], equals('demo__op'));
      expect(fn['name'], equals(cap.apiName));
      expect(fn, contains('parameters'));
    });

    test('api name round-trips through registry', () {
      expect(toApiName('demo.op'), equals('demo__op'));
      expect(fromApiName('demo__op'), equals('demo.op'));
    });
  });
}
