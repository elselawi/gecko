// Cross-language fixture companion generator (audited-test-gaps 3.10).
//
// `gen_golden_ops.dart` covers the `Op` batch wire. This companion covers the
// OTHER Dart-authored encoders the Rust engine consumes:
//   * the predicate wire (`encodePredicate`) — Dart encodes, Rust decodes and
//     EVALUATES;
//   * the sort-spec wire (`encodeSortSpecs`) — Dart encodes, Rust decodes and
//     ORDERS rows with `compare_rows`;
//   * the durable-index key wire (Priority 5) — Dart builds the
//     order-preserving value element + composite key, Rust builds the same
//     bytes from the `RowValue` and must match exactly (a mismatch would make
//     every cross-language index query miss).
//
// The emitted JSON fixture carries:
//   * each encoded predicate + sort-spec payload (hex), with a stable label;
//   * each durable-index composite key (hex) for a tagged set of values that
//     covers every order-preserving sub-tag (null, bool, int, datetime,
//     bigint, f64, string incl. empty/space/UTF-8/NUL, bytes, list, map);
//   * a shared row set (codec-encoded values, hex);
//   * the EXPECTED match set per predicate and the EXPECTED row order per
//     sort spec — computed by the Dart-side `Filter.matchesValue` and
//     `compareRows`, so a Rust test that reproduces both proves the two
//     implementations agree on the same logical contract, not just on a
//     self-consistent format.
//
// Usage: dart run tool/gen_golden_fixtures.dart
//
// This fixture is a cross-language contract artifact; regenerate it only
// alongside an intentional wire-format change and commit the produced .json
// to the repo.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:gecko_db/gecko_db.dart';
import 'package:gecko_db/src/query/durable_index_bounds.dart'
    show orderedIndexElement;
import 'package:gecko_db/src/query/predicate_codec.dart' show encodePredicate;
import 'package:gecko_db/src/query/sort_spec_codec.dart' show encodeSortSpecs;

const _codec = DefaultWireCodec();

/// The shared row set: distinct ages and nicks so sort orders are tie-free.
/// Row `r2` deliberately lacks `nick` (missing-field handling).
final Map<String, Map<String, Object?>> _rows = {
  'r0': {'id': 'r0', 'name': 'ada', 'age': 36, 'nick': 'g3'},
  'r1': {'id': 'r1', 'name': 'bob', 'age': 20, 'nick': 'g1'},
  'r2': {'id': 'r2', 'name': 'carol', 'age': 30},
  'r3': {'id': 'r3', 'name': 'dan', 'age': 5, 'nick': 'g4'},
  'r4': {'id': 'r4', 'name': 'eve', 'age': 60, 'nick': 'g9'},
  'r5': {'id': 'r5', 'name': 'ann', 'age': 10, 'nick': 'g0'},
  'r6': {'id': 'r6', 'name': 'amy', 'age': 42, 'nick': 'g2'},
  'r7': {'id': 'r7', 'name': 'aaron', 'age': 15, 'nick': 'g5'},
  'r8': {'id': 'r8', 'name': 'beatrice', 'age': 25, 'nick': 'g6'},
  'r9': {'id': 'r9', 'name': 'brad', 'age': 0, 'nick': 'g7'},
};

final Map<String, List<Filter>> _predicates = {
  'eq-nick-g3': [Filter.eq('nick', 'g3')],
  'range-age-10-19': [Filter.between('age', min: 10, max: 19)],
  'range-age-min-40': [Filter.between('age', min: 40)],
  'prefix-name-a': [Filter.prefix('name', 'a')],
  'empty': const [],
};

final Map<String, List<SortSpec>> _sortSpecs = {
  'age-asc': const [SortSpec('age')],
  'age-desc': const [SortSpec('age', SortOrder.descending)],
  'age-asc-nick-desc': const [
    SortSpec('age'),
    SortSpec('nick', SortOrder.descending),
  ],
  'nick-desc': const [SortSpec('nick', SortOrder.descending)],
  'empty': const [],
};

