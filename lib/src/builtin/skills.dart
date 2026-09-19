/// Skills: progressive-disclosure instructions, expressed as capabilities.
///
/// A skill is a body of instructions the model should only read when it is
/// relevant. Making it a capability `skill.<name>.load` reuses every
/// discovery mechanism that already exists — it shows up in the TOC under
/// `skill`, in auto-selected candidates when the request matches its
/// summary, and in `meta.tool.find` — with no second index to maintain.
library;

import 'dart:io';

import '../capability.dart';

/// Build the capability that loads one skill's instructions.
///
/// [name] is a lowercase identifier (`[a-z][a-z0-9_]*`); [summary] is the
/// one line the model sees before deciding to load the skill.
Capability skillCapability(String name, String text, {required String summary}) {
  return Capability.fromDict({
    'name': 'skill.$name.load',
    'category': 'skill',
    'card': {'summary': summary, 'tags': ['skill', name]},
    'spec': {
      'description': 'Load the instructions for the "$name" skill: $summary',
      'parameters': {'type': 'object', 'properties': {}},
    },
    'discovery': {'embedding_text': '$name $summary'},
    'execution': {'timeout_s': 5, 'retry_safety': 'pure'},
    'effects': [{'kind': 'none'}],
  }, handler: (Map<String, Object?> args) => text);
}

final RegExp _frontMatter = RegExp(r'^---\s*\n(.*?)\n---\s*\n', dotAll: true);

/// Every `<directory>/<skill>/SKILL.md` as a skill capability.
///
/// The file format is the one agent skill directories converge on: YAML
/// front matter with `name` and `description`, then the instructions. A
/// skill's text is data the model reads on request, never part of the
/// kernel; load only directories you trust.
List<Capability> loadSkills(String directory) {
  final files = [
    for (final entry in Directory(directory).listSync().whereType<Directory>())
      File('${entry.path}${Platform.pathSeparator}SKILL.md'),
  ]..sort((a, b) => a.path.compareTo(b.path));
  final skills = <Capability>[];
  for (final file in files) {
    if (!file.existsSync()) continue;
    final text = file.readAsStringSync().replaceAll('\r\n', '\n');
    final match = _frontMatter.firstMatch(text);
    final fields = <String, String>{};
    if (match != null) {
      for (final line in match.group(1)!.split('\n')) {
        final colon = line.indexOf(':');
        if (colon > 0) fields[line.substring(0, colon).trim()] = line.substring(colon + 1);
      }
    }
    String unquote(String v) => v.trim().replaceAll(RegExp(r'^[\x22\x27]|[\x22\x27]$'), '');
    final name = unquote(fields['name'] ?? file.parent.uri.pathSegments.where((p) => p.isNotEmpty).last)
        .toLowerCase()
        .replaceAll('-', '_');
    final description = unquote(fields['description'] ?? '');
    skills.add(skillCapability(name, match == null ? text : text.substring(match.end),
        summary: description.isEmpty ? 'The $name skill.' : description));
  }
  return skills;
}

