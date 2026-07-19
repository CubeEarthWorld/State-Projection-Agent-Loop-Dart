/// Shared test helpers: quick capability-definition builders.
///
/// Port of `tests/_util.py`. Keys inside the returned map stay snake_case
/// (they feed `Capability.fromMap`, which parses them the same way Python's
/// `Capability.from_dict` does); only Dart-side identifiers are camelCase.
library;

String echoHandlerText(String text) => 'echo: $text';

/// Build a capability definition map. [name] should already be dotted
/// (e.g. `demo.echo.say`); a bare name is namespaced under `test.`.
Map<String, Object?> capabilityDict(
  String name, {
  String category = 'misc',
  String description = '',
  String? summary,
  List<String>? tags,
  String embeddingText = '',
  bool pinned = false,
  bool noEmbed = false,
  bool requireSpec = false,
  Map<String, Object?>? properties,
  List<String>? required,
  String retrySafety = 'never_retry',
  int retries = 0,
  double timeoutS = 30.0,
  List<(String, String)>? effects,
  int? maxInlineTokens,
  String overflow = 'artifact',
}) {
  var n = name;
  if (!n.contains('.')) {
    n = 'test.$n';
  }
  final parameters = <String, Object?>{
    'type': 'object',
    'properties': properties ?? <String, Object?>{},
  };
  if (required != null) {
    parameters['required'] = required;
  }
  final d = <String, Object?>{
    'name': n,
    'category': category,
    'spec': {
      'description': description.isNotEmpty ? description : '$n capability.',
      'parameters': parameters,
    },
    'discovery': {
      'pinned': pinned,
      'no_embed': noEmbed,
      'require_spec': requireSpec,
      'embedding_text': embeddingText,
    },
    'execution': {
      'timeout_s': timeoutS,
      'retries': retries,
      'retry_safety': retrySafety,
      'output_policy': {
        'max_inline_tokens': maxInlineTokens,
        'overflow': overflow,
      },
    },
    'effects': [
      for (final e in (effects ?? [('none', '*')])) {'kind': e.$1, 'resource': e.$2},
    ],
  };
  if (summary != null || tags != null) {
    d['card'] = {'summary': summary ?? '', 'tags': tags ?? <String>[]};
  }
  return d;
}

/// A plain handler that ignores args and returns `"$name ok"`.
Object? Function(Map<String, Object?> args) okHandlerFactory(String name) {
  return (Map<String, Object?> args) => '$name ok';
}
