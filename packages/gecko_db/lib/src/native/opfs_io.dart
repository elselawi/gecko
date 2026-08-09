/// Native (VM) OPFS stub: OPFS persistence is web-only.
library;

/// Always reports that OPFS is unavailable on the VM. The caller (the web
/// worker open path) surfaces this as a typed error explaining the
/// requirement.
Future<String?> registerOpfsHandle(String path) async =>
    'OPFS persistence is only available on the web, inside a Web Worker '
    '(the wasm engine needs a FileSystemSyncAccessHandle). On this platform '
    'use a filesystem path instead.';
