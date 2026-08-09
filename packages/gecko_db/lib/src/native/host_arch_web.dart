/// Web implementation of host architecture detection.
///
/// There is no FFI `Abi` on the web; the wasm build is architecture-neutral
/// from Dart's perspective. Callers that need a real architecture must be on
/// the VM (bundled FFI artifacts), so this always returns null.
library;

/// Always null on the web — see file docs.
String? hostArchitecture() => null;
