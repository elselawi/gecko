// / perf gate instrumentation test.
//
// Verifies the gate's parsing, schema/config validation, and comparison
// logic WITHOUT running the benchmark (which needs the release native
// artifact and is slow): a JSON payload parses, a happy-path run passes, a
// deliberate regression fails, a workload missing from the baseline fails, a
// baseline workload the harness no longer produces fails, a p95 regression
// fails, a schema-version mismatch fails, and a dataset-config mismatch
// fails.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:path/path.dart' as p;

import 'perf_gate.dart';

Map<String, Object?> _defaultDataset() => {
  'seedRows': 1000,
  'shape': 'narrow',
  'batch': 500,
  'distinctGroups': 100,
  'indexed': false,
  'indexedRows': 0,
  'changeLogMaxEntries': 0,
  'encrypted': false,
  'allDirtyHistory': false,
  'lruCapacity': 1024,
  'pageSizes': [50, 200],
};

Map<String, Object?> _provenance({String os = 'test'}) => {
  'os': os,
  'dirty': false,
  'nativeLibrary': {
    'path': '/artifacts/gecko_db_rust.so',
    'sha256': 'abc123',
  },
};

String _jsonDoc(
  List<Map<String, Object?>> results, {
  int schemaVersion = 2,
  Map<String, Object?>? dataset,
  Map<String, Object?>? provenance,
}) => const JsonEncoder.withIndent('  ').convert({
  'benchmark': 'gecko_db_local_stopgap',
  'schemaVersion': schemaVersion,
  'platform': 'test',
  'dart': '3.10.8',
  'generatedAt': '2026-01-01T00:00:00Z',
  'metadata': {
    'dataset': dataset ?? _defaultDataset(),
    ...?provenance,
  },
  'results': results,
});

BaselineRow _baseline(double msPerOp, [double? p95MsPerOp]) =>
    BaselineRow(msPerOp, p95MsPerOp);

