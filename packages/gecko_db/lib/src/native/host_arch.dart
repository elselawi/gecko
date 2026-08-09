/// Host CPU architecture detection, split by platform because `dart:ffi`'s
/// `Abi` is not importable on the web.
library;

export 'host_arch_io.dart' if (dart.library.js_interop) 'host_arch_web.dart';
