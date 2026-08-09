/// Native implementation of host architecture detection (`dart:ffi`).
library;

import 'dart:ffi';
import 'dart:io';

/// Host CPU architecture mapped to the release-matrix keys. The `Abi` enum
/// uses names like `windows_x64`, `android_arm64`, `linux_ia32`. Returns null
/// when the architecture cannot be classified.
String? hostArchitecture() {
  final abi = Abi.current().toString().toLowerCase();
  if (abi.endsWith('x64')) return 'x64';
  if (abi.endsWith('arm64')) {
    return Platform.isAndroid ? 'arm64-v8a' : 'arm64';
  }
  if (abi.contains('arm')) return Platform.isAndroid ? 'armeabi-v7a' : 'arm';
  if (abi.contains('ia32')) return Platform.isAndroid ? 'x86' : 'x86';
  return abi;
}
