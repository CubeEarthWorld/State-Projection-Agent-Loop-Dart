/// Versioned JSON-portable plans. Mutations validate a copy before committing.
library;

import 'dart:convert';
import 'ids.dart';

const checklistStatuses = [
  'pending',
  'in_progress',
  'blocked',
  'completed',
  'cancelled'
];
const checklistContextModes = ['name', 'summary', 'full'];
final _idPattern = RegExp(r'^[0-7][0-9A-HJKMNP-TV-Z]{25}$');

Object? _copy(Object? value) => jsonDecode(jsonEncode(value));

Map<String, Object?> _keys(Object? value, Set<String> allowed) {
  if (value is! Map || value.keys.any((k) => !allowed.contains(k))) {
    throw ArgumentError('Expected an object with only these fields: $allowed');
  }
  return value.cast<String, Object?>();
}

String _text(Object? value, String field, int limit, {bool empty = false}) {
  if (value is! String ||
      value.runes.length > limit ||
      (!empty && value.trim().isEmpty)) {
    throw ArgumentError(
        '$field must be a ${empty ? "possibly empty" : "nonempty"} string of at most $limit characters');
  }
  return value;
}

String _identifier(Object? value) {
  if (value is! String || value.length != 26 || !_idPattern.hasMatch(value)) {
    throw ArgumentError('id must be a canonical 26-character ULID');
  }
  return value;
}

String _choice(Object? value, List<String> choices, String name) {
  if (!choices.contains(value)) {
    throw ArgumentError('$name must be one of $choices');
  }
  return value as String;
}

Map<String, Object?> _item(Object? raw, {bool generate = false}) {
  final data = _keys(raw, {'id', 'text', 'status', 'notes'});
  return {
    'id': _identifier(
        data.containsKey('id') ? data['id'] : (generate ? newUlid() : null)),
    'text': _text(data['text'], 'text', 500),
    'status': _choice(data.containsKey('status') ? data['status'] : 'pending',
        checklistStatuses, 'status'),
    'notes': _text(
        data.containsKey('notes') ? data['notes'] : '', 'notes', 2000,
        empty: true),
  };
}

Map<String, Object?> _checklist(Object? raw) {
  final data = _keys(raw, {
    'id',
    'name',
    'include_in_context',
    'context_mode',
    'revision',
    'items'
  });
  if (data['include_in_context'] is! bool) {
    throw ArgumentError('include_in_context must be a boolean');
  }
  if (data['revision'] is! int || (data['revision'] as int) < 1) {
    throw ArgumentError('revision must be a positive integer');
  }
  final rawItems = data['items'];
  if (rawItems is! List || rawItems.length > 200) {
    throw ArgumentError('items must be an array with at most 200 entries');
  }
  final items = rawItems.map((x) => _item(x)).toList();
  if (items.map((x) => x['id']).toSet().length != items.length) {
    throw ArgumentError('duplicate item id');
  }
  if (items.where((x) => x['status'] == 'in_progress').length > 1) {
    throw ArgumentError(
        'At most one item per checklist may be in_progress; update items atomically to switch');
  }
  return {
    'id': _identifier(data['id']),
    'name': _text(data['name'], 'name', 200),
    'include_in_context': data['include_in_context'],
    'context_mode':
        _choice(data['context_mode'], checklistContextModes, 'context_mode'),
    'revision': data['revision'],
    'items': items,
  };
}

Map<String, Object?> _view(Map<String, Object?> data, [String mode = 'full']) {
  if (mode == 'name') return {'id': data['id'], 'name': data['name']};
  final result = Map<String, Object?>.from(_copy(data) as Map)..remove('items');
  final items = (data['items'] as List).cast<Map>();
  final counts = {
    for (final s in checklistStatuses)
      s: items.where((x) => x['status'] == s).length
  };
  final total = items.length;
  final remaining = total - counts['completed']! - counts['cancelled']!;
  final status = total == 0
      ? 'pending'
      : counts['cancelled'] == total
          ? 'cancelled'
          : remaining == 0
              ? 'completed'
              : counts['in_progress']! > 0
                  ? 'in_progress'
                  : counts['blocked']! > 0
                      ? 'blocked'
                      : 'pending';
  result.addAll({
    'status': status,
    'progress': {
      'total': total,
      ...counts,
      'remaining': remaining,
      'fraction': total > counts['cancelled']!
          ? counts['completed']! / (total - counts['cancelled']!)
          : 0.0
    },
  });
  if (mode == 'full') result['items'] = _copy(data['items']);
  return result;
}

/// Session-local plans. Returned maps never alias stored state.
/// Use Session.invoke('planning.checklist.manage', ...) for recorded, policy-checked edits.
class ChecklistStore {
  final Map<String, Map<String, Object?>> _lists = {};

  bool get isEmpty => _lists.isEmpty;

  Map<String, Object?> toDict() =>
      {'version': 1, 'checklists': _copy(_lists.values.toList())};

  static ChecklistStore fromDict(Object? raw) {
    final data = _keys(raw, {'version', 'checklists'});
    if (data['version'] is! int || data['version'] != 1) {
      throw ArgumentError('Unsupported checklist format version');
    }
    final values = data['checklists'];
    if (values is! List || values.length > 100) {
      throw ArgumentError(
          'checklists must be an array with at most 100 entries');
    }
    final store = ChecklistStore();
    for (final raw in values) {
      final value = _checklist(raw);
      final id = value['id'] as String;
      if (store._lists.containsKey(id)) {
        throw ArgumentError('duplicate checklist id');
      }
      store._lists[id] = value;
    }
    return store;
  }

