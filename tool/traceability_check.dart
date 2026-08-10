// Workstream 6: 12-criterion acceptance traceability checker.
//
// The local-first acceptance criteria (plan.md appendix) each map to one or
// more NAMED tests. This tool verifies every listed test file exists and
// contains the named test; with `--run` it also executes the listed test files
// so the table is not just prose that can silently rot.
//
// Usage:
//   dart run tool/traceability_check.dart            # existence check
//   dart run tool/traceability_check.dart --run      # existence + run files
//   dart run tool/traceability_check.dart --json     # machine-readable output
library;

import 'dart:convert';
import 'dart:io';

class TraceEntry {
  const TraceEntry(this.criterion, this.summary, this.tests);
  final int criterion;
  final String summary;
  final List<(String, String)> tests; // (file, test-name substring)
}

const List<TraceEntry> kTraceability = [
  TraceEntry(1, 'Widgets consume live typed queries directly', [
    ('packages/gecko_db/test/query_test.dart', 'reactive filtered query'),
    ('packages/gecko_db/test/phase5_index_ws3_test.dart', 'range'),
  ]),
  TraceEntry(2, 'Local reads/writes work fully offline', [
    (
      'packages/gecko_db/test/phase2_differential_test.dart',
      'put/update/insert-only/update-only/delete/clear',
    ),
    (
      'packages/gecko_db/test/raw_backend_contract_test.dart',
      'put/read/delete sequence is deterministic',
    ),
  ]),
  TraceEntry(3, 'A local mutation auto-updates all affected live queries', [
    (
      'packages/gecko_db/test/query_test.dart',
      're-emits when a record starts matching',
    ),
    ('packages/gecko_db/test/watch_test.dart', 'emits post-write snapshots'),
  ]),
  TraceEntry(4, 'No manually maintained observable lists required', [
    ('packages/gecko_db/test/watch_test.dart', 'zero emissions'),
    (
      'packages/gecko_db/test/phase13_examples_test.dart',
      'advanced example compiles and runs',
    ),
  ]),
  TraceEntry(5, 'Sync can read pending local changes via a small interface', [
    (
      'packages/gecko_db/test/phase7_transactions_sync_test.dart',
      'local put patch delete produce one pending record',
    ),
  ]),
  TraceEntry(6, 'Remote changes applied transactionally', [
    (
      'packages/gecko_db/test/phase7_transactions_sync_test.dart',
      'rolls back single and multi-collection writes',
    ),
    (
      'packages/gecko_db/test/phase7_transactions_sync_test.dart',
      'reads own staged writes',
    ),
  ]),
  TraceEntry(7, 'Local/remote changes merge deterministically', [
    (
      'packages/gecko_db/test/phase8_conflict_test.dart',
      'last-write-wins, field merge, and manual review differ',
    ),
    (
      'packages/gecko_db/test/phase8_conflict_test.dart',
      'manual conflicts preserve both versions',
    ),
  ]),
  TraceEntry(8, 'Attachment metadata stays consistent with record changes', [
    (
      'packages/gecko_db/test/phase9_attachments_test.dart',
      'create, read, and duplicate-hash dedupe share a blob',
    ),
    (
      'packages/gecko_db/test/phase9_attachments_test.dart',
      'deleting the last reference frees the blob',
    ),
  ]),
  TraceEntry(9, 'Large datasets stay responsive', [
    (
      'packages/gecko_db/test/phase12_performance_test.dart',
      'bulkWrite commits atomically',
    ),
    ('packages/gecko_db/test/phase5_index_ws3_test.dart', 'scan'),
  ]),
  TraceEntry(10, 'Tests use isolated native file databases', [
    (
      'packages/gecko_db/test/raw_backend_contract_test.dart',
      'range ordering and bounds are shared backend semantics',
    ),
    (
      'packages/gecko_db/test/phase2_differential_test.dart',
      'multi-operation and multi-table atomic batches',
    ),
  ]),
  TraceEntry(11, 'Initialization, recovery, migrations are reliable', [
    (
      'packages/gecko_db/test/phase2_process_crash_test.dart',
      'committed batches survive a hard kill',
    ),
    (
      'packages/gecko_db/test/phase10_migrations_test.dart',
      'stamp is idempotent',
    ),
  ]),
  TraceEntry(12, 'App-specific store layer shrinks substantially', [
    (
      'packages/gecko_db/test/phase13_examples_test.dart',
      'quickstart example compiles and runs',
    ),
    ('tool/consumer_fixture_test.dart', 'runs end-to-end'),
  ]),
];

/// Returns the missing (file, test) pairs, if any. [entries] defaults to the
/// full [kTraceability] table (a test hook lets the checker be exercised with
/// a deliberately-broken fixture).
List<(String, String)> verifyExistence({List<TraceEntry>? entries}) {
  final missing = <(String, String)>[];
  for (final entry in entries ?? kTraceability) {
    for (final (file, testName) in entry.tests) {
      if (!File(file).existsSync()) {
        missing.add((file, testName));
        continue;
      }
      final source = File(file).readAsStringSync();
      if (!source.contains(testName)) {
        missing.add((file, testName));
      }
    }
  }
  return missing;
}

Future<List<String>> runAll() async {
  final failures = <String>[];
  final files = <String>{
    for (final e in kTraceability)
      for (final (f, _) in e.tests) f,
  };
  for (final file in files) {
    final result = await Process.run(Platform.resolvedExecutable, [
      'test',
      file,
    ]);
    if (result.exitCode != 0) {
      failures.add(file);
    }
  }
  return failures;
}

void main(List<String> args) async {
  final json = args.contains('--json');
  final run = args.contains('--run');
  final missing = verifyExistence();
  if (json) {
    stdout.writeln(
      jsonEncode({
        'criteria': kTraceability.length,
        'referencedTests': [
          for (final e in kTraceability)
            for (final (f, t) in e.tests) {'file': f, 'test': t},
        ],
        'missing': [
          for (final (f, t) in missing) {'file': f, 'test': t},
        ],
      }),
    );
    if (missing.isNotEmpty) exit(1);
    return;
  }
  for (final entry in kTraceability) {
    final status = missing.any((m) => entry.tests.any((t) => t == m))
        ? 'MISSING'
        : 'ok';
    stdout.writeln(
      'criterion ${entry.criterion.toString().padLeft(2)} [$status] '
      '${entry.summary}',
    );
    for (final (file, testName) in entry.tests) {
      stdout.writeln('    -> $file :: "$testName"');
    }
  }
  if (missing.isNotEmpty) {
    stderr.writeln(
      'TRACEABILITY FAILED: ${missing.length} missing test ref(s)',
    );
    for (final (f, t) in missing) {
      stderr.writeln('  - $f :: "$t"');
    }
    exit(1);
  }
  if (run) {
    final failures = await runAll();
    if (failures.isNotEmpty) {
      stderr.writeln('TRACEABILITY RUN FAILED for: ${failures.join(', ')}');
      exit(1);
    }
    stdout.writeln(
      'TRACEABILITY RUN PASSED (${kTraceability.length} criteria)',
    );
  } else {
    stdout.writeln('TRACEABILITY PASSED (${kTraceability.length} criteria)');
  }
}
