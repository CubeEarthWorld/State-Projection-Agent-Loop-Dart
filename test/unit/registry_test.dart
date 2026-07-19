// Registry: registration, TOC (layer 1), providers & epoch, versioned
// lookup, sub-agent scoping.
//
// SKIPPED: Python's test_register_decorated_function and
// test_register_plain_function_autogenerates rely on `@capability`
// decorator / bare-function introspection, which has no Dart equivalent
// (see lib/src/capability.dart library doc) — registration here always
// goes through `Registry.register(map, handler: ..., wantsCtx: ...)`.
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

import '../util.dart';

void main() {
  group('Registration', () {
    test('register dict with handler', () {
      final reg = Registry();
      final cap = reg.register(capabilityDict('demo.t1'), handler: okHandlerFactory('t1'));
      expect(reg.contains('demo.t1'), isTrue);
      expect(reg.get('demo.t1'), same(cap));
      expect(reg.length, equals(1));
    });

    test('duplicate raises unless replace', () {
      final reg = Registry();
      reg.register(capabilityDict('demo.t1'));
      expect(
        () => reg.register(capabilityDict('demo.t1')),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('already registered'))),
      );
      reg.register(capabilityDict('demo.t1'), replace: true);
      expect(reg.length, equals(1));
    });

    test('epoch bumps on mutation', () {
      final reg = Registry();
      final e0 = reg.epoch;
      reg.register(capabilityDict('demo.t1'));
      expect(reg.epoch, equals(e0 + 1));
      reg.unregister('demo.t1');
      expect(reg.epoch, equals(e0 + 2));
      reg.unregister('demo.missing'); // no-op does not bump
      expect(reg.epoch, equals(e0 + 2));
    });

    test('invalid name rejected', () {
      final bad = capabilityDict('demo.t1');
      bad['name'] = 'singleword';
      expect(
        () => Registry().register(bad),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('dotted'))),
      );
    });
  });

  group('Versioning', () {
    test('bare name resolves to latest', () {
      final reg = Registry();
      reg.register({...capabilityDict('demo.thing'), 'version': 1});
      reg.register({...capabilityDict('demo.thing'), 'version': 2});
      expect(reg.get('demo.thing')!.version, equals(2));
      expect(reg.get('demo.thing@1')!.version, equals(1));
      expect(reg.length, equals(1)); // counts distinct names, not versions
    });

    test('unregister by bare name drops all versions', () {
      final reg = Registry();
      reg.register({...capabilityDict('demo.thing'), 'version': 1});
      reg.register({...capabilityDict('demo.thing'), 'version': 2});
      reg.unregister('demo.thing');
      expect(reg.get('demo.thing'), isNull);
      expect(reg.get('demo.thing@1'), isNull);
    });
  });

  group('Toc', () {
    test('categories and toc text', () {
      final reg = Registry();
      reg.register(capabilityDict('web.search.s1', category: 'web/search'));
      reg.register(capabilityDict('web.search.s2', category: 'web/search'));
      reg.register(capabilityDict('file.f1', category: 'file'));
      reg.register(capabilityDict('misc.m1', category: '')); // -> misc
      expect(reg.categories(), equals({'file': 1, 'misc': 1, 'web/search': 2}));
      expect(reg.tocText(), equals('file(1) misc(1) web/search(2)'));
    });

    test('toc collapses when categories explode', () {
      final reg = Registry();
      for (var i = 0; i < 80; i++) {
        reg.register(capabilityDict('area${i % 4}.sub.t$i', category: 'area${i % 4}/sub$i'));
      }
      final toc = reg.tocText(maxCategories: 60);
      expect(toc, equals('area0(20) area1(20) area2(20) area3(20)'));
      expect(estimateTokens(toc), lessThan(100));
    });
  });

  group('Providers', () {
    test('attach and refresh', () {
      final reg = Registry();
      final provider = _ListProvider([
        capabilityDict('ext.a', category: 'ext'),
        capabilityDict('ext.b', category: 'ext'),
      ]);
      reg.attachProvider(provider);
      expect(reg.contains('ext.a'), isTrue);
      expect(reg.contains('ext.b'), isTrue);
      final epoch = reg.epoch;

      provider.defs = [
        capabilityDict('ext.a', category: 'ext'),
        capabilityDict('ext.c', category: 'ext'),
      ];
      reg.refreshProviders();
      expect(reg.contains('ext.c'), isTrue);
      expect(reg.contains('ext.b'), isFalse);
      expect(reg.epoch, greaterThan(epoch));
    });

    test('refresh without change keeps epoch', () {
      final reg = Registry();
      final provider = _ListProvider([
        capabilityDict('ext.a', category: 'ext'),
        capabilityDict('ext.b', category: 'ext'),
      ]);
      reg.attachProvider(provider);
      final current = [reg.get('ext.a')!, reg.get('ext.b')!];
      provider.defs = current;
      final epoch = reg.epoch;
      reg.refreshProviders();
      expect(reg.epoch, equals(epoch));
    });
  });

  group('Subset', () {
    Registry buildRegistry() {
      final reg = Registry();
      reg.register(capabilityDict('web.search.query', category: 'web/search'));
      reg.register(capabilityDict('web.fetch.url', category: 'web/fetch'));
      reg.register(capabilityDict('file.read', category: 'file'));
      reg.register(capabilityDict('game.flags.set', category: 'game/flags'));
      return reg;
    }

    test('by name category and prefix', () {
      final reg = buildRegistry();
      final sub = reg.subset(['file.read', 'web/*']);
      final names = sub.all().map((c) => c.name).toList()..sort();
      expect(names, equals(['file.read', 'web.fetch.url', 'web.search.query']));
    });

    test('exact category', () {
      final reg = buildRegistry();
      final sub = reg.subset(['game/flags']);
      expect(sub.all().map((c) => c.name).toList(), equals(['game.flags.set']));
    });

    test('empty scope gives empty registry', () {
      final reg = buildRegistry();
      expect(reg.subset([]).length, equals(0));
    });
  });
}

class _ListProvider implements ToolProvider {
  _ListProvider(this.defs);
  List<Object> defs;

  @override
  Iterable<Object> provide() => List<Object>.from(defs);
}
