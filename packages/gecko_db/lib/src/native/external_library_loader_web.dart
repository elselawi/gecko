/// Web implementation of external-library resolution.
///
/// On the web there is no FFI dynamic library: FRB loads the wasm module from
/// a wasm-bindgen `--target no-modules` glue pair (`gecko_db_rust.js` +
/// `gecko_db_rust_bg.wasm`) served over HTTP. `nativeLibraryPath` is
/// interpreted as the glue URL prefix (ending with `/`) when provided;
/// otherwise the bundled artifact location is used.
library;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'native_resolver.dart' show bundledWebGluePrefix, bundledWebStem;

/// Resolves the FRB external library on the web (see file docs).
Future<ExternalLibrary?> resolveExternalLibrary({
  required String? nativeLibraryPath,
}) async {
  final webPrefix = nativeLibraryPath == null
      ? await bundledWebGluePrefix()
      : _ensureTrailingSlash(nativeLibraryPath);
  if (webPrefix == null) return null;
  return loadExternalLibrary(
    ExternalLibraryLoaderConfig(
      stem: bundledWebStem,
      ioDirectory: null,
      webPrefix: webPrefix,
      wasmBindgenName: 'wasm_bindgen',
    ),
  );
}

String _ensureTrailingSlash(String prefix) =>
    prefix.endsWith('/') ? prefix : '$prefix/';
