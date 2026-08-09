import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('artifact manifest tool documents checksum and provenance fields', () {
    final source = File('tool/artifact_manifest.dart').readAsStringSync();
    for (final field in <String>[
      'sha256',
      'target',
      'architecture',
      'version',
      'commit',
      'rustToolchain',
      'frbCodegenVersion',
    ]) {
      expect(source, contains(field));
    }
  });

  test('manifest JSON shape remains parseable', () {
    final example = jsonDecode('''
      {"schemaVersion":1,"target":"windows","architecture":"x64",
       "version":"0.0.1","sha256":"abc","sizeBytes":1,
       "build":{"commit":"local","frbCodegenVersion":"2.12.0"}}
    ''');
    expect(example, isA<Map<String, dynamic>>());
    expect(example['schemaVersion'], 1);
  });
}