String _hex(List<int> bytes) =>
    [for (final b in bytes) b.toRadixString(16).padLeft(2, '0')].join();

/// Indexed values covering every order-preserving sub-tag, so the Rust
/// golden test proves the composite key bytes match across languages for all
/// supported types (including negatives, zero, UTF-8, an embedded NUL, and
/// bytes — the tricky cases for an order-preserving encoding).
final List<({String label, String field, Object? value, String recordId})>
_indexValues = [
  (label: 'null', field: 'f', value: null, recordId: 'r0'),
  (label: 'bool-true', field: 'f', value: true, recordId: 'r1'),
  (label: 'bool-false', field: 'f', value: false, recordId: 'r2'),
  (label: 'int-neg', field: 'age', value: -10, recordId: 'k0'),
  (label: 'int-zero', field: 'age', value: 0, recordId: 'k1'),
  (label: 'int-pos', field: 'age', value: 42, recordId: 'k2'),
  (
    label: 'datetime',
    field: 'at',
    value: DateTime.utc(2021, 1, 15, 12, 30, 45, 123, 456),
    recordId: 'd0',
  ),
  (
    label: 'bigint-neg',
    field: 'n',
    value: BigInt.parse('-12345678901234567890123456789'),
    recordId: 'b0',
  ),
  (
    label: 'bigint-pos',
    field: 'n',
    value: BigInt.parse('12345678901234567890123456789'),
    recordId: 'b1',
  ),
  (label: 'f64-neg', field: 'v', value: -1.5, recordId: 'f0'),
  (label: 'f64-zero', field: 'v', value: 0.0, recordId: 'f1'),
  (label: 'f64-pos', field: 'v', value: 3.25, recordId: 'f2'),
  (label: 'f64-inf', field: 'v', value: double.infinity, recordId: 'f3'),
  (label: 'string-empty', field: 'name', value: '', recordId: 's0'),
  (label: 'string-simple', field: 'name', value: 'g1', recordId: 's1'),
  (label: 'string-space', field: 'name', value: 'a b', recordId: 's2'),
  (label: 'string-utf8', field: 'name', value: 'héllo', recordId: 's3'),
  (label: 'string-nul', field: 'name', value: 'a\u0000b', recordId: 's4'),
  (
    label: 'bytes',
    field: 'blob',
    value: Uint8List.fromList([1, 2, 0, 255]),
    recordId: 'by0',
  ),
  (label: 'list', field: 'tags', value: [1, 'two', 3.0], recordId: 'l0'),
  (label: 'map', field: 'meta', value: {'a': 1, 'b': 'two'}, recordId: 'm0'),
];

/// The durable-index composite key
/// `[0x06, u32(4)] | encode(table) | encode(field) |
/// orderedIndexElement(value) | encode(recordId)`.
List<int> _indexKey(
  String table,
  String field,
  Object? value,
  String recordId,
) {
  final codec = _codec;
  return <int>[
    0x06,
    0,
    0,
    0,
    4,
    ...codec.encode(table),
    ...codec.encode(field),
    ...orderedIndexElement(value, codec: codec),
    ...codec.encode(recordId),
  ];
}