void main() {
  test('--json output parses into rows', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
        {
          'backend': 'native file',
          'workload': 'hotRead',
          'msPerOp': 0.001,
          'p95MsPerOp': 0.002,
        },
      ]),
    );
    expect(rows, hasLength(2));
    expect(rows[0].backend, 'native file');
    expect(rows[0].workload, 'insert');
    expect(rows[0].msPerOp, 0.05);
    expect(rows[0].p95MsPerOp, isNull);
    expect(rows[1].p95MsPerOp, 0.002);
  });

  test('--json document carries schema version and dataset config', () {
    final doc = parseBenchDoc(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
      ]),
    );
    expect(doc.schemaVersion, 2);
    expect(doc.dataset['seedRows'], 1000);
    expect(doc.dataset['shape'], 'narrow');
    expect(doc.results, hasLength(1));
  });

  test('happy-path run at or under baseline passes', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.06},
      ]),
    );
    final baseline = <String, BaselineRow>{
      'native file|insert': _baseline(0.05),
    };
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isFalse, reason: report);
    expect(report, isNot(contains('FAIL')));
  });

  test('deliberate regression beyond tolerance fails', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.5},
      ]),
    );
    final baseline = <String, BaselineRow>{
      'native file|insert': _baseline(0.05),
    };
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isTrue, reason: report);
    expect(report, contains('FAIL'));
  });

  test('workload absent from baseline fails; baseline workload missing from '
      'harness fails', () {
    final rows = parseResults(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'brandNew', 'msPerOp': 0.01},
      ]),
    );
    final baseline = <String, BaselineRow>{
      'native file|removedWorkload': _baseline(0.02),
    };
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isTrue, reason: report);
    expect(report, contains('not in baseline'));
    expect(report, contains('no longer produced'));
  });

  test('p95 regression beyond tolerance fails when the baseline pins p95', () {
    final rows = parseResults(
      _jsonDoc([
        {
          'backend': 'native file',
          'workload': 'insert',
          'msPerOp': 0.11, // mean +10% vs baseline → ok
          'p95MsPerOp': 0.09, // p95 +50% vs baseline → fail
        },
      ]),
    );
    final baseline = <String, BaselineRow>{
      'native file|insert': _baseline(0.10, 0.06),
    };
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isTrue, reason: report);
    expect(report, contains('p95'));
  });

  test('p95 is not compared when the baseline does not pin it', () {
    final rows = parseResults(
      _jsonDoc([
        {
          'backend': 'native file',
          'workload': 'insert',
          'msPerOp': 0.06,
          'p95MsPerOp': 0.5, // no baseline p95 → ignored
        },
      ]),
    );
    final baseline = <String, BaselineRow>{
      'native file|insert': _baseline(0.05),
    };
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isFalse, reason: report);
  });

  test('p95 is advisory (not gated) for microsecond-scale workloads', () {
    final rows = parseResults(
      _jsonDoc([
        {
          'backend': 'native file',
          'workload': 'hotRead',
          'msPerOp': 0.003, // mean unchanged → ok
          'p95MsPerOp': 0.010, // +100% vs baseline p95, but mean < 50µs
        },
      ]),
    );
    final baseline = <String, BaselineRow>{
      'native file|hotRead': _baseline(0.003, 0.005),
    };
    final (failed, report) = compare(rows, baseline, 0.30);
    expect(failed, isFalse, reason: report);
    expect(report, contains('advisory'));
  });

  test('schema-version mismatches are caught before comparison', () {
    expect(baselineUsable(BaselineFile(2, const {}, {})), isNull);
    expect(
      baselineUsable(BaselineFile(null, const {}, {})),
      isNotNull,
      reason: 'unversioned baseline must be rejected',
    );
    expect(
      baselineUsable(BaselineFile(1, const {}, {})),
      isNotNull,
      reason: 'old-schema baseline must be rejected',
    );
  });

  test('dataset config mismatch between run and baseline is caught', () {
    final run = BenchDoc('b', 'p', 'd', 't', 2, {
      'dataset': _defaultDataset(),
    }, []);
    final matching = BaselineFile(2, {'dataset': _defaultDataset()}, {});
    expect(datasetMismatch(run, matching), isNull);
    final different = BaselineFile(2, {
      'dataset': {..._defaultDataset(), 'seedRows': 100000},
    }, {});
    expect(datasetMismatch(run, different), contains('seedRows'));
    // New cache-mode / profile keys are part of the gated config.
    final encrypted = BaselineFile(2, {
      'dataset': {..._defaultDataset(), 'encrypted': true},
    }, {});
    expect(datasetMismatch(run, encrypted), contains('encrypted'));
    // A baseline without dataset config is treated as matching (legacy).
    expect(datasetMismatch(run, BaselineFile(2, const {}, {})), isNull);
  });

  test('provenance mismatches (artifact, dirty, OS, Dart) fail closed', () {
    final run = parseBenchDoc(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
      ], provenance: _provenance()),
    );
    final matching = BaselineFile(
      2,
      _provenance(),
      {'native file|insert': _baseline(0.05)},
      dart: '3.10.8',
    );
    expect(provenanceMismatch(run, matching), isNull);

    // Different native artifact hash.
    final otherArtifact = BaselineFile(
      2,
      _provenance(),
      {'native file|insert': _baseline(0.05)},
      dart: '3.10.8',
    );
    final runOtherArtifact = parseBenchDoc(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
      ], provenance: {
        ..._provenance(),
        'nativeLibrary': {
          'path': '/artifacts/gecko_db_rust.so',
          'sha256': 'different',
        },
      }),
    );
    expect(
      provenanceMismatch(runOtherArtifact, otherArtifact),
      contains('nativeLibrary.sha256'),
    );

    // Dirty source state differs.
    final dirtyRun = parseBenchDoc(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
      ], provenance: {..._provenance(), 'dirty': true}),
    );
    expect(provenanceMismatch(dirtyRun, matching), contains('dirty'));

    // OS family differs.
    final otherOs = parseBenchDoc(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
      ], provenance: _provenance(os: 'linux')),
    );
    expect(provenanceMismatch(otherOs, matching), contains('os'));

    // Dart version differs.
    final otherDart = parseBenchDoc(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
      ], provenance: _provenance()),
    );
    final dartBaseline = BaselineFile(
      2,
      _provenance(),
      {'native file|insert': _baseline(0.05)},
      dart: '3.9.0',
    );
    expect(provenanceMismatch(otherDart, dartBaseline), contains('dart'));

    // A legacy baseline with no provenance is treated as matching.
    expect(
      provenanceMismatch(
        parseBenchDoc(
          _jsonDoc([
            {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
          ]),
        ),
        BaselineFile(2, const {}, {'native file|insert': _baseline(0.05)}),
      ),
      isNull,
    );
  });

  test('allowHostDiff escape hatch accepts cross-host runs', () {
    final run = parseBenchDoc(
      _jsonDoc([
        {'backend': 'native file', 'workload': 'insert', 'msPerOp': 0.05},
      ], provenance: _provenance(os: 'linux')),
    );
    final baseline = BaselineFile(
      2,
      _provenance(),
      {'native file|insert': _baseline(0.05)},
      dart: '3.10.8',
    );
    expect(provenanceMismatch(run, baseline), isNotNull);
    expect(provenanceMismatch(run, baseline, allowHostDiff: true), isNull);
  });

  test('gate source documents the regression rules', () {
    final source = p.join('tool', 'perf_gate.dart');
    final text = File(source).readAsStringSync();
    expect(text, contains('--update'));
    expect(text, contains('--tolerance'));
    expect(text, contains('PERF GATE PASSED'));
  });

  test('gate source documents the in-memory backend as unsupported', () {
    final source = p.join('tool', 'perf_gate.dart');
    final text = File(source).readAsStringSync();
    expect(text, contains('--mem is unsupported'));
  });
}
