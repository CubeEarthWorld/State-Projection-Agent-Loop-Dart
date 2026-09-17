# Cross-language fixtures

`fixtures/*.json` is the contract between this package and the Python
package it is a port of: both test suites read the same files and must
produce the same outputs.

The expectations are generated from the Python implementation, which is the
reference. **They are not editable here.** To change one of the covered
functions, change it in both packages, regenerate with
`python spec/generate_fixtures.py` in the Python repository, and copy
`spec/fixtures/` across.

A fixture test failing here means this port has drifted — that is the whole
point of the file. Each of the divergences these fixtures cover
(two different content hashes, two glob dialects, two truncation rules, two
JSON separator styles) reached production unnoticed because nothing
compared the two implementations.

`projection.json` is one whole turn exactly as the model receives it
(messages and native tool schemas): no change to either package may alter a
byte of it unnoticed. `checklists_v1.json` is the checklist wire format, the
one fixture here that is authored by hand rather than generated.

## Bundled tool definitions

`tools/*.json` holds the definitions of the capabilities this package
bundles (`meta.*`, `state.*`, `planning.checklist.manage`, `meta.agent.spawn`).
They are data, shared byte for byte with the Python package, where they live
as package data under `src/state_projection_loop/builtin/defs/`. Handlers
stay in code — they are the part that genuinely differs per language.

Dart has no portable way to read its own package's data files at runtime, so
these are compiled into a string constant:

```
dart run tool/generate_defs.dart
```

That writes `lib/src/builtin/defs.g.dart`, which is committed and checked by
CI. To change a definition: edit it in the Python repository, copy
`spec/tools/` across, regenerate, and run both test suites.
