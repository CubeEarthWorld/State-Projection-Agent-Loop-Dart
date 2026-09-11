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
