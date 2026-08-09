// Workstream 2 — backend differential and conformance testing (raw level).
//
// Replays identical, deterministic operation scripts against the in-memory
// backend and the native file-backed backend (each wrapped in a `RawEngine`)
// and asserts byte-equivalent snapshots, identical results and typed error
// categories, identical LSNs, and identical change-feed batches after every
// step. See `test/support/differential.dart` for the harness.
import 'dart:convert';
import 'dart:io';

import 'package:gecko_db/gecko_db.dart';
import 'package:test/test.dart';

import 'support/differential.dart';

String _repoRoot() {
  if (Directory.current.path.endsWith(
    'packages${Platform.pathSeparator}gecko_db',
  )) {
    return Directory.current.parent.parent.path;
  }
  return Directory.current.path;
}

String _nativeLibraryPath(String root) {
  final name = Platform.isWindows
      ? 'gecko_db_rust.dll'
      : Platform.isMacOS
      ? 'libgecko_db_rust.dylib'
      : 'libgecko_db_rust.so';
  return '$root${Platform.pathSeparator}rust${Platform.pathSeparator}'
      'target${Platform.pathSeparator}release${Platform.pathSeparator}$name';
}

List<int> _bytes(List<int> bytes) => List<int>.from(bytes);

void main() {
  final root = _repoRoot();
  final nativePath = _nativeLibraryPath(root);

  late Directory tempDir;
  late String nativeDbPath;
  late RawEngine memoryEngine;
  late RawEngine nativeEngine;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('gecko-diff-');
    nativeDbPath = '${tempDir.path}${Platform.pathSeparator}db.redb';
    memoryEngine = RawEngine(InMemoryBackend());
    nativeEngine = RawEngine(
      await NativeRawBackend.open(nativeDbPath, nativeLibraryPath: nativePath),
    );
  });

  tearDown(() async {
    await memoryEngine.dispose();
    await nativeEngine.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<void> expectDifferential(List<DiffStep> steps) async {
    final outcome = await runDifferential(memoryEngine, nativeEngine, steps);
    expect(outcome.mismatches, isEmpty, reason: outcome.mismatches.join('\n'));
  }

  group('raw differential', () {
    test('put/update/insert-only/update-only/delete/clear and scans', () async {
      const k1 = [0x01];
      const k2 = [0x02];
      const k3 = [0x03];
      await expectDifferential([
        // Missing-key reads.
        const DiffGet('items', k1),
        const DiffScanAll('items'),
        const DiffRangeScan('items'),
        // Upserts.
        const DiffPut('items', k1, [0x61]),
        const DiffPut('items', k2, [0x62]),
        const DiffPut('items', k3, [0x63]),
        const DiffGet('items', k1),
        const DiffGet('items', [0x09]),
        // Update.
        const DiffPut('items', k1, [0x41]),
        const DiffGet('items', k1),
        // insertOnly: new key succeeds, existing key is a typed error.
        const DiffPut('items', [0x09], [0x69], mode: RawWriteMode.insertOnly),
        const DiffPut('items', k2, [0x42], mode: RawWriteMode.insertOnly),
        // updateOnly: existing key succeeds, missing key is a typed error.
        const DiffPut('items', k3, [0x43], mode: RawWriteMode.updateOnly),
        const DiffPut('items', [0x0A], [0x6A], mode: RawWriteMode.updateOnly),
        // Scans with bounds.
        const DiffRangeScan('items', start: [0x02], end: [0x03]),
        const DiffRangeScan('items', start: [0x02]),
        const DiffRangeScan('items', end: [0x02]),
        const DiffScanAll('items'),
        // Delete present and missing.
        const DiffDelete('items', k2),
        const DiffGet('items', k2),
        const DiffDelete('items', k2),
        const DiffScanAll('items'),
        // Clear + empty scans.
        const DiffClear('items'),
        const DiffScanAll('items'),
        const DiffRangeScan('items'),
        const DiffGet('items', k1),
      ]);
    });

    test('multi-operation and multi-table atomic batches', () async {
      await expectDifferential([
        // One atomic batch spanning three tables.
        DiffBackendBatch([
          RawPut('items', ByteKey(_bytes([0x01])), _bytes([0x61])),
          RawPut('items', ByteKey(_bytes([0x02])), _bytes([0x62])),
          RawPut('users', ByteKey(_bytes([0x01])), _bytes([0x75, 0x31])),
          RawPut('orders', ByteKey(_bytes([0x01])), _bytes([0x6F, 0x31])),
        ]),
        // Same-key overwrite and delete in one batch (last op wins).
        DiffBackendBatch([
          RawPut('items', ByteKey(_bytes([0x01])), _bytes([0x41])),
          RawDelete('items', ByteKey(_bytes([0x01]))),
          RawPut('items', ByteKey(_bytes([0x01])), _bytes([0x61])),
        ]),
        // deleteRange across a run of keys.
        DiffBackendBatch([
          RawPut('items', ByteKey(_bytes([0x01])), _bytes([0x61])),
          RawPut('items', ByteKey(_bytes([0x02])), _bytes([0x62])),
          RawPut('items', ByteKey(_bytes([0x03])), _bytes([0x63])),
          RawPut('items', ByteKey(_bytes([0x04])), _bytes([0x64])),
        ]),
        DiffBackendBatch([
          RawDeleteRange(
            'items',
            ByteKey(_bytes([0x02])),
            ByteKey(_bytes([0x03])),
          ),
        ]),
        const DiffScanAll('items'),
        // clear one table without touching the others.
        DiffBackendBatch([RawClear('items')]),
        DiffBackendBatch([RawClear('users')]),
        const DiffScanAll('items'),
        const DiffScanAll('users'),
        const DiffScanAll('orders'),
      ]);
    });

    test('snapshot reads concurrent with writes (MVCC isolation)', () async {
      const k1 = [0x01];
      const k2 = [0x02];
      await expectDifferential([
        const DiffPut('items', k1, [0x61]),
        const DiffPut('items', k2, [0x62]),
        DiffMvccRead(
          ops: [
            RawPut('items', ByteKey(_bytes(k1)), _bytes([0x41])),
            RawPut('items', ByteKey(_bytes([0x03])), _bytes([0x63])),
          ],
          readTable: 'items',
          readKeys: const [
            k1,
            k2,
            [0x03],
          ],
        ),
        // Old snapshot must remain stable across multiple writes.
        DiffMvccRead(
          ops: [
            RawDelete('items', ByteKey(_bytes(k2))),
            RawPut('items', ByteKey(_bytes(k1)), _bytes([0x61])),
          ],
          readTable: 'items',
          readKeys: const [k1, k2],
        ),
      ]);
    });

    test('boundary byte payloads and ordering edge keys', () async {
      final unicode = utf8.encode('héllo 🌍 データベース \u0000\uFFFF');
      final binary = List<int>.generate(256, (i) => i);
      final large = List<int>.filled(3 * 1024 * 1024, 0xAB);
      await expectDifferential([
        // Empty value and empty key.
        DiffPut('items', _bytes(const []), _bytes(const [])),
        DiffPut('items', _bytes(const [0x00]), _bytes(const [])),
        const DiffGet('items', []),
        // Unicode / binary / all-zero / all-FF / large payloads.
        DiffPut('items', _bytes(const [0x10]), unicode),
        DiffPut('items', _bytes(const [0x11]), binary),
        DiffPut('items', _bytes(const [0x12]), List.filled(64, 0x00)),
        DiffPut('items', _bytes(const [0x13]), List.filled(64, 0xFF)),
        DiffPut('items', _bytes(const [0x14]), large),
        // Ordering edge keys: prefixes of each other, extremes.
        DiffPut('items', _bytes(const [0x01]), _bytes(const [0x61])),
        DiffPut('items', _bytes(const [0x01, 0x00]), _bytes(const [0x62])),
        DiffPut(
          'items',
          _bytes(const [0x01, 0x00, 0x00]),
          _bytes(const [0x63]),
        ),
        DiffPut('items', _bytes(const [0x01, 0x01]), _bytes(const [0x64])),
        DiffPut('items', _bytes(const [0xFF]), _bytes(const [0x65])),
        DiffPut('items', _bytes(const [0xFF, 0xFF]), _bytes(const [0x66])),
        DiffPut('items', _bytes(const [0x00, 0x00]), _bytes(const [0x67])),
        DiffScanAll('items'),
        DiffRangeScan('items', start: [0x01], end: [0x01, 0x01]),
        DiffRangeScan('items', start: [0x00]),
        const DiffGet('items', [0x11]),
        const DiffGet('items', [0x14]),
      ]);
    });

    test('identical results across a mixed long scenario', () async {
      // A longer deterministic scenario mixing every step family, so ordering
      // of snapshots, LSNs, and feeds is compared over many transitions.
      final steps = <DiffStep>[
        for (var i = 0; i < 40; i++)
          DiffPut('t', _bytes([i]), _bytes([i, i & 0xFF, (i * 7) & 0xFF])),
        const DiffScanAll('t'),
        for (var i = 0; i < 40; i += 3) DiffDelete('t', _bytes([i])),
        DiffRangeScan('t', start: [10], end: [30]),
        DiffPut('t', _bytes(const [5]), _bytes(const [0xEE])),
        DiffBackendBatch([
          for (var i = 0; i < 10; i++)
            RawPut('t2', ByteKey(_bytes([i])), _bytes([0x20 + i])),
          RawClear('t'),
        ]),
        const DiffScanAll('t'),
        const DiffScanAll('t2'),
        for (var i = 0; i < 10; i++) DiffGet('t2', _bytes([i])),
      ];
      await expectDifferential(steps);
    });
  });
}
