/// Platform-specific FRB external-library resolution.
///
/// Native (VM) builds open an FFI dynamic library; web builds load the
/// wasm-bindgen glue pair from an HTTP URL. Dart's conditional export picks
/// the implementation that matches the compilation target.
library;

export 'external_library_loader_io.dart'
    if (dart.library.js_interop) 'external_library_loader_web.dart';
