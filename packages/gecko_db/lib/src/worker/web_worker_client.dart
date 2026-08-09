/// Main-thread client for the reusable OPFS Web Worker
/// (`package:gecko_db/web/gecko_db_worker.dart`).
///
/// On the web, spawns a Dedicated Worker and speaks the JSON protocol from
/// `web_worker_protocol.dart`, exposing the same operation surface as
/// [`NativeWorkerClient`]. On the VM this is a stub that throws (there are no
/// Web Workers).
library;

export 'web_worker_client_io.dart'
    if (dart.library.js_interop) 'web_worker_client_web.dart';
