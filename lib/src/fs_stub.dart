/// Web (and anything else without `dart:io`): no filesystem.
///
/// Chosen by the conditional import in `fs.dart`. Returning `null` rather
/// than throwing here is deliberate: importing the library must stay free,
/// and only actually asking for file-backed persistence should fail.
library;

import 'fs.dart';

FileSystem? createFileSystem() => null;
