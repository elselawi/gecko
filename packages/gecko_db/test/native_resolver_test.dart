import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

class _Storage implements ResolverStorage {
  final files = <String, List<int>>{};
  final directories = <String>[];

  @override
  bool exists(String path) => files.containsKey(path);

  @override
  List<int> read(String path) => List<int>.from(files[path]!);

  @override
  void write(String path, List<int> bytes) =>
      files[path] = List<int>.from(bytes);

  @override
  void createDirectory(String path) => directories.add(path);
}

class _Downloader implements ResolverDownloader {
  _Downloader(this.bytes);
  final List<int> bytes;
  final requested = <Uri>[];

  @override
  Future<List<int>> download(Uri uri) async {
    requested.add(uri);
    return List<int>.from(bytes);
  }
}

NativeArtifact _artifact(List<int> bytes, {String? bundled, Uri? uri}) =>
    NativeArtifact(
      version: '1.0.0',
      sha256: sha256.convert(bytes).toString(),
      bundledPath: bundled,
      downloadUri: uri,
    );

void main() {
  test(
    'prefers valid override/local path before cache/bundle/download',
    () async {
      final storage = _Storage();
      final good = [1, 2, 3];
      storage.files['local'] = good;
      final downloader = _Downloader(good);
      final resolver = NativeResolver(
        storage: storage,
        downloader: downloader,
        cacheDirectory: 'cache',
      );
      final result = await resolver.resolve(
        _artifact(good, uri: Uri.parse('https://x')),
        localPaths: ['local'],
      );
      expect(result, 'local');
      expect(downloader.requested, isEmpty);
    },
  );

  test('skips invalid local and falls back to bundled', () async {
    final storage = _Storage()
      ..files['bad'] = [9]
      ..files['bundle'] = [1, 2];
    final good = [1, 2];
    final resolver = NativeResolver(storage: storage, cacheDirectory: 'cache');
    expect(
      await resolver.resolve(
        _artifact(good, bundled: 'bundle'),
        localPaths: ['bad'],
      ),
      'bundle',
    );
  });

  test('downloads pinned artifact and caches by version plus sha', () async {
    final storage = _Storage();
    final good = [4, 5, 6];
    final downloader = _Downloader(good);
    final resolver = NativeResolver(
      storage: storage,
      downloader: downloader,
      cacheDirectory: 'cache',
    );
    final artifact = _artifact(good, uri: Uri.parse('https://release/pinned'));
    final first = await resolver.resolve(artifact);
    expect(first, 'cache${Platform.pathSeparator}1.0.0-${artifact.sha256}');
    expect(downloader.requested, hasLength(1));
    expect(await resolver.resolve(artifact), first);
    expect(downloader.requested, hasLength(1));
  });

  test('checksum mismatch is typed and bad downloads are not cached', () async {
    final storage = _Storage();
    final downloader = _Downloader([7, 8]);
    final artifact = NativeArtifact(
      version: '1.0.0',
      sha256: nativeArtifactSha256([1, 2]),
      downloadUri: Uri.parse('https://release/bad'),
    );
    expect(
      () => NativeResolver(
        storage: storage,
        downloader: downloader,
        cacheDirectory: 'cache',
      ).resolve(artifact),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.checksumMismatch,
        ),
      ),
    );
    expect(storage.files, isEmpty);
  });

  test('no candidate and no pinned URL is a typed invalid operation', () async {
    final resolver = NativeResolver(
      storage: _Storage(),
      cacheDirectory: 'cache',
    );
    expect(
      () => resolver.resolve(_artifact([1])),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.invalidOperation,
        ),
      ),
    );
  });

  test('manifest is stable JSON and path override is split', () async {
    final bytes = [1, 2];
    final artifact = _artifact(bytes, uri: Uri.parse('https://x'));
    final json = jsonDecode(nativeArtifactManifest(artifact)) as Map;
    expect(json['version'], '1.0.0');
    expect(json['sha256'], artifact.sha256);
    final storage = _Storage()..files['override'] = bytes;
    final resolver = NativeResolver(
      storage: storage,
      cacheDirectory: 'cache',
      overridePaths: 'missing${';'}override',
    );
    expect(await resolver.resolve(artifact), 'override');
  });
}
