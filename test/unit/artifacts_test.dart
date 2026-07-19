// Artifact store: structured references never confuse literal strings
// (P0-6), previews, peek, run namespacing, move().
import 'package:state_projection_loop/state_projection_loop.dart';
import 'package:test/test.dart';

void main() {
  group('ReferenceForm', () {
    test('isRef', () {
      expect(isRef({r'$artifact': 'art_x'}), isTrue);
      expect(isRef(r'$h1'), isFalse);
      expect(isRef({r'$artifact': 'art_x', 'extra': 1}), isFalse);
      expect(isRef({'other': 'art_x'}), isFalse);
    });

    test('bare string never resolved', () {
      final store = ArtifactStore('run_1');
      final record = store.put('hello world');
      // A literal string that happens to equal the artifact id must NOT
      // be resolved — only the structured {"$artifact": ...} form is.
      final resolved = store.resolveArgs({'text': record.id});
      expect(resolved, equals({'text': record.id}));
    });

    test('structured ref is resolved', () {
      final store = ArtifactStore('run_1');
      final record = store.put({'a': 1});
      final resolved = store.resolveArgs({'payload': ref(record.id)});
      expect(resolved, equals({'payload': {'a': 1}}));
    });

    test('nested resolution', () {
      final store = ArtifactStore('run_1');
      final record = store.put([1, 2, 3]);
      final resolved = store.resolveArgs({
        'outer': {
          'inner': [ref(record.id), 'literal'],
        },
      });
      expect(
        resolved,
        equals({
          'outer': {
            'inner': [
              [1, 2, 3],
              'literal',
            ],
          },
        }),
      );
    });

    test('unknown ref passed through', () {
      final store = ArtifactStore('run_1');
      final resolved = store.resolveArgs({'x': ref('art_missing')});
      expect(resolved, equals({'x': ref('art_missing')}));
    });
  });

  group('PreviewAndPeek', () {
    test('refText contains id, type and preview', () {
      final store = ArtifactStore('run_1');
      final record = store.put('x' * 5000, source: 'demo.tool');
      final text = store.refText(record, previewTokens: 10);
      expect(text, contains(record.id));
      expect(text, contains('str'));
      expect(text, contains('demo.tool'));
    });

    test('peek query returns matching lines with context', () {
      final store = ArtifactStore('run_1');
      final record = store.put('a\nb\nneedle\nc\nd');
      final out = store.peek(record.id, query: 'needle');
      expect(out, contains('needle'));
    });

    test('peek range by line', () {
      final store = ArtifactStore('run_1');
      final record = store.put('l1\nl2\nl3\nl4');
      final out = store.peek(record.id, range: '2-3');
      expect(out, contains('l2'));
      expect(out, contains('l3'));
      expect(out, isNot(contains('l1')));
    });

    test('peek unknown id', () {
      final store = ArtifactStore('run_1');
      final out = store.peek('art_missing');
      expect(out, contains('unknown artifact'));
    });
  });

  group('Namespacing', () {
    test('move creates new id in target store', () {
      final parent = ArtifactStore('run_parent');
      final child = ArtifactStore('run_child');
      final childRecord = child.put({'result': 42}, source: 'child.tool');
      final moved = parent.move(childRecord);
      expect(moved.id, isNot(equals(childRecord.id)));
      expect(parent.get(moved.id), equals({'result': 42}));
      expect(parent.exists(childRecord.id), isFalse);
    });
  });
}
