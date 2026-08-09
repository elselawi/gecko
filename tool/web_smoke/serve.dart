// Tiny static server for the web smoke test.
//
// Serves the compiled app from build/web_smoke/ at `/` and the FRB wasm glue
// from build/web_glue/ at `/native/web/wasm32/` (the URL the bundled artifact
// layout resolves to). Run with:
//
//   dart run tool/web_smoke/serve.dart
//
// then point headless Chrome at http://localhost:8080/.
library;

import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8080;
  final root = Directory('build/web_smoke');
  final glueRoot = Directory('build/web_glue');
  const glueUrlPrefix = '/native/web/wasm32/';

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
  // ignore: avoid_print
  print('serving http://localhost:$port/ (glue at $glueUrlPrefix)');
  await for (final request in server) {
    try {
      final path = request.uri.path;
      File file;
      if (path.startsWith('/packages/gecko_db/native/web/wasm32/')) {
        // The FRB web loader resolves the glue to the conventional
        // `packages/<package>/...` URL (Flutter web serves this prefix).
        final relative = path
            .substring('/packages/gecko_db/native/web/wasm32/'.length);
        file = File('${glueRoot.path}/$relative');
      } else if (path.startsWith(glueUrlPrefix)) {
        final relative = path.substring(glueUrlPrefix.length);
        file = File('${glueRoot.path}/$relative');
      } else if (path == '/' || path == '') {
        file = File('${root.path}/index.html');
      } else {
        final relative = path.replaceAll(RegExp(r'^/+'), '');
        file = File('${root.path}/$relative');
      }
      if (file.existsSync()) {
        final bytes = file.readAsBytesSync();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.parse(_contentType(file.path))
          // FRB's wasm runtime uses a Web-Worker pool with SharedArrayBuffer;
          // that requires a cross-origin isolated context (COOP/COEP).
          ..headers.set('Cross-Origin-Opener-Policy', 'same-origin')
          ..headers.set(
            'Cross-Origin-Embedder-Policy',
            'require-corp',
          )
          ..add(bytes);
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found: $path');
      }
    } catch (error) {
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('error: $error');
    } finally {
      await request.response.close();
    }
  }
}

String _contentType(String path) {
  if (path.endsWith('.js')) return 'application/javascript';
  if (path.endsWith('.wasm')) return 'application/wasm';
  if (path.endsWith('.html')) return 'text/html';
  if (path.endsWith('.json')) return 'application/json';
  return 'application/octet-stream';
}
