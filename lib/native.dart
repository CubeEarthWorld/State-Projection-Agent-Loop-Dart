/// Native-only extras: the parts that need a real operating system.
///
/// These cannot be made platform-independent the way file persistence can
/// (see `src/fs.dart`) - reading skills off disk needs a real directory
/// and the filesystem/shell toolkit is a shell. Keeping them out of the
/// main
/// library is what lets `package:state_projection_loop/state_projection_loop.dart`
/// compile for web at all.
///
/// ```dart
/// import 'package:state_projection_loop/state_projection_loop.dart';
/// import 'package:state_projection_loop/native.dart'; // VM / Flutter only
/// ```
library;

export 'src/builtin/skills.dart' show skillCapability, loadSkills;
export 'src/builtin/toolkits.dart' show installToolkits;