/// A JSON-tagged representation of an indexed value the Rust side can
/// reconstruct as a `RowValue`. Maps preserve insertion order via a pair
/// array (the codec encodes maps in insertion order).
Object? _tagged(Object? value) {
  if (value == null) return {'type': 'null'};
  if (value is bool) return {'type': 'bool', 'value': value};
  if (value is int) return {'type': 'int', 'value': value};
  if (value is DateTime) {
    return {'type': 'datetime', 'value': value.toUtc().microsecondsSinceEpoch};
  }
  if (value is BigInt) return {'type': 'bigint', 'value': value.toString()};
  if (value is double) {
    if (value == double.infinity) return {'type': 'f64', 'value': 'inf'};
    if (value == double.negativeInfinity) {
      return {'type': 'f64', 'value': '-inf'};
    }
    if (value.isNaN) return {'type': 'f64', 'value': 'nan'};
    return {'type': 'f64', 'value': value};
  }
  if (value is String) return {'type': 'string', 'value': value};
  if (value is Uint8List) return {'type': 'bytes', 'value': _hex(value)};
  if (value is List) {
    return {
      'type': 'list',
      'value': [for (final v in value) _tagged(v)],
    };
  }
  if (value is Map) {
    return {
      'type': 'map',
      'value': [
        for (final e in value.entries) [_tagged(e.key), _tagged(e.value)],
      ],
    };
  }
  throw ArgumentError.value(value, 'value', 'unsupported indexed value');
}

/// The rows a [Filter] matches, in fixture row order.
List<String> _matches(List<Filter> filters) => [
  for (final entry in _rows.entries)
    if (filters.every((f) => f.matchesValue(entry.value[f.field]))) entry.key,
];

/// The rows ordered by [specs] under Dart `compareRows` (stable).
List<String> _ordered(List<SortSpec> specs) {
  final keys = _rows.keys.toList();
  keys.sort((a, b) {
    final cmp = compareRows(
      Map<Object?, Object?>.from(_rows[a]!),
      Map<Object?, Object?>.from(_rows[b]!),
      specs,
    );
    if (cmp != 0) return cmp;
    return a.compareTo(b); // tie-break by key, matching the query engine
  });
  return keys;
}

void main() {
  final fixture = <String, Object?>{
    'schemaVersion': 1,
    'predicates': [
      for (final entry in _predicates.entries)
        {'label': entry.key, 'hex': _hex(encodePredicate(entry.value))},
    ],
    'sortSpecs': [
      for (final entry in _sortSpecs.entries)
        {'label': entry.key, 'hex': _hex(encodeSortSpecs(entry.value))},
    ],
    'rows': [
      for (final entry in _rows.entries)
        {'key': entry.key, 'hex': _hex(_codec.encode(entry.value))},
    ],
    'expectedMatches': {
      for (final entry in _predicates.entries) entry.key: _matches(entry.value),
    },
    'expectedOrder': {
      for (final entry in _sortSpecs.entries) entry.key: _ordered(entry.value),
    },
    'indexKeys': [
      for (final entry in _indexValues)
        {
          'label': entry.label,
          'table': 'items',
          'field': entry.field,
          'value': _tagged(entry.value),
          'recordId': entry.recordId,
          'hex': _hex(
            _indexKey('items', entry.field, entry.value, entry.recordId),
          ),
        },
    ],
  };

  final out = File('rust/tests/fixtures/golden_predicate_sort.json')
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(fixture)}\n',
    );
  stdout.writeln('Wrote ${out.path}');
  stdout.writeln(
    '  ${_predicates.length} predicates, ${_sortSpecs.length} sort specs, '
    '${_rows.length} rows, ${_indexValues.length} index keys',
  );

  // Self-check: the Dart decoder/evaluator reproduces its own expectations.
  for (final entry in _predicates.entries) {
    final decoded = encodePredicate(entry.value);
    if (decoded.isEmpty) {
      stderr.writeln(
        'SELF-CHECK FAILED: empty predicate bytes for ${entry.key}',
      );
      exit(1);
    }
  }
  for (final entry in _sortSpecs.entries) {
    if (encodeSortSpecs(entry.value).isEmpty) {
      stderr.writeln('SELF-CHECK FAILED: empty sort bytes for ${entry.key}');
      exit(1);
    }
  }
  for (final entry in _indexValues) {
    if (_indexKey('items', entry.field, entry.value, entry.recordId).isEmpty) {
      stderr.writeln('SELF-CHECK FAILED: empty index key for ${entry.label}');
      exit(1);
    }
  }
  stdout.writeln('Dart self-check: OK');
}
