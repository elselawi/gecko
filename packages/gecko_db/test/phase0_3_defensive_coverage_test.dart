import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/native_database.dart';

class _MemoryResolverStorage implements ResolverStorage {
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

class _DelayedBackend implements RawBackend {
  _DelayedBackend(this.delay, this.delegate);
  final Duration delay;
  final RawBackend delegate;

  @override
  bool get isReadOnly => false;

  @override
  Future<Set<(String, ByteKey)>> applyBatch(RawBatch ops) async {
    await Future<void>.delayed(delay);
    return delegate.applyBatch(ops);
  }

  @override
  Future<RawSnapshot> snapshot() => delegate.snapshot();

  @override
  Future<bool> tableExists(String table) => delegate.tableExists(table);

  @override
  Future<List<String>> tables() => delegate.tables();

  @override
  Future<int> lastCommitSeq() => delegate.lastCommitSeq();

  @override
  Future<void> close() => delegate.close();
}

void main() {
  test('applyPatch handles a non-map existing row', () {
    final result = applyPatch(42, [const FieldPatch.set('a', 1)]);
    expect(result.row['a'], 1);
  });

  test('close waits for an admitted write to drain', () async {
    final db = await openNativeTestDatabase('defensive-drain');
    final backend = _DelayedBackend(
      const Duration(milliseconds: 20),
      db.engine.backend,
    );
    final engine = RawEngine(backend, inFlightBatchLimit: 1);
    final pending = engine.rawPut('t', ByteKey([1]), [1]);
    final drain = engine.drain();
    expect(engine.inFlightCount, 1);
    await drain;
    await pending;
    expect(engine.inFlightCount, 0);
  });

  test('format header rejects an out-of-range version', () {
    expect(
      () =>
          const FormatHeader(formatVersion: 256, packageVersion: 'x').encode(),
      throwsA(
        isA<GeckoError>().having(
          (error) => error.type,
          'type',
          GeckoErrorType.invalidOperation,
        ),
      ),
    );
  });

  test(
    'resolver skips invalid cache and invalid bundle before download',
    () async {
      final storage = _MemoryResolverStorage()
        ..files['cache/1.0.0-good'] = [9]
        ..files['bundle'] = [8];
      final good = [1, 2, 3];
      final downloader = _FakeDownloader(good);
      final resolver = NativeResolver(
        storage: storage,
        downloader: downloader,
        cacheDirectory: 'cache',
      );
      final artifact = NativeArtifact(
        version: '1.0.0',
        sha256: sha256.convert(good).toString(),
        bundledPath: 'bundle',
        downloadUri: Uri.parse('https://pinned'),
      );
      expect(
        await resolver.resolve(artifact),
        'cache${Platform.pathSeparator}1.0.0-${artifact.sha256}',
      );
      expect(downloader.calls, 1);
    },
  );
}

class _FakeDownloader implements ResolverDownloader {
  _FakeDownloader(this.bytes);
  final List<int> bytes;
  int calls = 0;

  @override
  Future<List<int>> download(Uri uri) async {
    calls++;
    return bytes;
  }
}
