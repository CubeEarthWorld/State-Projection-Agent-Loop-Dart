/// Skills: progressive-disclosure instructions, expressed as capabilities.
///
/// A skill is a body of instructions the model should only read when it is
/// relevant. Making it a capability `skill.<name>.load` reuses every
/// discovery mechanism that already exists — it shows up in the TOC under
/// `skill`, in auto-selected candidates when the request matches its
/// summary, and in `meta.tool.find` — with no second index to maintain.
library;

import '../capability.dart';

/// Build the capability that loads one skill's instructions.
///
/// [name] is a lowercase identifier (`[a-z][a-z0-9_]*`); [summary] is the
/// one line the model sees before deciding to load the skill.
Capability skillCapability(String name, String text, {required String summary}) {
  return Capability.fromMap({
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
