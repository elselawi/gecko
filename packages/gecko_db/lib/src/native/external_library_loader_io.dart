/// Native (VM/FFI) implementation of external-library resolution.
library;

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'native_resolver.dart' show bundledArtifactPath;

/// Resolves the FRB external library on native platforms (an FFI dynamic
/// library). Uses the no-build-steps artifact bundled in the package when no
/// explicit path is given; falls back to the FRB default loader otherwise.
Future<ExternalLibrary?> resolveExternalLibrary({
  required String? nativeLibraryPath,
}) async {
  final effectiveLibraryPath = nativeLibraryPath ?? await bundledArtifactPath();
  return effectiveLibraryPath == null
      ? null
      : ExternalLibrary.open(effectiveLibraryPath);
}