  Object? execute(String action, [Map<String, Object?> args = const {}]) {
    const allowed = {
      'list': {'mode'},
      'get': {'id', 'mode'},
      'export': {'id'},
      'create': {'name', 'items', 'include_in_context', 'context_mode'},
      'import': {'document'},
      'delete': {'id', 'expected_revision'},
      'update': {
        'id',
        'expected_revision',
        'name',
        'items',
        'include_in_context',
        'context_mode'
      },
      'add_item': {'id', 'expected_revision', 'item'},
      'update_item': {'id', 'expected_revision', 'item_id', 'item'},
      'delete_item': {'id', 'expected_revision', 'item_id'},
    };
    if (!allowed.containsKey(action)) {
      throw ArgumentError('Unknown checklist action: $action');
    }
    _keys(args, allowed[action]!);
    final mode = _choice(
        args.containsKey('mode')
            ? args['mode']
            : (action == 'list' ? 'summary' : 'full'),
        checklistContextModes,
        'mode');
    if (action == 'list') {
      return [for (final v in _lists.values) _view(v, mode)];
    }
    if (action == 'export') {
      if (!args.containsKey('id')) return toDict();
      return {
        'version': 1,
        'checklists': [_copy(_get(args['id']))]
      };
    }
    if (action == 'import') {
      final incoming = fromDict(args['document']);
      if (incoming._lists.keys.any(_lists.containsKey)) {
        throw ArgumentError(
            'Checklist id already exists; import never overwrites local plans');
      }
      if (_lists.length + incoming._lists.length > 100) {
        throw ArgumentError('At most 100 checklists are allowed');
      }
      _lists.addAll(incoming._lists);
      return [for (final v in incoming._lists.values) _view(v)];
    }
    Map<String, Object?> value;
    if (action == 'create') {
      if (_lists.length >= 100) {
        throw ArgumentError('At most 100 checklists are allowed');
      }
      final rawItems = args.containsKey('items') ? args['items'] : [];
      if (rawItems is! List) throw ArgumentError('items must be an array');
      value = _checklist({
        'id': newUlid(),
        'revision': 1,
        'name': args['name'],
        'include_in_context': args.containsKey('include_in_context')
            ? args['include_in_context']
            : true,
        'context_mode':
            args.containsKey('context_mode') ? args['context_mode'] : 'summary',
        'items': [for (final x in rawItems) _item(x, generate: true)],
      });
    } else {
      final current = _get(args['id']);
      if (action == 'get') return _view(current, mode);
      if (args['expected_revision'] is! int ||
          args['expected_revision'] != current['revision']) {
        throw ArgumentError(
            'Revision conflict: read checklist first; expected_revision must be ${current['revision']}');
      }
      if (action == 'delete') {
        _lists.remove(current['id']);
        return {'deleted': current['id']};
      }
      value = Map<String, Object?>.from(_copy(current) as Map);
      if (action == 'update') {
        for (final key in [
          'name',
          'include_in_context',
          'context_mode',
          'items'
        ]) {
          if (args.containsKey(key)) value[key] = args[key];
        }
        if (value['items'] is! List) {
          throw ArgumentError('items must be an array');
        }
        value['items'] = [
          for (final x in value['items'] as List) _item(x, generate: true)
        ];
      } else if (action == 'add_item') {
        (value['items'] as List).add(_item(args['item'], generate: true));
      } else {
        final itemId = _identifier(args['item_id']);
        final items = value['items'] as List;
        final index = items.indexWhere((x) => (x as Map)['id'] == itemId);
        if (index < 0) throw ArgumentError('Unknown item id: $itemId');
        if (action == 'delete_item') {
          items.removeAt(index);
        } else {
          final patch = _keys(args['item'], {'text', 'status', 'notes'});
          (items[index] as Map).addAll(patch);
        }
      }
      value['revision'] = (value['revision'] as int) + 1;
      value = _checklist(value);
    }
    _lists[value['id'] as String] = value;
    return _view(value);
  }

  Map<String, Object?> _get(Object? raw) {
    final id = _identifier(raw);
    if (!_lists.containsKey(id)) {
      throw ArgumentError('Unknown checklist id: $id');
    }
    return _lists[id]!;
  }

  /// Bounded projection; visibility affects this section, not history/access.
  String render({int maxChars = 6000}) {
    if (maxChars < 100) return '';
    final lines = <String>[];
    final visible =
        _lists.values.where((v) => v['include_in_context'] == true).toList();
    var used = 0;
    for (final value in visible) {
      var line = jsonEncode(_view(value, value['context_mode'] as String));
      if (used + line.runes.length > maxChars - 100) {
        line = jsonEncode(_view(value, 'summary'));
      }
      if (used + line.runes.length > maxChars - 100) break;
      lines.add(line);
      used += line.runes.length + 1;
    }
    if (lines.length < visible.length) {
      lines.add(
          '[${visible.length - lines.length} more checklists omitted; use planning.checklist.manage.]');
    }
    return lines.join('\n');
  }
}
